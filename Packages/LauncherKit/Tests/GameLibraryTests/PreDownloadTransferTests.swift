// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite(.timeLimit(.minutes(1))) struct PreDownloadTransferTests {
    @Test func containerStreamsOverlapAndRespectNormalConcurrencyLimit() async throws {
        let gate = CacheTransferGate(count: 35), hashes = Mutex([String: Int]())
        let fixture = try await CacheTransferFixture(count: 35, http: CacheTransferHTTP(size: 64, gate: gate))
        let library = fixture.library
        let transfer = Task {
            try await OperationWork.$objectHashObserver.withValue({ id in hashes.withLock { $0[id, default: 0] += 1 } }) {
                var events: [OperationEvent] = []
                for try await event in await library.resumePreDownload(GameDefinition.all[0]) { events.append(event) }
                return events
            }
        }
        defer { transfer.cancel(); gate.releaseAll() }
        // No body may finish until the normal 32-stream limit is occupied.
        // A serial loop cannot reach this handshake. Time is only a failure bound.
        try await cacheTransferHandshake(gate.started[31], transfer: transfer, gate: gate)
        #expect(gate.active == 32)
        gate.release[0].signal()
        try await cacheTransferHandshake(gate.started[32], transfer: transfer, gate: gate)
        #expect(gate.active == 32)
        gate.releaseAll()
        let events = try await transfer.value
        #expect(gate.peak == 32 && gate.active == 0)
        #expect(events.last == .phase(.completed))
        let state = try #require(try fixture.cache.load())
        #expect(state.completed && state.verified.count == 35)
        #expect(hashes.withLock { $0.count == 35 && $0.values.allSatisfy { $0 == 1 } })
        let progress = events.compactMap { event -> Int64? in
            if case .progress(let downloaded, let total, _, _) = event {
                #expect(total == 2_240)
                return downloaded
            }
            return nil
        }
        #expect(progress.last == 2_240 && progress == progress.sorted())
    }

    @Test(arguments: [
        CacheTransferLimits(concurrent: 2, objects: 20, bytes: 4_096, overlap: 2),
        CacheTransferLimits(concurrent: 8, objects: 2, bytes: 4_096, overlap: 2),
        CacheTransferLimits(concurrent: 8, objects: 20, bytes: 128, overlap: 2),
        CacheTransferLimits(concurrent: 8, objects: 20, bytes: 1, overlap: 1),
    ])
    func configuredConcurrencyAndPrefetchBoundsAreShared(limits: CacheTransferLimits) async throws {
        let gate = CacheTransferGate(count: 6), work = Mutex((active: 0, peak: 0, submitted: 0))
        let fixture = try await CacheTransferFixture(count: 6, http: CacheTransferHTTP(size: 64, gate: gate),
            maxConcurrentObjects: limits.concurrent, pipeline: PipelineConfiguration(prefetchBytes: limits.bytes, prefetchObjects: limits.objects))
        let library = fixture.library
        let transfer = Task {
            try await OperationWork.$observer.withValue({ event in
                work.withLock {
                    if event == .fetchTaskSubmitted { $0.active += 1; $0.submitted += 1; $0.peak = max($0.peak, $0.active) }
                    if event == .fetchTaskFinished { $0.active -= 1 }
                }
            }) { for try await _ in await library.resumePreDownload(GameDefinition.all[0]) {} }
        }
        defer { transfer.cancel(); gate.releaseAll() }
        try await cacheTransferHandshake(gate.started[limits.overlap - 1], transfer: transfer, gate: gate)
        #expect(gate.active == limits.overlap)
        gate.releaseAll(); try await transfer.value
        #expect(gate.peak == limits.overlap && gate.active == 0)
        #expect(work.withLock { $0.submitted == 6 && $0.active == 0 && $0.peak <= limits.overlap })
        #expect(try fixture.cache.load()?.completed == true)
    }

    @Test(arguments: CacheTransferCancellationPoint.allCases)
    func cancellationJoinsEveryStreamBeforeResumeAndLeavesNoReceiptForBlockedBodies(point: CacheTransferCancellationPoint) async throws {
        let gate = CacheTransferGate(count: 6)
        let between = TestEvent(), nextPull = TestEvent(), pulling = TestEvent()
        let released = TestEvent(), finishWorker = TestEvent()
        let afterStaging = Mutex(false), events = Mutex([OperationEvent]())
        let fixture = try await CacheTransferFixture(count: 6, http: CacheTransferHTTP(size: 64, gate: gate), maxConcurrentObjects: 2)
        let library = fixture.library
        let afterRelease: @Sendable () async -> Void = {
            guard point == .betweenPulls else { return }
            released.signal()
            _ = await Task.detached { try await finishWorker.wait() }.result
        }
        let transfer = Task {
            try await PreDownloadSession.$afterWorkerRelease.withValue(afterRelease) {
                try await OperationWork.$observer.withValue({ work in
                    if work == .pipelinePullWaiting && afterStaging.withLock({ $0 }) { pulling.signal() }
                }) {
                    for try await event in await library.resumePreDownload(GameDefinition.all[0]) {
                        events.withLock { $0.append(event) }
                        if point != .bodiesStarted && event == .phase(.staging) {
                            afterStaging.withLock { $0 = true }; between.signal()
                            // Cancel between next() calls without the test gate
                            // itself throwing. Always release/join the detached
                            // waiter, including on a failed handshake's cancellation.
                            try await withTaskCancellationHandler {
                                try await Task.detached { try await nextPull.wait() }.value
                            } onCancel: { nextPull.signal() }
                        }
                    }
                }
            }
        }
        defer { transfer.cancel(); nextPull.signal(); finishWorker.signal(); gate.releaseAll() }
        try await cacheTransferHandshake(gate.started[1], transfer: transfer, gate: gate)
        if point != .bodiesStarted { try await cacheTransferHandshake(between, transfer: transfer, gate: gate) }
        if point == .pendingPull {
            nextPull.signal()
            try await cacheTransferHandshake(pulling, transfer: transfer, gate: gate)
        }
        transfer.cancel()
        nextPull.signal()
        switch point {
        case .betweenPulls:
            // AsyncThrowingStream skips its unfolding closure when next() starts
            // in an already-cancelled task. Quiet exhaustion is not completion.
            try await transfer.value
        case .pendingPull:
            await #expect(throws: LauncherError.cancelled) { try await transfer.value }
        case .bodiesStarted:
            // The original CI interleaving: cancellation can land on either side
            // of next(). Require the typed error if it throws, but allow nil.
            do { try await transfer.value }
            catch { #expect(error as? LauncherError == .cancelled) }
        }
        #expect(!events.withLock { $0.contains(.phase(.completed)) })
        if point == .betweenPulls {
            try await cacheTransferHandshake(released, transfer: transfer, gate: gate)
        }
        // AppModel joins readers after termination. A completed drain must also
        // release exclusion, even while the worker's task is still returning.
        try await library.waitForPreDownloadDrain("genshin")
        try await library.waitUntilIdle("genshin")
        #expect(gate.active == 0)
        let paused = try #require(try fixture.cache.load())
        #expect(!paused.completed && paused.verified.isEmpty)
        let restart = fixture.restarted(http: CacheTransferHTTP(size: 64, gate: nil))
        for try await _ in await restart.resumePreDownload(GameDefinition.all[0]) {}
        #expect(try fixture.cache.load()?.completed == true)
        finishWorker.signal()
    }

    @Test(arguments: ["preDownload", "resumePreDownload", "update", "resume", "runnerResume"])
    func cancelledBeforeFirstPullMatchesOtherOperationStreams(route: String) async throws {
        let fixture = try await CacheTransferFixture(count: 1, http: CacheTransferHTTP(size: 64, gate: nil))
        let library = fixture.library, store = fixture.store
        let runner = OperationRunner(store: store, fetcher: ChunkFetcher(http: CacheTransferHTTP(size: 64, gate: nil),
            retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            disk: FixedDiskSpace(bytes: Int64.max), log: nil)
        let saved = try fixture.cache.load(), record = try await store.load("genshin")
        let consumer = Task {
            let stream: AsyncThrowingStream<OperationEvent, any Error>
            switch route {
            case "preDownload": stream = await library.preDownload(GameDefinition.all[0])
            case "resumePreDownload": stream = await library.resumePreDownload(GameDefinition.all[0])
            case "update": stream = await library.update(GameDefinition.all[0], approved: true)
            case "resume": stream = await library.resume(GameDefinition.all[0], approved: true)
            default: stream = await runner.resume("genshin", approved: true)
            }
            withUnsafeCurrentTask { $0?.cancel() }
            for try await _ in stream { Issue.record("Cancelled stream must not start work") }
        }
        try await consumer.value
        try await library.waitUntilIdle("genshin")
        #expect(try fixture.cache.load() == saved)
        #expect(try await store.load("genshin") == record)
    }

    @Test func concurrentRouteUsesTheExistingFetcherRetryPolicy() async throws {
        let cdn = MockCDN(), hashes = Mutex(0)
        cdn.serve("containers/0", data: Data(repeating: 0, count: 64))
        cdn.enqueueFault("containers/0", .status(503))
        let fixture = try await CacheTransferFixture(count: 1, http: cdn)
        try await OperationWork.$objectHashObserver.withValue({ _ in hashes.withLock { $0 += 1 } }) {
            for try await _ in await fixture.library.resumePreDownload(GameDefinition.all[0]) {}
        }
        #expect(cdn.requestLog.count == 2)
        #expect(hashes.withLock { $0 } == 1)
        #expect(try fixture.cache.load()?.completed == true)
    }
}

enum CacheTransferCancellationPoint: String, Sendable, CaseIterable {
    case bodiesStarted, betweenPulls, pendingPull
}

struct CacheTransferLimits: Sendable {
    let concurrent: Int, objects: Int
    let bytes: Int64
    let overlap: Int
}

/// Gates stream reads, rather than GET completion, so overlapping requests
/// remain live until the test explicitly releases a body. No polling or sleeps.
private final class CacheTransferGate: Sendable {
    private struct State { var started = 0, active = 0, peak = 0 }
    private let state = Mutex(State())
    let started: [TestEvent], release: [TestEvent]
    init(count: Int) {
        started = (0..<count).map { _ in TestEvent() }
        release = (0..<count).map { _ in TestEvent() }
    }
    var active: Int { state.withLock { $0.active } }
    var peak: Int { state.withLock { $0.peak } }
    func read(_ bytes: Data) async throws -> Data {
        let index = state.withLock { s in
            let index = s.started; s.started += 1; s.active += 1; s.peak = max(s.peak, s.active)
            return index
        }
        defer { state.withLock { $0.active -= 1 } }
        guard started.indices.contains(index) else { throw LauncherError.io("unexpected cache request") }
        started[index].signal()
        try await release[index].wait()
        return bytes
    }
    func releaseAll() { for event in release { event.signal() } }
}

private struct CacheTransferHTTP: HTTPClient {
    let size: Int
    let gate: CacheTransferGate?
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("unexpected metadata") }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard let index = Int(url.lastPathComponent), (0..<200).contains(index), offset == nil else {
            throw LauncherError.io("unexpected cache range")
        }
        let bytes = Data(repeating: UInt8(index), count: size)
        let body = CacheTransferBody(bytes: bytes, gate: gate)
        return (HTTPResponseHead(status: 200, contentLength: Int64(size)), HTTPBody(next: { try await body.next() }))
    }
}
private actor CacheTransferBody {
    let bytes: Data
    let gate: CacheTransferGate?
    var emitted = false
    init(bytes: Data, gate: CacheTransferGate?) { self.bytes = bytes; self.gate = gate }
    func next() async throws -> Data? {
        guard !emitted else { return nil }
        emitted = true
        if let gate { return try await gate.read(bytes) }
        return bytes
    }
}

private struct CacheTransferFixture: ~Copyable {
    let root: TempDir, installation: TempDir
    let cache: PreDownloadStore
    let library: GameLibrary
    let store: GameRecordStore
    init(count: Int, size: Int = 64, http: any HTTPClient,
        maxConcurrentObjects: Int = SpaceBudget.defaultMaxConcurrentObjects, pipeline: PipelineConfiguration = .default) async throws {
        let root = try TempDir(), installation = try TempDir()
        let paths = AppPaths(root: root.url), store = GameRecordStore(directory: paths.games)
        let fs = try ContainedFileSystem(root: installation.url)
        let cache = try PreDownloadStore(fs: fs)
        var containers: [String: PreDownloadContainer] = [:]
        for index in 0..<count {
            let digest = cacheDigest(Data(repeating: UInt8(index), count: size)), rawID = String(index)
            let id = SophonPlanner.patchContainerIdentity(id: rawID, digest: digest)
            let object = ChunkObject(id: id, urls: [URL(string: "https://cdn.hoyoverse.com/containers/" + rawID)!],
                transferSize: Int64(size), transferDigest: digest, decodedSize: Int64(size), decodedDigest: digest)
            containers[id] = PreDownloadContainer(rawID: rawID, object: object)
        }
        let plan = try PreDownloadPlan(edition: "genshin", region: .global, installation: fs.rootIdentity(), sourceTag: "1.0", targetTag: "2.0",
            buildID: "future", patchID: "patch", categories: [PreDownloadCategory(id: "game", matchingField: "game", containers: Array(containers.keys))],
            voices: [], containers: containers)
        try cache.replace(plan)
        let installed = InstalledBuild(tag: "1.0", buildID: "installed", categories: [], voices: [])
        try await store.save(GameRecord(installPath: installation.url, ownership: .created, executable: SafeRelativePath("game.exe"),
            installed: installed, installIdentity: fs.rootIdentity()), for: "genshin")
        let disk = FixedDiskSpace(bytes: Int64.max)
        let library = GameLibrary(paths: paths, api: DeliveryAPI(http: http), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 2), sleeper: InstantSleeper()), disk: disk, log: nil,
            maxConcurrentObjects: maxConcurrentObjects, pipeline: pipeline),
            store: store, disk: disk, log: nil)
        self.root = root; self.installation = installation; self.cache = cache; self.library = library; self.store = store
    }
    func restarted(http: any HTTPClient) -> GameLibrary {
        let disk = FixedDiskSpace(bytes: Int64.max)
        return GameLibrary(paths: AppPaths(root: root.url), api: DeliveryAPI(http: http), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 2), sleeper: InstantSleeper()), disk: disk, log: nil),
            store: store, disk: disk, log: nil)
    }
}

private func cacheTransferHandshake<Value: Sendable>(_ event: TestEvent, transfer: Task<Value, any Error>, gate: CacheTransferGate) async throws {
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await event.wait() }
            group.addTask {
                try await ContinuousClock().sleep(for: .seconds(10))
                throw LauncherError.io("cache transfer handshake deadline")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    } catch {
        transfer.cancel(); gate.releaseAll()
        _ = await transfer.result
        throw error
    }
}
