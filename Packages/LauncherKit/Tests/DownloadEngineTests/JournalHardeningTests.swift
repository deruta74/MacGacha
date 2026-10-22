// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)))
func journalCancellationInsideSyncFinishesRecord() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    try fs.writeAtomically(hardeningLines([hardeningPlanRecord()]), to: path)
    let armed = Mutex(false)
    let journal = try OperationJournal(fs: fs, path: path, synchronize: { fd, durable in
        if armed.withLock({ $0 }) { withUnsafeCurrentTask { $0?.cancel() } }
        try ContainedFileSystem.synchronizeFileDescriptor(fd, durable: durable)
    })
    armed.withLock { $0 = true }
    let task = Task { try await journal.append(.operationCompleted) }
    try await task.value
    #expect(try OperationJournal.replay(fs: fs, path: path).completed)
}

@Test(arguments: [false, true])
func journalRejectsChangedPlan(changeDigest: Bool) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let second = JournalRecord.planStored(planID: try SafeIdentifier(changeDigest ? "build" : "other"),
        planDigest: try Digest(algorithm: .sha256, hex: String(repeating: changeDigest ? "b" : "a", count: 64)))
    try fs.writeAtomically(hardeningLines([hardeningPlanRecord(), .objectVerified(id: "old"), second]), to: path)
    #expect(throws: LauncherError.journalCorrupt("Conflicting planStored")) { try OperationJournal.replay(fs: fs, path: path) }
}

@Test
func journalRejectsRecordsAfterCompletion() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    try fs.writeAtomically(hardeningLines([hardeningPlanRecord(), .operationCompleted, .operationStarted]), to: path)
    #expect(throws: LauncherError.journalCorrupt("Record after operationCompleted")) { try OperationJournal.replay(fs: fs, path: path) }
}

@Test
func journalRejectsRecordBeforePlan() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    try fs.writeAtomically(hardeningLines([.operationStarted]), to: path)
    #expect(throws: LauncherError.journalCorrupt("Record before planStored")) { try OperationJournal.replay(fs: fs, path: path) }
}

@Test
func journalRejectsCommitWithoutMatchingBatch() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    try fs.writeAtomically(hardeningLines([hardeningPlanRecord(), .commitStarted(batch: 0)]), to: path)
    #expect(throws: LauncherError.journalCorrupt("commitStarted without batchStarted")) { try OperationJournal.replay(fs: fs, path: path) }
}

@Test(arguments: [Data(), Data(repeating: 0, count: 70_000)])
func journalDiscardsNewlineTerminatedTornTail(zeros: Data) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let prefix = try hardeningLines([hardeningPlanRecord(), .objectVerified(id: "kept")])
    try fs.writeAtomically(prefix + Data([0, 0, 0, 10]) + zeros, to: path)
    let journal = try OperationJournal(fs: fs, path: path)
    _ = journal
    #expect(try fs.readFile(at: path, maxBytes: 1024) == prefix)
    #expect(try OperationJournal.replay(fs: fs, path: path).verifiedObjects == ["kept"])
}

@Test(.timeLimit(.minutes(1)))
func journalOpenFailureBeforeWriteDoesNotPoisonInstance() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let journal = try OperationJournal(fs: fs, path: path)
    try fs.removeFile(at: path); try fs.createDirectory(at: path)
    await #expect(throws: (any Error).self) { try await journal.append(hardeningPlanRecord()) }
    try fs.removeItem(at: path)
    try await journal.append(hardeningPlanRecord())
    #expect(try OperationJournal.replay(fs: fs, path: path).planID == SafeIdentifier("build"))
}

@Test
func journalCreationSyncsParentsAndUsesFullSync() throws {
    let temp = try TempDir(); let ops = JournalSyncRecorder()
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    _ = try OperationJournal(fs: fs, path: SafeRelativePath("staging/build/journal"))
    let calls = ops.calls.withLock { $0 }
    #expect(calls.filter(\.directory).count == 3)
    #expect(calls.filter { !$0.directory }.map(\.durable) == [true])
}

@Test(.timeLimit(.minutes(1)))
func journalExistingAppendDoesNotSyncParent() async throws {
    let temp = try TempDir(); let ops = JournalSyncRecorder()
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let journal = try OperationJournal(fs: fs, path: SafeRelativePath("journal"))
    ops.calls.withLock { $0.removeAll() }
    try await journal.append(hardeningPlanRecord())
    #expect(ops.calls.withLock { $0.filter(\.directory).isEmpty })
    #expect(ops.calls.withLock { $0.count } == 1)
}

@Test
func journalRejectsInvalidObjectIDsAndExtraKeys() throws {
    for json in ["{\"type\":\"objectVerified\",\"id\":\"\"}",
        "{\"type\":\"objectVerified\",\"id\":\"\(String(repeating: "x", count: 4097))\"}",
        "{\"type\":\"operationStarted\",\"path\":\"x\"}",
        "{\"type\":\"operationStarted\",\"unknown\":1}"] {
        let reason = json.contains("objectVerified") ? "Invalid object id" : "Unexpected journal record keys"
        #expect(throws: LauncherError.journalCorrupt(reason)) { try JSONDecoder().decode(JournalRecord.self, from: Data(json.utf8)) }
    }
}

@Test
func journalRepairSyncsTruncationBeforeReturning() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let prefix = try hardeningLines([hardeningPlanRecord()])
    try fs.writeAtomically(prefix + Data("torn".utf8), to: path)
    let sizes = Mutex([Int64]())
    _ = try OperationJournal(fs: fs, path: path, synchronize: { fd, durable in
        var info = stat(); #expect(fstat(fd, &info) == 0)
        sizes.withLock { $0.append(info.st_size) }
        try ContainedFileSystem.synchronizeFileDescriptor(fd, durable: durable)
    })
    #expect(sizes.withLock { $0 } == [Int64(prefix.count)])
}

@Test
func journalNewlineExactlyAtReadBoundary() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let prefix = try hardeningLines([hardeningPlanRecord()])
    let line = Data("{\"type\":\"objectVerified\",\"id\":\"boundary\"}".utf8)
    let bytes = prefix + line + Data(repeating: 32, count: 65_535 - prefix.count - line.count) + Data([10])
        + (try hardeningLines([.operationCompleted]))
    try fs.writeAtomically(bytes, to: path)
    let state = try OperationJournal.replay(fs: fs, path: path)
    #expect(state.verifiedObjects == ["boundary"]); #expect(state.completed)
}

@Test(.timeLimit(.minutes(1)))
func journalRecoveredStateIsOpeningSnapshot() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    try fs.writeAtomically(hardeningLines([hardeningPlanRecord(), .objectVerified(id: "kept")]), to: path)
    let journal = try OperationJournal(fs: fs, path: path)
    #expect(journal.recoveredState.verifiedObjects == ["kept"])
    try await journal.append(.objectVerified(id: "new"))
    #expect(journal.recoveredState.verifiedObjects == ["kept"])
    #expect(try await journal.snapshot().verifiedObjects == ["kept", "new"])
}

@Test(.timeLimit(.minutes(1)))
func journalAppendRunsOnDedicatedSerialQueue() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let key = JournalQueueKey(); let observed = Mutex(false)
    let journal = try OperationJournal(fs: fs, path: SafeRelativePath("journal"), synchronize: { fd, durable in
        observed.withLock { $0 = DispatchQueue.getSpecific(key: key.value) == 1 }
        try ContainedFileSystem.synchronizeFileDescriptor(fd, durable: durable)
    })
    journal.ioQueue.setSpecific(key: key.value, value: 1)
    try await journal.append(hardeningPlanRecord())
    #expect(observed.withLock { $0 })
}

// The key is initialized once, then only used by dispatch's synchronized APIs.
private final class JournalQueueKey: @unchecked Sendable {
    let value = DispatchSpecificKey<Int>()
}

private func hardeningPlanRecord() throws -> JournalRecord {
    .planStored(planID: try SafeIdentifier("build"), planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)))
}
private func hardeningLines(_ records: [JournalRecord]) throws -> Data {
    var bytes = Data()
    for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
    return bytes
}
private final class JournalSyncRecorder: FileOps {
    struct Call { let directory: Bool; let durable: Bool }
    let calls = Mutex([Call]())
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var info = stat(); guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("fstat") }
        calls.withLock { $0.append(Call(directory: info.st_mode & S_IFMT == S_IFDIR, durable: durable)) }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
