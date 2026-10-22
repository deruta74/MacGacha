// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import DownloadEngine
import TestSupport

@Test func delayedProgressCannotOverwriteANewerDeliveredSnapshot() async throws {
    let plan = try opPlan("ordered", [("out", "abcd")]), tracker = PipelineProgress(plan), channel = PipelineChannel()
    tracker.initialize(downloaded: 0, total: 4, credited: [], predicted: Set(plan.objects.keys))
    let older = tracker.snapshot()
    _ = tracker.update("ordered-0", 3)
    let newer = tracker.snapshot()
    channel.send(newer)
    #expect(try await channel.next() == newer.event)
    channel.send(older) // Deterministic descheduling of A until B is delivered.
    channel.send(.fileVerified(plan.files[0].path))
    channel.finish()
    #expect(try await channel.next() == .fileVerified(plan.files[0].path))
    #expect(try await channel.next() == nil)
}

@Test func recoveredCommittingStagingIsFullSyncedBeforeRename() async throws {
    let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), cdn = MockCDN()
    let plan = try opPlan("recovered-sync", [("a", "correct")])
    _ = try await opSeed(fs, plan, commit: true)
    try fs.writeAtomically(Data("correct".utf8), to: opStaged(plan, plan.files[0].path))
    let ops = RecoverySyncOrder()
    #expect(try await opCollect(InstallOperation(plan: plan, installRoot: root.url, fetcher: stagingFetcher(cdn), fileOps: ops).run()).last == .phase(.completed))
    #expect(ops.order.withLock { $0 } == ["fullSync", "rename"])
    #expect(cdn.requestLog.isEmpty)
}

@Test(arguments: [false, true]) func committingRecoveryVerifiesAndFullSyncsBeforeStagedJournal(corrupt: Bool) async throws {
    let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), cdn = MockCDN()
    let plan = try opPlan("durability", [("a", "correct")]); opServe(cdn, plan, ["correct"])
    _ = try await opSeed(fs, plan, commit: true)
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    if corrupt { try fs.writeAtomically(Data("CORRUPT".utf8), to: opStaged(plan, plan.files[0].path)) }
    let ops = RecoverySyncOrder()
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: root.url, fetcher: stagingFetcher(cdn), fileOps: ops).run())
    #expect(events.last == .phase(.completed))
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 7) == Data("correct".utf8))
    #expect(ops.order.withLock { $0 } == ["fullSync", "fileStaged", "rename"])
}

@Test(.timeLimit(.minutes(1))) func oversizedFileBoundsOutstandingFetchTasks() async throws {
    let root = try TempDir(), cdn = MockCDN(), gate = ReviewHeaderGate(cdn: cdn), work = OutstandingFetchWork()
    let count = 4096, digest = opDigest("x")
    let objects = (0..<count).map { stagingObject("p\($0)", "x") }
    for object in objects { cdn.serve(object.id, data: Data("x".utf8)) }
    let file = FileTask(path: try SafeRelativePath("large"), size: Int64(count), digest: opDigest(String(repeating: "x", count: count)),
        extents: objects.enumerated().map { Extent(source: .chunk(id: $0.element.id), fileOffset: Int64($0.offset), length: 1, digest: digest) })
    let plan = try stagingPlan(objects, [file])
    let task = Task {
        try await OperationWork.$observer.withValue({ work.record($0) }) {
            try await opCollect(InstallOperation(plan: plan, installRoot: root.url, fetcher: stagingFetcher(gate)).run())
        }
    }
    defer { gate.release(); task.cancel() }
    await gate.waitFor32()
    #expect(work.peak.withLock { $0 } <= 32)
    gate.release()
    #expect(try await task.value.last == .phase(.completed))
    #expect(work.peak.withLock { $0 } <= 32)
    #expect(cdn.requestLog.count == count)
}

private final class OutstandingFetchWork: Sendable {
    private let active = Mutex(0)
    let peak = Mutex(0)
    func record(_ work: OperationWork) {
        switch work {
        case .fetchTaskSubmitted:
            let n = active.withLock { $0 += 1; return $0 }; peak.withLock { $0 = max($0, n) }
        case .fetchTaskFinished: active.withLock { $0 -= 1 }
        default: break
        }
    }
}
private final class ReviewHeaderGate: HTTPClient {
    let cdn: MockCDN
    private let count = Mutex(0)
    private let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let released = AsyncStream<Void>.makeStream()
    init(cdn: MockCDN) { self.cdn = cdn }
    func release() { released.continuation.finish() }
    func waitFor32() async { var iterator = ready.stream.makeAsyncIterator(); _ = await iterator.next() }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let n = count.withLock { $0 += 1; return $0 }
        if n == 32 { ready.continuation.yield(()) }
        var iterator = released.stream.makeAsyncIterator(); _ = await iterator.next()
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}
private final class RecoverySyncOrder: FileOps {
    let order = Mutex<[String]>([])
    private func path(_ descriptor: Int32) -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if path(descriptor).hasSuffix("journal.jsonl"), String(decoding: bytes, as: UTF8.self).contains("fileStaged") { order.withLock { $0.append("fileStaged") } }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if durable, path(descriptor).contains("/files/") { order.withLock { $0.append("fullSync") } }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if source == "a", destination == "a" { order.withLock { $0.append("rename") } }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}
