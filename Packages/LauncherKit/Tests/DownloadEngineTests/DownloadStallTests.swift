// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1))) func blockedObjectReceiptDoesNotHoldTransferSlot() async throws {
    let root = try TempDir(), cdn = MockCDN(), ops = StallJournalOps()
    let fs = try ContainedFileSystem(root: root.url, fileOps: ops)
    let plan = try opPlan("receipt-slot", [("a", "first"), ("b", "second")])
    opServe(cdn, plan, ["first", "second"])
    let journal = try stagingJournal(fs, plan), http = StallTransferHTTP(cdn: cdn, ops: ops)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(http), journal: journal,
        disk: FixedDiskSpace(bytes: Int64.max), maxConcurrentObjects: 1,
        pipeline: PipelineConfiguration(prefetchBytes: 1024, prefetchObjects: 2, assemblies: 2))
    let task = Task { try await collectStaging(stager.stage(files: plan.files)) }
    defer { ops.release(); task.cancel() }
    try await ops.blocked.wait()
    try await http.secondStarted.wait()
    #expect(!ops.timedOut.withLock { $0 }, "The next transfer must start while the first receipt is blocked")
    #expect(try await task.value.filter { if case .fileVerified = $0 { true } else { false } }.count == 2)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func stagedOutputsSyncAfterDrainBeforeBatchBoundary(copy: Bool) async throws {
    let root = try TempDir(), cdn = MockCDN(), ops = BatchSyncOps()
    var plan = try opPlan("batch-sync", [("a", "first"), ("b", "second")])
    opServe(cdn, plan, ["first", "second"])
    if copy {
        plan = InstallPlan(id: plan.id, objects: plan.objects, files: plan.files.enumerated().map { index, file in
            FileTask(path: file.path, size: file.size, digest: file.digest, extents: file.extents,
                recipe: .copy(container: "batch-sync-\(index)", offset: 0, length: file.size))
        })
    }
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: root.url,
        fetcher: stagingFetcher(cdn), fileOps: ops).run())
    #expect(events.last == .phase(.completed))
    let expected = copy
        ? ["staged", "sync", "batch", "commit", "rename", "staged", "sync", "batch", "commit", "rename"]
        : ["staged", "staged", "sync", "sync", "batch", "commit", "rename", "rename"]
    #expect(ops.events.withLock { $0 } == expected)
    let fs = try ContainedFileSystem(root: root.url)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 6) == Data("first".utf8))
    #expect(try fs.readFile(at: plan.files[1].path, maxBytes: 6) == Data("second".utf8))
}

@Test(.timeLimit(.minutes(1))) func failedBatchOutputSyncCannotStartCommit() async throws {
    let root = try TempDir(), cdn = MockCDN(), ops = BatchSyncOps(failSync: true)
    let plan = try opPlan("failed-batch-sync", [("a", "first"), ("b", "second")])
    opServe(cdn, plan, ["first", "second"])
    let fs = try ContainedFileSystem(root: root.url)
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    await #expect(throws: LauncherError.io("Injected batch sync failure")) {
        try await opCollect(InstallOperation(plan: plan, installRoot: root.url,
            fetcher: stagingFetcher(cdn), fileOps: ops).run())
    }
    #expect(ops.events.withLock { $0 } == ["staged", "staged", "sync"])
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 5) == Data("old".utf8))
    #expect(try fs.size(at: plan.files[1].path) == nil)
    #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches.isEmpty)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try await opCollect(opEngine(plan, root.url, cdn).run()).last == .phase(.completed))
}

@Test(.timeLimit(.minutes(1))) func preCommitReceiptCannotPublishLostStagedBytes() async throws {
    let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), cdn = MockCDN()
    let plan = try opPlan("lost-staged-data", [("a", "first")])
    _ = try await opSeed(fs, plan, commit: false)
    // Model lost/reordered data with a surviving fileStaged receipt. Keeping
    // the same size proves resume checks the digest before the new sync point.
    try fs.writeAtomically(Data("WRONG".utf8), to: opStaged(plan, plan.files[0].path))
    opServe(cdn, plan, ["first"])
    #expect(try await opCollect(opEngine(plan, root.url, cdn).run()).last == .phase(.completed))
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 5) == Data("first".utf8))
}

private func stallDescriptorPath(_ descriptor: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return "" }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

private final class StallJournalOps: FileOps, @unchecked Sendable {
    let blocked = TestEvent(), timedOut = Mutex(false)
    private let condition = NSCondition()
    private var released = false
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if stallDescriptorPath(descriptor).hasSuffix("journal.jsonl"),
            String(decoding: bytes, as: UTF8.self).contains("objectVerified") {
            // This hook runs on the journal's Dispatch executor. The deadline
            // only bounds a broken implementation; successful runs use events.
            condition.lock()
            blocked.signal()
            let deadline = Date().addingTimeInterval(10)
            while !released {
                if !condition.wait(until: deadline) { timedOut.withLock { $0 = true }; break }
            }
            condition.unlock()
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

private final class StallTransferHTTP: HTTPClient {
    let secondStarted = TestEvent()
    private let cdn: MockCDN, ops: StallJournalOps
    private let requests = Mutex(0)
    init(cdn: MockCDN, ops: StallJournalOps) { self.cdn = cdn; self.ops = ops }
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("Unexpected POST") }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if requests.withLock({ $0 += 1; return $0 }) == 2 {
            try await ops.blocked.wait()
            secondStarted.signal()
            ops.release()
        }
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}

private final class BatchSyncOps: FileOps {
    let events = Mutex<[String]>([])
    private let failSync: Bool
    init(failSync: Bool = false) { self.failSync = failSync }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if stallDescriptorPath(descriptor).hasSuffix("journal.jsonl"), !bytes.isEmpty,
            let record = try? JSONDecoder().decode(JournalRecord.self, from: Data(bytes)) {
            switch record {
            case .fileStaged: events.withLock { $0.append("staged") }
            case .batchStarted: events.withLock { $0.append("batch") }
            case .commitStarted: events.withLock { $0.append("commit") }
            default: break
            }
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if stallDescriptorPath(descriptor).contains("/files/"), !durable {
            events.withLock { $0.append("sync") }
            if failSync { throw LauncherError.io("Injected batch sync failure") }
        }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if stallDescriptorPath(sourceDirectory).contains("/files") { events.withLock { $0.append("rename") } }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}
