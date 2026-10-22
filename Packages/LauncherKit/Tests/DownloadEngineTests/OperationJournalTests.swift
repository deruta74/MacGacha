// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)))
func roundTripsAllRecords() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("staging/build-1/journal.jsonl")
    let planID = try SafeIdentifier("build-1")
    let digest = try journalDigest()
    let staged = try SafeRelativePath("Data/new.bin")
    let deleted = try SafeRelativePath("Data/old.bin")
    let records: [JournalRecord] = [
        .planStored(planID: planID, planDigest: digest), .operationStarted,
        .objectVerified(id: "opaque/id#1"), .fileStaged(path: staged), .fileUnstaged(path: staged),
        .fileStaged(path: staged), .batchStarted(index: 0), .commitStarted(batch: 0),
        .fileCommitted(path: staged), .fileDeleted(path: deleted), .batchStarted(index: 1),
        .commitStarted(batch: 1), .operationCompleted,
    ]
    let journal = try OperationJournal(fs: fs, path: path)
    for record in records { try await journal.append(record) }
    let bytes = try fs.readFile(at: path, maxBytes: 16_384)
    #expect(bytes.last == 0x0a)
    let lines = bytes.split(separator: 0x0a)
    #expect(try lines.map { try JSONDecoder().decode(JournalRecord.self, from: Data($0)) } == records)
    #expect(String(decoding: lines[0], as: UTF8.self) ==
        "{\"planDigest\":{\"algorithm\":\"sha256\",\"hex\":\"\(digest.hex)\"},\"planID\":\"build-1\",\"type\":\"planStored\"}")
    let state = try OperationJournal.replay(fs: fs, path: path)
    #expect(state.planID == planID)
    #expect(state.planDigest == digest)
    #expect(state.verifiedObjects == ["opaque/id#1"])
    #expect(state.stagedFiles == [staged])
    #expect(state.currentBatch == 1)
    #expect(state.commitStartedBatches == [0, 1])
    #expect(state.committedFiles == [staged])
    #expect(state.deletedFiles == [deleted])
    #expect(state.completed)
}

@Test(arguments: [Data("{\"type\":\"objectVerified\",\"id\":\"torn".utf8),
    Data("{\"id\":\"no-newline\",\"type\":\"objectVerified\"}".utf8), Data([0xe6, 0x97])])
func tornTailIsTruncatedBeforeAppend(tail: Data) async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let prefix = try journalLines([journalPlanRecord(), .operationStarted, .objectVerified(id: "kept")])
    try fs.writeAtomically(prefix + tail, to: path)
    let replayed = try OperationJournal.replay(fs: fs, path: path)
    #expect(replayed.verifiedObjects == ["kept"])
    #expect(try fs.readFile(at: path, maxBytes: 1024) == prefix + tail)
    let journal = try OperationJournal(fs: fs, path: path)
    #expect(try fs.readFile(at: path, maxBytes: 1024) == prefix)
    try await journal.append(.objectVerified(id: "appended"))
    let reopened = try OperationJournal(fs: fs, path: path)
    try await reopened.append(.operationCompleted)
    let state = try OperationJournal.replay(fs: fs, path: path)
    #expect(state.verifiedObjects == ["kept", "appended"])
    #expect(state.completed)
}

@Test
func midFileCorruptionThrows() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    for corrupt in ["not JSON\n", "{\n", "\n"] {
        let bytes = try journalLines([journalPlanRecord(), .operationStarted]) + Data(corrupt.utf8) + journalLines([.operationCompleted])
        try fs.writeAtomically(bytes, to: path)
        try expectJournalCorrupt { _ = try OperationJournal.replay(fs: fs, path: path) }
        try expectJournalCorrupt { _ = try OperationJournal(fs: fs, path: path) }
        #expect(try fs.readFile(at: path, maxBytes: 1024) == bytes)
    }
}

@Test(.timeLimit(.minutes(1)))
func unstagedRemovesStagedFile() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let file = try SafeRelativePath("Data/file")
    let other = try SafeRelativePath("Data/other")
    let journal = try OperationJournal(fs: fs, path: path)
    try await journal.append(journalPlanRecord())
    for record in [JournalRecord.objectVerified(id: "shared"), .fileStaged(path: file), .fileStaged(path: other),
        .fileUnstaged(path: file), .fileUnstaged(path: file)] {
        try await journal.append(record)
    }
    let state = try OperationJournal.replay(fs: fs, path: path)
    #expect(state.stagedFiles == [other])
    #expect(state.verifiedObjects == ["shared"])
}

@Test(.timeLimit(.minutes(1)))
func durableRecordsAlwaysUseFullFsync() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let syncs = Mutex([Bool]())
    let journal = try OperationJournal(fs: fs, path: path, synchronize: { fd, durable in
        syncs.withLock { $0.append(durable) }
        try ContainedFileSystem.synchronizeFileDescriptor(fd, durable: durable)
    })
    #expect(syncs.withLock { $0 } == [true])
    syncs.withLock { $0.removeAll() }
    let file = try SafeRelativePath("Data/file")
    let records: [(JournalRecord, Bool)] = [
        (.planStored(planID: try SafeIdentifier("build-1"), planDigest: try journalDigest()), false),
        (.operationStarted, false),
        (.objectVerified(id: "object-1"), false),
        (.fileStaged(path: file), false),
        (.fileUnstaged(path: file), false),
        (.batchStarted(index: 0), true),
        (.commitStarted(batch: 0), true),
        (.fileCommitted(path: file), false),
        (.fileDeleted(path: file), false),
        (.operationCompleted, true),
    ]
    for (record, durable) in records {
        syncs.withLock { $0.removeAll() }
        try await journal.append(record)
        if case .objectVerified = record { #expect(syncs.withLock { $0 }.isEmpty) }
        else { #expect(syncs.withLock { $0 } == [durable], "Unexpected durability for \(record)") }
    }
    #expect(try OperationJournal.replay(fs: fs, path: path).completed)
}

@Test
func unknownRecordThrows() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let bytes = Data("{\"type\":\"futureRecord\"}\n".utf8)
    // Unknown schema is rejected directly and in the middle of a journal. A final
    // undecodable line is now recoverable under the torn-tail contract.
    try fs.writeAtomically(journalLines([journalPlanRecord()]) + bytes + journalLines([.operationCompleted]), to: path)
    try expectJournalCorrupt { _ = try OperationJournal.replay(fs: fs, path: path) }
    try expectJournalCorrupt { _ = try OperationJournal(fs: fs, path: path) }
    try expectJournalCorrupt { _ = try JSONDecoder().decode(JournalRecord.self, from: bytes) }
}

@Test
func journalDecodingPreservesTypedInvariants() throws {
    for json in [
        "{\"type\":\"fileStaged\",\"path\":\"../escape\"}",
        "{\"type\":\"batchStarted\",\"index\":-1}",
        "{\"type\":\"commitStarted\",\"batch\":-1}",
        "{\"type\":\"planStored\",\"planID\":\"../escape\",\"planDigest\":{\"algorithm\":\"sha256\",\"hex\":\"\(String(repeating: "a", count: 64))\"}}",
        "{\"type\":\"planStored\",\"planID\":\"build\",\"planDigest\":{\"algorithm\":\"sha256\",\"hex\":\"bad\"}}",
    ] {
        try expectJournalCorrupt { _ = try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8)) }
    }
}

@Test
func missingJournalReplaysAsEmptyWithoutCreatingAFile() throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("missing/journal.jsonl")
    #expect(try OperationJournal.replay(fs: fs, path: path) == JournalState())
    #expect(try fs.itemType(at: path) == nil)
}

@Test(.timeLimit(.minutes(1)))
func journalCancellationKeepsExistingRecords() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let journal = try OperationJournal(fs: fs, path: path)
    try await journal.append(journalPlanRecord())
    try await journal.append(.operationStarted)
    let before = try fs.readFile(at: path, maxBytes: 1024)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await journal.append(.operationCompleted)
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(try fs.readFile(at: path, maxBytes: 1024) == before)
    try await journal.append(.objectVerified(id: "still-usable"))
    #expect(try OperationJournal.replay(fs: fs, path: path).verifiedObjects == ["still-usable"])
}

@Test(.timeLimit(.minutes(1)))
func failedAppendRequiresReopeningBeforeAnotherAppend() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let fail = Mutex(false)
    let journal = try OperationJournal(fs: fs, path: path, synchronize: { fd, durable in
        if durable && fail.withLock({ $0 }) { throw LauncherError.io("Injected sync failure") }
        try ContainedFileSystem.synchronizeFileDescriptor(fd, durable: durable)
    })
    try await journal.append(journalPlanRecord())
    try await journal.append(.batchStarted(index: 0))
    fail.withLock { $0 = true }
    await #expect(throws: LauncherError.io("Injected sync failure")) {
        try await journal.append(.commitStarted(batch: 0))
    }
    await #expect(throws: LauncherError.journalCorrupt("Reopen journal after failed append")) {
        try await journal.append(.operationCompleted)
    }
    let reopened = try OperationJournal(fs: fs, path: path)
    #expect(reopened.recoveredState.commitStartedBatches == [0])
    #expect(!reopened.recoveredState.completed)
    try await reopened.append(.operationCompleted)
    #expect(try OperationJournal.replay(fs: fs, path: path).completed)
}

@Test(.timeLimit(.minutes(1)))
func journalStreamsAcrossReadBoundariesAndDiscardsLongTornTail() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let id = String(repeating: "é", count: 2048)
    var prefix = try journalLines([journalPlanRecord(), .operationStarted])
    let objectLine = try journalLines([.objectVerified(id: id)])
    prefix.append(Data(repeating: 32, count: 70_000)); prefix.append(objectLine)
    try fs.writeAtomically(prefix + Data(repeating: 0x78, count: 2 * 1_048_576), to: path)
    let journal = try OperationJournal(fs: fs, path: path)
    try await journal.append(.operationCompleted)
    let state = try OperationJournal.replay(fs: fs, path: path)
    #expect(state.verifiedObjects == [id])
    #expect(state.completed)
    #expect(try fs.readFile(at: path, maxBytes: 100_000) == prefix + journalLines([.operationCompleted]))
}

private func journalDigest() throws -> Digest {
    try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64))
}

@Test(.timeLimit(.minutes(1)))
func invalidOrOversizedRecordsDoNotModifyTheJournal() async throws {
    let directory = try TempDir()
    let fs = try ContainedFileSystem(root: directory.url)
    let path = try SafeRelativePath("journal.jsonl")
    let journal = try OperationJournal(fs: fs, path: path)
    await #expect(throws: LauncherError.journalCorrupt("Negative batch index")) {
        try await journal.append(.batchStarted(index: -1))
    }
    let oversized = String(repeating: "a", count: 1_048_577)
    await #expect(throws: LauncherError.journalCorrupt("Invalid object id")) {
        try await journal.append(.objectVerified(id: oversized))
    }
    await #expect(throws: LauncherError.journalCorrupt("Journal record exceeds 1048576 bytes")) {
        try await journal.append(.fileStaged(path: SafeRelativePath(oversized)))
    }
    #expect(try fs.readFile(at: path, maxBytes: 1).isEmpty)
    try await journal.append(journalPlanRecord())
    try await journal.append(.operationCompleted)
    let completeOversized = Data("{\"type\":\"objectVerified\",\"id\":\"\(oversized)\"}\n".utf8)
    try fs.writeAtomically(completeOversized, to: path)
    #expect(try OperationJournal.replay(fs: fs, path: path) == JournalState())
    _ = try OperationJournal(fs: fs, path: path)
    #expect(try fs.size(at: path) == 0)
}

private func journalLines(_ records: [JournalRecord]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for record in records { data.append(try encoder.encode(record)); data.append(0x0a) }
    return data
}

private func expectJournalCorrupt(_ body: () throws -> Void) throws {
    do { try body(); Issue.record("Expected LauncherError.journalCorrupt") }
    catch LauncherError.journalCorrupt(let reason) { #expect(!reason.isEmpty) }
}

private func journalPlanRecord() throws -> JournalRecord {
    .planStored(planID: try SafeIdentifier("build-1"), planDigest: try journalDigest())
}
