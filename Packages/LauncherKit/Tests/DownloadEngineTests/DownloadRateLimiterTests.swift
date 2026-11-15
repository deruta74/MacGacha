// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import TestSupport
import LauncherCore
@testable import DownloadEngine

@Suite(.timeLimit(.minutes(1))) struct DownloadRateLimiterTests {
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
    struct Wait: Sendable { let deadline: Instant; let resume = TestEvent() }
    let origin = ContinuousClock.now
    private let time = Mutex<Instant?>(nil)
    private let channel = AsyncStream<Wait>.makeStream()
    var waits: AsyncStream<Wait> { channel.stream }
    var now: Instant { time.withLock { $0 ?? origin } }
    var minimumResolution: Duration { .nanoseconds(1) }
    func advance(to instant: Instant) { time.withLock { $0 = instant } }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let wait = Wait(deadline: deadline)
        channel.continuation.yield(wait)
        try await wait.resume.wait()
    }
}
