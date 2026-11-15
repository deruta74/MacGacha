// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Shared by all game delivery clients. Idle credit is bounded to 100 ms and
/// waits recheck live preferences at least every 100 ms without blocking threads.
public final class DownloadRateLimiter: Sendable {
    private struct State {
        var rate: Int64?
        var tokens: Double
        var updated: Duration
    }
    private let state: Mutex<State>
    private let now: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public convenience init(bytesPerSecond: Int64? = nil) {
        self.init(bytesPerSecond: bytesPerSecond, clock: ContinuousClock())
    }

    public init<C: Clock>(bytesPerSecond: Int64? = nil, clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
        let rate = Self.validRate(bytesPerSecond)
        state = Mutex(State(rate: rate, tokens: Self.capacity(rate), updated: .zero))
    }

    public func setBytesPerSecond(_ bytesPerSecond: Int64?) {
        state.withLock { state in
            let rate = Self.validRate(bytesPerSecond)
            guard rate != state.rate else { return }
            refill(&state)
            // Lowering a limit discards excess credit. Repeated changes cannot
            // mint new bursts, except when first enabling an unlimited bucket.
            state.tokens = state.rate == nil ? Self.capacity(rate) : min(state.tokens, Self.capacity(rate))
            state.rate = rate
        }
    }

    /// Returns the next bounded read allowance. No tokens are reserved while
    /// suspended, so cancellation cannot strand credit for other streams.
    func acquire(upTo bytes: Int) async throws -> Int {
        precondition(bytes > 0)
        while true {
            try Task.checkCancellation()
            let result: (Int, Duration) = state.withLock { state in
                refill(&state)
                guard let rate = state.rate else { return (bytes, .zero) }
                let count = min(bytes, 64 << 10, max(1, Int(Self.capacity(rate))))
                if state.tokens >= Double(count) {
                    state.tokens -= Double(count)
                    return (count, .zero)
                }
                return (0, .seconds(min(0.1, (Double(count) - state.tokens) / Double(rate))))
            }
            if result.0 > 0 { return result.0 }
            do { try await sleep(result.1) }
            catch { if Task.isCancelled { throw LauncherError.cancelled }; throw error }
        }
    }

    private static func validRate(_ rate: Int64?) -> Int64? { rate.flatMap { $0 > 0 ? $0 : nil } }
    private static func capacity(_ rate: Int64?) -> Double { rate.map { max(1, Double($0) / 10) } ?? 0 }
    private func refill(_ state: inout State) {
        let instant = now(), elapsed = state.updated.durationSeconds(to: instant)
        if let rate = state.rate {
            state.tokens = min(Self.capacity(rate), state.tokens + max(0, elapsed) * Double(rate))
        }
        state.updated = instant
    }
}

private extension Duration {
    func durationSeconds(to other: Duration) -> Double {
        let value = (other - self).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

/// Keeps at most one native callback outside the transport's bounded buffer.
/// Large callbacks are split so a single read cannot bypass the burst budget.
actor RateLimitedHTTPReader {
    private let limiter: DownloadRateLimiter
    private let read: @Sendable () async throws -> Data?
    private var pending = Data()
    private var pulling = false
    init(limiter: DownloadRateLimiter, next: @escaping @Sendable () async throws -> Data?) {
        self.limiter = limiter; read = next
    }
    func next() async throws -> Data? {
        guard !pulling else { throw LauncherError.transport("Concurrent body reads") }
        pulling = true; defer { pulling = false }
        while pending.isEmpty {
            guard let data = try await read() else { return nil }
            pending = data
        }
        let count = try await limiter.acquire(upTo: pending.count)
        try Task.checkCancellation()
        let piece = Data(pending.prefix(count))
        pending.removeFirst(count)
        return piece
    }
}
