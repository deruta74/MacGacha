// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia
import CoreVideo
import Synchronization
import Testing
import TestSupport
import LauncherCore
@testable import BackdropVideo

@Suite(.timeLimit(.minutes(1))) @MainActor struct PlayerTests {
    @Test func preparingKeepsStillUntilFrameIsEnqueuedAndDisplayable() async throws {
        let source = TestFrameSource(), sink = TestVideoSink(), player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        var requests = source.requests.stream.makeAsyncIterator()
        let url = URL(fileURLWithPath: "/a.webm")
        player.play(url)
        #expect(player.state == .preparing)
        _ = await requests.next()
        sink.makeReady()
        #expect(player.state == .preparing)
        sink.isDisplayable = false
        source.send(.success(try testFrame()))
        _ = await requests.next()
        #expect(sink.frames.count == 1 && player.state == .preparing)
        sink.makeReady()
        #expect(player.state == .playing && player.sourceURL == url)
        let work = player.workTask; player.stop(); await work?.value
        #expect(player.state == .stopped && source.stops == 1)
    }
    @Test func cancelledPumpCannotConsumeReplacementPreparation() async throws {
        let old = TestFrameSource(), replacement = TestFrameSource(), sink = TestVideoSink()
        let a = URL(fileURLWithPath: "/a.webm"), b = URL(fileURLWithPath: "/b.webm")
        let player = BackdropVideoPlayer(sink: sink, makeSource: { $0 == a ? old : replacement })
        // Park B synchronously before its pump starts so only A can consume preparation.
        player.onStateChange = { [weak player] url, state in
            if url == b && state == .preparing { player?.pause() }
        }
        player.play(a)
        let cancelled = player.workTask
        player.play(b)
        await cancelled?.value
        #expect(sink.preparations == 0)
        #expect(old.count == 0 && replacement.count == 0)
        #expect(player.sourceURL == b && player.state == .preparing)

        var requests = replacement.requests.stream.makeAsyncIterator()
        player.resume(); _ = await requests.next()
        #expect(sink.preparations == 1)
        replacement.send(.success(try testFrame())); _ = await requests.next()
        sink.makeReady()
        #expect(player.sourceURL == b && player.state == .playing)
        let work = player.workTask; player.stop(); await work?.value
    }
    @Test func pauseStopsFeedingAndResumeRetainsPendingFrame() async throws {
        let source = TestFrameSource(), sink = TestVideoSink(), player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        let waiting = player.workTask
        player.pause(); source.send(.success(try testFrame()))
        await waiting?.value
        #expect(sink.frames.isEmpty && player.isPaused && sink.rates.last == false)
        player.resume(); _ = await requests.next()
        #expect(sink.frames.count == 1 && !player.isPaused)
        let work = player.workTask; player.stop(); await work?.value
    }
    @Test func pauseResumeDoesNotPrepareOrFlushTheSameSourceAgain() async throws {
        let source = TestFrameSource(), sink = TestVideoSink(), player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        source.send(.success(try testFrame())); _ = await requests.next()
        sink.makeReady()
        let work = player.workTask
        player.pause(); source.send(.success(nil)); await work?.value
        player.resume(); _ = await requests.next()
        #expect(sink.preparations == 1 && sink.frames.count == 1)
        #expect(player.state == .playing)
        let resumed = player.workTask; player.stop(); await resumed?.value
    }
    @Test(arguments: [0, 100, 101])
    func reanchorsOnlyWhenAFrameExceedsTheMinimumTolerance(lateness: Int) async throws {
        let source = TestFrameSource(), sink = TestVideoSink()
        let player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        defer { player.stop() }
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        source.send(.success(try testFrame())); _ = await requests.next()
        sink.makeReady()

        let second = CMTime(value: 40, timescale: 1_000)
        sink.advanceClock(by: CMTime(value: Int64(40 + lateness), timescale: 1_000))
        source.send(.success(try testFrame(at: second))); _ = await requests.next()
        source.send(.success(try testFrame(at: CMTime(value: 80, timescale: 1_000)))); _ = await requests.next()

        #expect(sink.alignments == (lateness > 100 ? [second] : []))
        if lateness > 100 { #expect(sink.enqueueTimes.dropFirst() == [second, second]) }
        #expect(sink.frames.count == 3 && player.state == .playing)
    }
    @Test func slowFramesUseTwoFrameIntervalsAsTolerance() async throws {
        let source = TestFrameSource(), sink = TestVideoSink()
        let player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        defer { player.stop() }
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        source.send(.success(try testFrame())); _ = await requests.next()
        sink.makeReady()

        sink.advanceClock(by: CMTime(value: 300, timescale: 1_000))
        source.send(.success(try testFrame(at: CMTime(value: 100, timescale: 1_000)))); _ = await requests.next()
        #expect(sink.alignments.isEmpty)

        let third = CMTime(value: 200, timescale: 1_000)
        sink.advanceClock(by: CMTime(value: 101, timescale: 1_000))
        source.send(.success(try testFrame(at: third))); _ = await requests.next()
        #expect(sink.alignments == [third])
    }
    @Test(arguments: [false, true])
    func longPauseResumesAtNormalPace(frameWasLateBeforePause: Bool) async throws {
        let source = TestFrameSource(), sink = TestVideoSink()
        let player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        defer { player.stop() }
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        source.send(.success(try testFrame())); _ = await requests.next()
        sink.makeReady()

        let second = CMTime(value: 40, timescale: 1_000)
        let pauseTime = CMTime(value: frameWasLateBeforePause ? 2_000 : 40, timescale: 1_000)
        sink.advanceClock(by: pauseTime)
        let pausedWork = player.workTask
        player.pause()
        sink.advanceClock(by: CMTime(value: 600, timescale: 1))
        source.send(.success(try testFrame(at: second)))
        await pausedWork?.value
        #expect(sink.rates == [true, false])
        #expect(sink.currentTime == pauseTime)
        #expect(sink.frames.count == 1 && sink.alignments.isEmpty)

        player.resume(); _ = await requests.next()
        let third = CMTime(value: 80, timescale: 1_000)
        sink.advanceClock(by: CMTime(value: 40, timescale: 1_000))
        source.send(.success(try testFrame(at: third))); _ = await requests.next()
        #expect(sink.rates == [true, false, true])
        #expect(sink.alignments == (frameWasLateBeforePause ? [second] : []))
        #expect(sink.enqueueTimes == [.zero, second, third])
        #expect(sink.frames.count == 3 && player.state == .playing)
    }
    @Test func lateFailureAndReadyCallbackCannotChangeNewSource() async throws {
        let old = TestFrameSource(retainOnStop: true), new = TestFrameSource(), sink = TestVideoSink()
        let player = BackdropVideoPlayer(sink: sink, makeSource: { $0.lastPathComponent == "a.webm" ? old : new })
        var oldRequests = old.requests.stream.makeAsyncIterator(), newRequests = new.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await oldRequests.next()
        let oldWork = player.workTask, staleReady = sink.onReady
        let url = URL(fileURLWithPath: "/b.webm")
        player.play(url); _ = await newRequests.next()
        new.send(.success(try testFrame())); _ = await newRequests.next()
        sink.isDisplayable = true; staleReady?()
        #expect(player.state == .preparing)
        sink.onReady?(); #expect(player.state == .playing)
        old.send(.failure(LauncherError.io("old failure"))); await oldWork?.value
        #expect(player.sourceURL == url && player.state == .playing)
        let work = player.workTask; player.stop(); await work?.value
    }
    @Test func failureIsReportedForCurrentSourceAndReleasesIt() async {
        let source = TestFrameSource(), sink = TestVideoSink(), player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        var requests = source.requests.stream.makeAsyncIterator(), states: [BackdropVideoState] = []
        player.onStateChange = { _, state in states.append(state) }
        player.play(URL(fileURLWithPath: "/broken.webm")); _ = await requests.next()
        let work = player.workTask
        source.send(.failure(LauncherError.io("bad media"))); await work?.value
        #expect(player.state == .failed && source.stops == 1)
        #expect(states == [.preparing, .failed])
    }
    @Test func backpressureDoesNotRequestAnotherFrameUntilAccepted() async throws {
        let source = TestFrameSource(), sink = TestVideoSink(), gate = TestEvent()
        sink.hold = gate
        let player = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        var requests = source.requests.stream.makeAsyncIterator()
        player.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        source.send(.success(try testFrame())); try await sink.entered.wait()
        #expect(source.count == 1 && player.state == .preparing)
        player.pause(); gate.signal()
        let work = player.workTask; await work?.value
        #expect(source.count == 1 && sink.rates.last == false)
        player.stop()
    }
    @Test func deinitStopsSourceWithoutTaskRetainCycle() async {
        let source = TestFrameSource(), sink = TestVideoSink()
        var player: BackdropVideoPlayer? = BackdropVideoPlayer(sink: sink, makeSource: { _ in source })
        weak let weakPlayer = player
        var requests = source.requests.stream.makeAsyncIterator()
        player?.play(URL(fileURLWithPath: "/a.webm")); _ = await requests.next()
        let work = player?.workTask; player = nil
        #expect(weakPlayer == nil && source.stops == 1)
        await work?.value
    }
}

@Suite(.timeLimit(.minutes(1))) struct FrameQueueTests {
    @Test func fiveLoopsStayBoundedAndMonotonicPauseAndStopReleaseDecoder() async throws {
        let video = try await tinyVideo(), counters = DecodeCounters()
        let source = VideoFrameSource(url: URL(fileURLWithPath: "/inert.webm"), load: { _ in video }, makeDecoder: { _ in try TestDecoder(counters) })
        var previous = -1.0
        for _ in 0..<100 {
            let frame = try #require(try await source.next())
            #expect(frame.presentationTime.seconds > previous)
            previous = frame.presentationTime.seconds
            #expect(source.queueMetrics.queued <= VideoFrameSource.capacity)
        }
        #expect(source.queueMetrics.peak == VideoFrameSource.capacity)
        source.setPaused(true)
        let count = counters.count
        #expect(try await source.next() == nil)
        #expect(counters.count == count)
        source.setPaused(false); #expect(try await source.next() != nil)
        source.stop(); await source.drain()
        #expect(source.queueMetrics.queued == 0 && counters.invalidated)
    }
}

private func testFrame(at presentationTime: CMTime = .zero) throws -> BackdropFrame {
    var image: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess,
        let image else { throw LauncherError.io("Cannot create synthetic surface") }
    return BackdropFrame(pixelBuffer: image, presentationTime: presentationTime)
}
private final class DecodeCounters: Sendable {
    let values = Mutex((count: 0, invalidated: false))
    var count: Int { values.withLock { $0.count } }
    var invalidated: Bool { values.withLock { $0.invalidated } }
}
private final class TestDecoder: BackdropDecoding {
    let counters: DecodeCounters
    let frame: BackdropFrame
    init(_ counters: DecodeCounters) throws { self.counters = counters; frame = try testFrame() }
    func decode(_ sample: WebMSample) throws -> BackdropFrame? { counters.values.withLock { $0.count += 1 }; return sample.isDisplayed ? frame : nil }
    func invalidate() { counters.values.withLock { $0.invalidated = true } }
}
private final class TestFrameSource: BackdropFrameSource, Sendable {
    private struct State { var next: CheckedContinuation<BackdropFrame?, any Error>?; var count = 0; var stops = 0 }
    private let state = Mutex(State())
    let requests = AsyncStream<Int>.makeStream()
    let retainOnStop: Bool
    init(retainOnStop: Bool = false) { self.retainOnStop = retainOnStop }
    var count: Int { state.withLock { $0.count } }
    var stops: Int { state.withLock { $0.stops } }
    func next() async throws -> BackdropFrame? {
        try await withCheckedThrowingContinuation { c in
            let count = state.withLock { $0.next = c; $0.count += 1; return $0.count }
            requests.continuation.yield(count)
        }
    }
    func send(_ result: Result<BackdropFrame?, any Error>) {
        let next = state.withLock { let c = $0.next; $0.next = nil; return c }
        next?.resume(with: result)
    }
    func setPaused(_ value: Bool) {}
    func stop() { state.withLock { $0.stops += 1 }; if !retainOnStop { send(.failure(CancellationError())) } }
}
@MainActor private final class TestVideoSink: BackdropVideoSink {
    var isDisplayable = false
    var onReady: (@MainActor @Sendable () -> Void)?
    var frames: [BackdropFrame] = []
    var enqueueTimes: [CMTime] = []
    var rates: [Bool] = []
    private(set) var currentTime: CMTime = .zero
    private(set) var alignments: [CMTime] = []
    var preparations = 0
    var hold: TestEvent?
    let entered = TestEvent()
    func prepare() async { preparations += 1; isDisplayable = false; frames.removeAll() }
    func enqueue(_ frame: BackdropFrame) async throws {
        enqueueTimes.append(currentTime)
        entered.signal()
        if let hold { try await hold.wait() }
        frames.append(frame)
    }
    func makeReady() { isDisplayable = true; onReady?() }
    func setPlaying(_ playing: Bool) { rates.append(playing) }
    func align(to time: CMTime) { alignments.append(time); currentTime = time }
    func advanceClock(by elapsed: CMTime) {
        if rates.last == true { currentTime = CMTimeAdd(currentTime, elapsed) }
    }
    func flush() { isDisplayable = false; frames.removeAll(); currentTime = .zero }
}
