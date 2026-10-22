// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)), arguments: [Data(), Data("{\"type\":\"planStored\",\"planID\":\"".utf8), Data("{\"type\":\"planStored\"}\n".utf8)])
func storedPlanWithMissingFirstJournalRecordResumes(tail: Data) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("missing-first", [("Data/a", "abc"), ("Data/b", "def")])
    let cdn = MockCDN(); opServe(cdn, plan, ["abc", "def"])
    try fs.writeAtomically(JSONEncoder().encode(plan), to: opPlanPath(plan))
    try fs.writeAtomically(tail, to: opJournal(plan))
    let events = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { event in
        if event == .phase(.checkingSpace) {
            let replay = try OperationJournal.replay(fs: fs, path: opJournal(plan))
            #expect(replay.planID == plan.id); #expect(replay.planDigest == plan.planDigest)
        }
    })
    #expect(events.last == .phase(.completed))
    for file in plan.files {
        let bytes = try fs.readFile(at: file.path, maxBytes: 3)
        var hasher = StreamingHasher(file.digest.algorithm); hasher.update(bytes)
        #expect(hasher.finalize() == file.digest)
    }
    #expect(cdn.requestLog.count == 2)
}

private let followupTornTails: [Data] = [
    Data("{}\n".utf8), Data("null\n".utf8), Data("{\"type\":\"objectVerified\"}\n".utf8),
    Data("{\"type\":\"futureRecord\"}\n".utf8), Data([0, 0, 10, 0, 0, 10]),
    Data(repeating: 0, count: 1_048_577) + Data([10]),
    Data(repeating: 0x78, count: 1_048_577) + Data([10]),
]

@Test(.timeLimit(.minutes(1)), arguments: followupTornTails)
func journalRecoversAnyInvalidFinalLine(tail: Data) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let prefix = try followupLines([followupPlanRecord(), .objectVerified(id: "kept")])
    let bytes = prefix + tail + Data([0, 10, 0, 10])
    try fs.writeAtomically(bytes, to: path)
    #expect(try OperationJournal.replay(fs: fs, path: path).verifiedObjects == ["kept"])
    #expect(try fs.size(at: path) == Int64(bytes.count))
    let journal = try OperationJournal(fs: fs, path: path)
    #expect(journal.recoveredState.verifiedObjects == ["kept"])
    #expect(try fs.readFile(at: path, maxBytes: 4096) == prefix)
    try await journal.append(.operationCompleted)
    #expect(try OperationJournal.replay(fs: fs, path: path).completed)
}

@Test(arguments: followupTornTails)
func journalInvalidLineBeforeValidRecordRemainsCorrupt(tail: Data) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("journal")
    let prefix = try followupLines([followupPlanRecord()])
    // Put the valid suffix in a later read chunk to exercise streaming tail validation.
    let bytes = prefix + tail + Data(repeating: 0, count: 70_000) + Data([10]) + (try followupLines([.operationCompleted]))
    try fs.writeAtomically(bytes, to: path)
    try followupExpectCorrupt { _ = try OperationJournal.replay(fs: fs, path: path) }
    try followupExpectCorrupt { _ = try OperationJournal(fs: fs, path: path) }
    #expect(try fs.size(at: path) == Int64(bytes.count))
}

@Test(.timeLimit(.minutes(1)))
func journalCreationFinishesIfCancellationArrivesDuringOpen() async throws {
    let temp = try TempDir(); let ops = CreationSyncFaults(mode: .cancelDuringOpen)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let path = try SafeRelativePath("new/journal")
    // The last ancestor's creation sync cancels during openRegularDescriptors. It still
    // creates the file, so the append must finish its file and parent syncs afterwards.
    let task = Task { try OperationJournal(fs: fs, path: path) }
    _ = try await task.value
    #expect(try fs.itemType(at: path) == .regularFile)
    let calls = ops.state.withLock { $0.calls }
    #expect(calls.map(\.directory) == [true, false, true])
    #expect(calls.filter { !$0.directory }.map(\.durable) == [true])
}

@Test
func journalReopenHealsFailedCreationParentSync() throws {
    let temp = try TempDir(); let ops = CreationSyncFaults(mode: .failCreationParent)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let path = try SafeRelativePath("journal")
    #expect(throws: LauncherError.io("Injected creation parent sync failure")) { try OperationJournal(fs: fs, path: path) }
    #expect(try fs.itemType(at: path) == .regularFile)
    ops.state.withLock { $0.calls.removeAll() }
    _ = try OperationJournal(fs: fs, path: path)
    #expect(ops.state.withLock { $0.calls.map(\.directory) } == [false, true])
}

@Test
func zstdPlanRoundTripsAndSupportsPreflight() throws {
    let plan = try followupCompressedPlan()
    let decoded = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan))
    #expect(decoded.planDigest == plan.planDigest)
    try decoded.validate(supportedCodecs: Set(ChunkCodec.allCases))
    try decoded.validate()
    #expect(throws: LauncherError.io("codec unsupported: zstd")) { try decoded.validate(supportedCodecs: [.identity]) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func storedZstdPlanCompletesBeforeRequestedPlanOnlyAfterCommitStarted(commit: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let stored = try followupCompressedPlan(); let requested = try opPlan("requested", [("new", "abc")])
    _ = try await opSeed(fs, stored, commit: commit)
    let cdn = MockCDN()
    cdn.serve("object", data: try zstdVector("good")); cdn.serve("requested-0", data: Data("abc".utf8))
    let events = try await opCollect(opEngine(requested, temp.url, cdn).run())
    #expect(events.filter { $0 == .phase(.completed) }.count == 1)
    #expect(cdn.requestLog.map(\.path) == (commit ? ["object", "requested-0"] : ["requested-0"]))
    #expect(try fs.readFile(at: requested.files[0].path, maxBytes: 3) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)), arguments: [1, 2])
func mismatched206TotalRestartsWithoutRange(attempts: Int) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("part"); try fs.writeAtomically(Data("abc".utf8), to: path)
    let object = stagingObject("object", "abcdef"); let client = WrongTotalClient()
    let fetcher = ChunkFetcher(http: client, retry: RetryPolicy(maxAttempts: attempts, baseDelay: .zero, maxDelay: .zero), sleeper: InstantSleeper())
    if attempts == 1 {
        await #expect(throws: LauncherError.transport("invalid content range")) {
            try await fetcher.fetch(object, fs: fs, part: path, progress: { _ in })
        }
        #expect(try fs.size(at: path) == 0)
    } else {
        try await fetcher.fetch(object, fs: fs, part: path, progress: { _ in })
        #expect(client.ranges.withLock { $0 } == [3, nil])
        #expect(try fs.readFile(at: path, maxBytes: 6) == Data("abcdef".utf8))
    }
}

@Test(.timeLimit(.minutes(1)))
func oversizedStoredPlanFailsBeforeJSONDecoding() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("oversized", [("new", "abc")]); let path = try opPlanPath(plan)
    let handle = try fs.openForWriting(at: path, truncate: true)
    try handle.write(contentsOf: Data("not JSON".utf8))
    try handle.truncate(atOffset: UInt64(InstallPlan.maximumEncodedBytes + 1)); try handle.close()
    let cdn = MockCDN()
    await #expect(throws: LauncherError.fileTooLarge(path: path.resolved(against: temp.url).path, limit: InstallPlan.maximumEncodedBytes)) {
        _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    }
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.itemType(at: plan.files[0].path) == nil)
}

private func followupPlanRecord() throws -> JournalRecord {
    .planStored(planID: try SafeIdentifier("build"), planDigest: opDigest("plan"))
}
private func followupLines(_ records: [JournalRecord]) throws -> Data {
    var bytes = Data()
    for record in records { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
    return bytes
}
private func followupExpectCorrupt(_ body: () throws -> Void) throws {
    do { try body(); Issue.record("Expected journalCorrupt") }
    catch LauncherError.journalCorrupt(let reason) { #expect(!reason.isEmpty) }
}
private func followupCompressedPlan() throws -> InstallPlan {
    let object = compressedObject(try zstdVector("good"))
    return try stagingPlan([object], [compressedFile(object, path: "new")])
}
private final class WrongTotalClient: HTTPClient {
    let ranges = Mutex([Int64?]())
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let first = ranges.withLock { values in values.append(offset); return values.count == 1 }
        let head = first ? HTTPResponseHead(status: 206, contentLength: 3, contentRange: 3...5, totalLength: 7)
            : HTTPResponseHead(status: 200, contentLength: 6)
        let data = Mutex<Data?>(Data((first ? "def" : "abcdef").utf8))
        return (head, HTTPBody(next: { data.withLock { value in defer { value = nil }; return value } }, onCancel: {}))
    }
}
private final class CreationSyncFaults: FileOps {
    enum Mode { case cancelDuringOpen, failCreationParent }
    struct Call { let directory: Bool; let durable: Bool }
    struct State { var fileSynced = false; var cancelled = false; var failed = false; var calls: [Call] = [] }
    let state = Mutex(State())
    private let mode: Mode
    init(mode: Mode) { self.mode = mode }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var info = stat(); guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("fstat failed") }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        let actions = state.withLock { value -> (cancel: Bool, fail: Bool) in
            value.calls.append(Call(directory: directory, durable: durable))
            if !directory { value.fileSynced = true }
            if directory && mode == .cancelDuringOpen && !value.cancelled {
                value.cancelled = true; return (true, false)
            }
            if directory && mode == .failCreationParent && value.fileSynced && !value.failed {
                value.failed = true; return (false, true)
            }
            return (false, false)
        }
        if actions.cancel { withUnsafeCurrentTask { $0?.cancel() } }
        if actions.fail { throw LauncherError.io("Injected creation parent sync failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
