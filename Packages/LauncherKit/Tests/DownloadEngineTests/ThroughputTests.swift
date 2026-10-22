// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Dispatch
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1))) func disposablePartsDoNotRequestFullSync() async throws {
    let temp = try TempDir(), ops = ThroughputFileOps(), fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let cdn = MockCDN(), object = stagingObject("part", "payload")
    cdn.serve(object.id, data: Data("payload".utf8))
    try await stagingFetcher(cdn).fetch(object, fs: fs, part: SafeRelativePath("data.part"), progress: { _ in })
    #expect(ops.partFullSyncs.withLock { $0 } == 0)
    #expect(try fs.readFile(at: SafeRelativePath("data.part"), maxBytes: 7) == Data("payload".utf8))
}

@Test(.timeLimit(.minutes(1))) func recoveredCompressedPartWithoutTransferDigestIsReverifiedBeforeAssembly() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let good = try zstdVector("good"), wrong = try zstdVector("wrong")
    #expect(good.count == wrong.count)
    let payload = String(repeating: "A", count: 4096), digest = stagingDigest(payload)
    let object = ChunkObject(id: "compressed", urls: [URL(string: "https://cdn.test/compressed")!],
        transferSize: Int64(good.count), decodedSize: 4096, decodedDigest: digest, codec: .zstd)
    let plan = try stagingPlan([object], [stagingFile("out", payload, [stagingChunk(object.id, payload)])])
    try fs.writeAtomically(JSONEncoder().encode(plan), to: opPlanPath(plan))
    let journal = try stagingJournal(fs, plan)
    try fs.writeAtomically(wrong, to: objectPath(plan, object))
    try await journal.append(.objectVerified(id: object.id))
    cdn.serve(object.id, data: good)
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: temp.url,
        fetcher: stagingFetcher(cdn), fileOps: ThroughputFileOps(requireFetch: cdn)).run())
    #expect(events.last == .phase(.completed) && cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 4096) == Data(payload.utf8))
}

@Test(.timeLimit(.minutes(1))) func sharedCorruptionQuiescesReadersBeforeReplacingThePart() async throws {
    let temp = try TempDir(), cdn = MockCDN(), encoded = try zstdVector("good")
    let payload = String(repeating: "A", count: 4096), digest = stagingDigest(payload)
    let object = ChunkObject(id: "shared-corrupt", urls: [URL(string: "https://cdn.test/shared-corrupt")!],
        transferSize: Int64(encoded.count), decodedSize: 4096, decodedDigest: digest, codec: .zstd)
    let files = try (0..<20).map { try stagingFile("out\($0)", payload, [stagingChunk(object.id, payload)]) }
    let plan = try stagingPlan([object], files)
    cdn.serve(object.id, data: encoded); cdn.enqueueFault(object.id, .corruptByte(at: 0))
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn)).run())
    #expect(events.last == .phase(.completed) && cdn.requestLog.count == 2)
    let fs = try ContainedFileSystem(root: temp.url)
    for file in files { #expect(try fs.readFile(at: file.path, maxBytes: 4096) == Data(payload.utf8)) }
}

@Test(.timeLimit(.minutes(1))) func stagedFilesUseFsyncBeforeCommitBoundaries() async throws {
    let temp = try TempDir(), ops = ThroughputFileOps(), fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let cdn = MockCDN(), object = stagingObject("object", "data")
    cdn.serve(object.id, data: Data("data".utf8))
    let file = try stagingFile("output", "data", [stagingChunk(object.id, "data")])
    let plan = try stagingPlan([object], [file]), journal = try stagingJournal(fs, plan)
    _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: [file]))
    #expect(ops.outputSyncs.withLock { $0 } == [false])
    #expect(try OperationJournal.replay(fs: fs, path: journalPath(plan)).stagedFiles == [file.path])
}

@Test(.timeLimit(.minutes(1))) func defaultTransfersReach32AcrossSingleChunkFiles() async throws {
    let temp = try TempDir(), cdn = MockCDN(), http = HeaderGateHTTP(cdn: cdn)
    let plan = try opPlan("parallel", (0..<40).map { ("out\($0)", "payload") })
    opServe(cdn, plan, Array(repeating: "payload", count: 40))
    let task = Task { try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(http)).run()) }
    defer { http.release(); task.cancel() }
    await http.waitFor32()
    #expect(http.peak.withLock { $0 } == 32)
    http.release()
    #expect(try await task.value.last == .phase(.completed))
    #expect(cdn.requestLog.count == 40)
}

@Test(.timeLimit(.minutes(1))) func streamingProgressArrivesBeforeAnyFileIsVerified() async throws {
    let temp = try TempDir(), cdn = MockCDN(), gate = ProgressBodyGate()
    let body = String(repeating: "P", count: 262_144), plan = try opPlan("stream", [("output", body)])
    opServe(cdn, plan, [body])
    let http = ProgressGateHTTP(cdn: cdn, gate: gate)
    var samples: [(Int64, Int64)] = [], sawPartial = false, verified = false
    defer { gate.release() }
    for try await event in try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(http)).run() {
        if case .fileVerified = event { verified = true }
        if case .progress(let done, let total, _, _) = event {
            samples.append((done, total))
            if done > 0 && done < total { #expect(!verified); sawPartial = true; gate.release() }
        }
    }
    #expect(sawPartial && verified)
    #expect(samples.allSatisfy { $0.0 <= $0.1 })
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    #expect(samples.last?.0 == 262_144 && samples.last?.1 == 262_144)
}

private final class HeaderGateHTTP: HTTPClient {
    let cdn: MockCDN, peak = Mutex(0)
    private let active = Mutex(0)
    private let reached = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let unblocked = AsyncStream<Void>.makeStream()
    init(cdn: MockCDN) { self.cdn = cdn }
    func release() { unblocked.continuation.finish() }
    func waitFor32() async { for await _ in reached.stream { return } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let count = active.withLock { $0 += 1; return $0 }
        defer { active.withLock { $0 -= 1 } }
        peak.withLock { $0 = max($0, count) }
        if count == 32 { reached.continuation.yield(()) }
        var iterator = unblocked.stream.makeAsyncIterator(); _ = await iterator.next()
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}
private final class ProgressBodyGate: Sendable {
    private let stream = AsyncStream<Void>.makeStream()
    func release() { stream.continuation.finish() }
    func wait() async { var iterator = stream.stream.makeAsyncIterator(); _ = await iterator.next() }
}
private struct ProgressGateHTTP: HTTPClient {
    let cdn: MockCDN, gate: ProgressBodyGate
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let (head, body) = try await cdn.get(url, byteRangeFrom: offset)
        let iterator = ProgressGateIterator(body.makeAsyncIterator(), gate: gate)
        return (head, HTTPBody(next: { try await iterator.next() }))
    }
}
private actor ProgressGateIterator {
    private var iterator: HTTPBody.AsyncIterator
    private let gate: ProgressBodyGate
    private var calls = 0
    init(_ iterator: HTTPBody.AsyncIterator, gate: ProgressBodyGate) { self.iterator = iterator; self.gate = gate }
    func next() async throws -> Data? {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .milliseconds(100)) }
        else { await gate.wait() }
        var iterator = self.iterator
        let piece = try await iterator.next(); self.iterator = iterator
        return piece
    }
}

@Test(.timeLimit(.minutes(1))) func downloadsUpcomingFilesWhileEarlierFileAssembles() async throws {
    let temp = try TempDir(), ops = ThroughputFileOps(blockAssembly: true)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops), cdn = MockCDN()
    let objects = (0..<8).map { stagingObject("p\($0)", "data") }
    let files = try objects.enumerated().map { try stagingFile("f\($0.offset)", "data", [stagingChunk($0.element.id, "data")]) }
    for object in objects { cdn.serve(object.id, data: Data("data".utf8)) }
    let plan = try stagingPlan(objects, files), journal = try stagingJournal(fs, plan)
    let stager = try stagingEngine(plan, fs, cdn, journal)
    let task = Task { try await collectStaging(stager.stage(files: files)) }
    defer { ops.release(); task.cancel() }
    await ops.waitForAssembly()
    #expect(cdn.requestLog.count > 1)
    ops.release()
    #expect(try await task.value.filter { if case .fileVerified = $0 { true } else { false } }.count == 8)
}

@Test(.timeLimit(.minutes(1))) func concurrentAssemblyKeepsSharedPartsAndUsesLocalFallbacks() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let shared = stagingObject("shared", "shared"), fallback = stagingObject("fallback", "local")
    cdn.serve(shared.id, data: Data("shared".utf8)); cdn.serve(fallback.id, data: Data("local".utf8))
    try fs.writeAtomically(Data("local".utf8), to: SafeRelativePath("good"))
    try fs.writeAtomically(Data("WRONG".utf8), to: SafeRelativePath("bad"))
    let files = try (0..<8).map { i in
        try stagingFile("out\(i)", "sharedlocal", [stagingChunk(shared.id, "shared"),
            Extent(source: .local(path: SafeRelativePath(i % 2 == 0 ? "good" : "bad"), offset: 0),
                fileOffset: 6, length: 5, digest: fallback.decodedDigest, fallbackChunkID: fallback.id)])
    }
    let plan = try stagingPlan([shared, fallback], files), gate = AssemblyObservationGate()
    let task = Task {
        try await OperationWork.$observer.withValue({ gate.observe($0) }) {
            try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn)).run())
        }
    }
    defer { gate.release(); task.cancel() }
    await gate.waitForConcurrentWorkers()
    #expect(gate.peak.withLock { $0 } >= 2)
    #expect(!gate.timedOut.withLock { $0 })
    gate.release()
    #expect(try await task.value.last == .phase(.completed))
    #expect(cdn.requestLog.count == 2)
    for file in files { #expect(try fs.readFile(at: file.path, maxBytes: 11) == Data("sharedlocal".utf8)) }
    #expect(try fs.readFile(at: SafeRelativePath("bad"), maxBytes: 5) == Data("WRONG".utf8))
}

@Test(.timeLimit(.minutes(1))) func pipelineCancellationResumesPartialTransfersAndFinishesProgress() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let bodies = [String(repeating: "a", count: 32_768)] + (1..<8).map { String(repeating: Character(String($0)), count: 131_072) }
    let plan = try opPlan("streaming", bodies.enumerated().map { ("out\($0.offset)", $0.element) })
    opServe(cdn, plan, bodies)
    let ops = ThroughputFileOps()
    let operation = try InstallOperation(plan: plan, installRoot: temp.url,
        fetcher: stagingFetcher(SlowPipelineHTTP(cdn: cdn, parts: ops)), fileOps: ops)
    let first = Task {
        do {
            for try await event in operation.run() {
                if event == .fileVerified(plan.files[0].path) { withUnsafeCurrentTask { $0?.cancel() } }
            }
            #expect(Task.isCancelled) // AsyncThrowingStream may end with nil on cancellation.
        } catch LauncherError.cancelled {}
    }
    try await first.value
    let state = try OperationJournal.replay(fs: fs, path: opJournal(plan))
    #expect(state.stagedFiles.contains(plan.files[0].path) && !state.completed)
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn)).run())
    let samples = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let downloaded, let total, _, _) = event { (downloaded, total) } else { nil }
    }
    #expect((samples.first?.0 ?? 0) >= 32_768)
    #expect(samples.allSatisfy { $0.0 <= $0.1 })
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    #expect(samples.last?.0 == samples.last?.1 && events.last == .phase(.completed))
    #expect(cdn.requestLog.contains { ($0.rangeFrom ?? 0) > 0 })
    for (file, body) in zip(plan.files, bodies) { #expect(try fs.readFile(at: file.path, maxBytes: 131_072) == Data(body.utf8)) }
}

private struct SlowPipelineHTTP: HTTPClient {
    let cdn: MockCDN
    let parts: ThroughputFileOps
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if url.lastPathComponent == "streaming-0" { await parts.waitForPart() }
        let (head, body) = try await cdn.get(url, byteRangeFrom: offset)
        if url.lastPathComponent == "streaming-0" { return (head, body) }
        let iterator = SlowPipelineIterator(body.makeAsyncIterator())
        return (head, HTTPBody(next: { try await iterator.next() }))
    }
}
private actor SlowPipelineIterator {
    private var iterator: HTTPBody.AsyncIterator
    private var read = false
    init(_ iterator: HTTPBody.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> Data? {
        if read { try await Task.sleep(for: .seconds(3600)) }
        read = true
        var iterator = self.iterator
        let next = try await iterator.next()
        self.iterator = iterator
        return next
    }
}

private final class AssemblyObservationGate: Sendable {
    let peak = Mutex(0)
    private let active = Mutex(0)
    private let gate = BoundedIOGate()
    let timedOut = Mutex(false)
    private let concurrent = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func release() { gate.release() }
    func waitForConcurrentWorkers() async { for await _ in concurrent.stream { return } }
    func observe(_ work: OperationWork) {
        if work == .assemblyFinished { active.withLock { $0 -= 1 }; return }
        guard work == .assemblyStarted else { return }
        let count = active.withLock { $0 += 1; return $0 }
        peak.withLock { $0 = max($0, count) }
        if count >= 2 { concurrent.continuation.yield(()) }
        do { try gate.wait() } catch { timedOut.withLock { $0 = true }; concurrent.continuation.finish() }
    }
}

final class ThroughputFileOps: FileOps {
    let partFullSyncs = Mutex(0)
    let outputSyncs = Mutex<[Bool]>([])
    private let blockAssembly: Bool
    private let gate = BoundedIOGate()
    private let assembly = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let partWritten = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let requireFetch: MockCDN?
    init(blockAssembly: Bool = false, requireFetch: MockCDN? = nil) { self.blockAssembly = blockAssembly; self.requireFetch = requireFetch }
    func waitForAssembly() async { for await _ in assembly.stream { return } }
    func waitForPart() async { for await _ in partWritten.stream { return } }
    func release() { gate.release() }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if descriptorPath(descriptor).contains("/files/"), let requireFetch, requireFetch.requestLog.isEmpty {
            throw LauncherError.io("Unverified recovered part reached assembly")
        }
        if blockAssembly, descriptorPath(descriptor).contains("/files/") {
            assembly.continuation.yield(())
            try gate.wait()
        }
        let count = try SystemFileOps().write(descriptor, bytes: bytes)
        if descriptorPath(descriptor).hasSuffix(".part") { partWritten.continuation.yield(()) }
        return count
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if durable, descriptorPath(descriptor).hasSuffix(".part") { partFullSyncs.withLock { $0 += 1 } }
        if descriptorPath(descriptor).contains("/files/") { outputSyncs.withLock { $0.append(durable) } }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
    private func descriptorPath(_ fd: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// Deliberately blocks an I/O worker to model slow storage. This must run on
/// BlockingIO's Dispatch executor, never a cooperative worker. Bounded waits
/// and broadcast release prevent a broken test from retaining workers forever.
private final class BoundedIOGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func wait() throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(30)
        while !released {
            try Task.checkCancellation()
            guard condition.wait(until: min(deadline, Date().addingTimeInterval(0.1))) || Date() < deadline else {
                throw LauncherError.io("I/O test gate timed out")
            }
        }
    }
}
