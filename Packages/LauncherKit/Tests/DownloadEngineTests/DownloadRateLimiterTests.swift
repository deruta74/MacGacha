// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import TestSupport
import LauncherCore
@testable import DownloadEngine

@Suite(.timeLimit(.minutes(1))) struct DownloadRateLimiterTests {
    @Test func oldReceptionEpochCannotDebitANewerBudget() async throws {
        let events = AsyncStream<String>.makeStream()
        let clock = RateClock(onSleep: { events.continuation.yield("waiting") })
        let bucket = DownloadRateLimiter(bytesPerSecond: 5_000_000, clock: clock)
        let old = try #require(bucket.receptionEpoch)
        bucket.setBytesPerSecond(nil)
        bucket.setBytesPerSecond(5_000_000)
        bucket.settle(reception: nil, received: 500_000, epoch: old)
        let read = Task { _ = try await bucket.acquire(upTo: 1); events.continuation.yield("granted") }
        defer { read.cancel() }
        var event = events.stream.makeAsyncIterator()
        #expect(await event.next() == "granted")
        read.cancel(); _ = try? await read.value
    }

    @Test func staleRefundCannotCreditAReinitializedBudget() async throws {
        let events = AsyncStream<String>.makeStream()
        let clock = RateClock(onSleep: { events.continuation.yield("waiting") })
        let bucket = DownloadRateLimiter(bytesPerSecond: 5_000_000, clock: clock)
        let old = UUID(), current = UUID()
        _ = try await bucket.acquire(upTo: 65_536, receptionOwner: old)
        bucket.setBytesPerSecond(nil)
        bucket.setBytesPerSecond(5_000_000)
        _ = try await bucket.acquire(upTo: 65_536, receptionOwner: current)
        bucket.settle(reception: old, received: 0)
        var drained = 0
        while drained < 434_464 { drained += try await bucket.acquire(upTo: 434_464 - drained) }
        let read = Task { _ = try await bucket.acquire(upTo: 1); events.continuation.yield("granted") }
        defer { read.cancel() }
        var event = events.stream.makeAsyncIterator()
        #expect(await event.next() == "waiting")
        read.cancel(); _ = try? await read.value
    }

    @Test func staleReceptionReleaseCannotRevokeANewerTurn() async throws {
        let bucket = DownloadRateLimiter(bytesPerSecond: 5_000_000)
        let old = UUID(), current = UUID()
        _ = try await bucket.acquire(upTo: 100, receptionOwner: old)
        bucket.setBytesPerSecond(nil)
        bucket.setBytesPerSecond(5_000_000)
        _ = try await bucket.acquire(upTo: 100, receptionOwner: current)
        bucket.releaseReception(old)
        #expect(bucket.isReceiving)
        bucket.releaseReception(current)
        #expect(!bucket.isReceiving)
    }

    @Test func newerSmallReadsCannotBypassAnOlderLargeWaiter() async throws {
        let events = AsyncStream<String>.makeStream()
        let clock = RateClock()
        let bucket = DownloadRateLimiter(bytesPerSecond: 100, clock: clock)
        #expect(try await bucket.acquire(upTo: 10) == 10)
        let large = Task { _ = try await bucket.acquire(upTo: 10); events.continuation.yield("large") }
        defer { large.cancel() }
        var event = events.stream.makeAsyncIterator(), waits = clock.waits.makeAsyncIterator()
        let firstWait = try #require(await waits.next())
        clock.advance(to: firstWait.deadline)
        // The older waiter has not been scheduled yet. New smaller reads must
        // still leave its refill intact, independently of executor ordering.
        let small = Task { _ = try await bucket.acquire(upTo: 1, onQueued: { events.continuation.yield("waiting") }); events.continuation.yield("small") }
        defer { small.cancel() }
        #expect(await event.next() == "waiting")
        firstWait.resume.signal()
        #expect(await event.next() == "large")
        large.cancel(); small.cancel()
        _ = try? await large.value; _ = try? await small.value
    }

    @Test func sharedBudgetRefillsAtRateAndBoundsIdleBurst() async throws {
        let clock = RateClock()
        // Use one shared bucket with a controllable monotonic clock.
        let bucket = DownloadRateLimiter(bytesPerSecond: 100, clock: clock)
        #expect(try await bucket.acquire(upTo: 100) == 10)
        let next = Task { try await bucket.acquire(upTo: 100) }
        var waits = clock.waits.makeAsyncIterator()
        let wait = try #require(await waits.next())
        #expect(wait.deadline == clock.origin.advanced(by: .milliseconds(100)))
        clock.advance(to: wait.deadline); wait.resume.signal()
        #expect(try await next.value == 10)
        clock.advance(to: clock.origin.advanced(by: .seconds(100)))
        #expect(try await bucket.acquire(upTo: 100) == 10)
        let blocked = Task { try await bucket.acquire(upTo: 100) }
        _ = try #require(await waits.next())
        blocked.cancel()
        await #expect(throws: (any Error).self) { try await blocked.value }
    }

    @Test func liveChangesReevaluateWaitingReadsWithinOneTenthSecond() async throws {
        let clock = RateClock()
        let limiter = DownloadRateLimiter(bytesPerSecond: 100, clock: clock)
        #expect(try await limiter.acquire(upTo: 10) == 10)
        var waits = clock.waits.makeAsyncIterator()
        let read = Task { try await limiter.acquire(upTo: 100) }
        let wait = try #require(await waits.next())
        limiter.setBytesPerSecond(nil)
        clock.advance(to: wait.deadline); wait.resume.signal()
        #expect(try await read.value == 100)
        limiter.setBytesPerSecond(50)
        #expect(try await limiter.acquire(upTo: 100) == 5)
        limiter.setBytesPerSecond(10)
        let lower = Task { try await limiter.acquire(upTo: 100) }
        let lowerWait = try #require(await waits.next())
        #expect(lowerWait.deadline.duration(to: clock.now) >= .milliseconds(-100))
        clock.advance(to: lowerWait.deadline); lowerWait.resume.signal()
        #expect(try await lower.value == 1)
    }

    @Test func cancellationWhileWaitingLeavesBudgetAvailable() async throws {
        let clock = RateClock()
        let bucket = DownloadRateLimiter(bytesPerSecond: 100, clock: clock)
        #expect(try await bucket.acquire(upTo: 10) == 10)
        let cancelled = Task { try await bucket.acquire(upTo: 10) }
        var waits = clock.waits.makeAsyncIterator()
        let wait = try #require(await waits.next())
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        clock.advance(to: wait.deadline)
        #expect(try await bucket.acquire(upTo: 10) == 10)
    }
}

final class RateClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant
    final class Wait: Sendable {
        let id = UUID(), deadline: Instant
        let resume = TestEvent()
        let finished = Mutex(false)
        var active: Bool { !finished.withLock { $0 } }
        init(deadline: Instant) { self.deadline = deadline }
    }
    private let onSleep: @Sendable () -> Void
    init(onSleep: @escaping @Sendable () -> Void = {}) { self.onSleep = onSleep }
    let origin = ContinuousClock.now
    private struct State { var time: Instant?; var sleepers: [UUID: Wait] = [:] }
    private let state = Mutex(State())
    private let channel = AsyncStream<Wait>.makeStream()
    var waits: AsyncStream<Wait> { channel.stream }
    var now: Instant { state.withLock { $0.time ?? origin } }
    var minimumResolution: Duration { .nanoseconds(1) }
    func advance(to instant: Instant, wakingSleepers: Bool = false) {
        let due = state.withLock { state in
            state.time = instant
            return wakingSleepers ? state.sleepers.values.filter { $0.deadline <= instant } : []
        }
        due.forEach { $0.resume.signal() }
    }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let wait = Wait(deadline: deadline)
        state.withLock { $0.sleepers[wait.id] = wait }
        defer {
            wait.finished.withLock { $0 = true }
            _ = state.withLock { $0.sleepers.removeValue(forKey: wait.id) }
        }
        channel.continuation.yield(wait)
        onSleep()
        try await withTaskCancellationHandler { try await wait.resume.wait() } onCancel: {
            wait.finished.withLock { $0 = true }
        }
    }
}
