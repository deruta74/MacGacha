// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Shared native-reception budget with FIFO admission. A single receiving
/// turn bounds concurrent callback overshoot, which is repaid before admission.
/// Idle credit and receiving turns are capped at 100 ms. Waiting is asynchronous.
public final class DownloadRateLimiter: Sendable {
    private struct Waiter: Sendable { let id: UUID; let turn: AsyncStream<Void>.Continuation }
    private struct State {
        var rate: Int64?
        var epoch = UUID()
        var tokens: Double
        var updated: Duration
        var waiters: [Waiter] = []
        var receiver: UUID?
        var transition: UUID?
        var pendingObservers: Set<UUID> = []
        var reservations: [UUID: Int] = [:]
        var observers: [UUID: @Sendable (UUID) -> Void] = [:]
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
        let transition = UUID()
        let observers: [@Sendable (UUID) -> Void]? = state.withLock { state in
            let rate = Self.validRate(bytesPerSecond)
            guard rate != state.rate else { return nil }
            refill(&state)
            // Lowering a limit discards excess credit. Repeated changes cannot
            // mint new bursts, except when first enabling an unlimited bucket.
            if state.rate == nil, rate != nil { state.epoch = UUID() }
            state.tokens = state.rate == nil ? Self.capacity(rate) : min(state.tokens, Self.capacity(rate))
            state.rate = rate; state.transition = transition
            state.pendingObservers = Set(state.observers.keys)
            if rate == nil { state.receiver = nil; state.reservations.removeAll() }
            if state.pendingObservers.isEmpty { state.transition = nil }
            return Array(state.observers.values)
        }
        guard let observers else { return }
        // Each observer acknowledges only after its native effects execute.
        for observer in observers { observer(transition) }
        if observers.isEmpty { state.withLock { $0.waiters.first?.turn }?.yield(()) }
    }

    var isTransitioning: Bool { state.withLock { $0.transition != nil } }

    func acknowledgeTransition(_ transition: UUID, observer: UUID) {
        let next = state.withLock { state in
            guard state.transition == transition else { return nil as AsyncStream<Void>.Continuation? }
            state.pendingObservers.remove(observer)
            guard state.pendingObservers.isEmpty else { return nil }
            state.transition = nil
            return state.waiters.first?.turn
        }
        next?.yield(())
    }

    var receptionEpoch: UUID? { state.withLock { $0.rate == nil ? nil : $0.epoch } }
    var isReceiving: Bool { state.withLock { $0.receiver != nil } }
    var pendingAcquisitions: Int { state.withLock { $0.waiters.count } }
    var isLimited: Bool { state.withLock { $0.rate != nil } }

    func observeChanges(id: UUID, _ observer: @escaping @Sendable (UUID) -> Void) {
        state.withLock { $0.observers[id] = observer }
    }

    func removeObserver(_ id: UUID) {
        let next = state.withLock { state in
            state.observers.removeValue(forKey: id)
            state.pendingObservers.remove(id)
            guard state.pendingObservers.isEmpty else { return nil as AsyncStream<Void>.Continuation? }
            state.transition = nil
            return state.waiters.first?.turn
        }
        next?.yield(())
    }

    /// Reservation identities survive finite rate changes. Unlimited discards
    /// them so a stale refund cannot replenish a newly initialized bucket.
    func settle(reception: UUID?, received: Int, epoch: UUID? = nil) {
        state.withLock { state in
            let reserved = reception.flatMap { state.reservations.removeValue(forKey: $0) } ?? 0
            guard state.rate != nil else { return }
            refill(&state)
            let received = epoch == state.epoch ? received : 0
            state.tokens = min(Self.capacity(state.rate), state.tokens + Double(reserved) - Double(received))
        }
    }

    /// FIFO admission prevents smaller callbacks from overtaking an older
    /// request. Cancellation removes its ticket without consuming any credit.
    func acquire(upTo bytes: Int, receptionOwner: UUID? = nil, onQueued: (@Sendable () -> Void)? = nil) async throws -> Int {
        precondition(bytes > 0)
        let ticket = UUID(), turns = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let first = state.withLock { state in
            state.waiters.append(Waiter(id: ticket, turn: turns.continuation))
            return state.waiters.count == 1
        }
        if first { turns.continuation.yield(()) }
        onQueued?()
        defer {
            let next = state.withLock { state in
                let first = state.waiters.first?.id == ticket
                state.waiters.removeAll { $0.id == ticket }
                return first ? state.waiters.first?.turn : nil
            }
            turns.continuation.finish()
            next?.yield(())
        }
        var turn = turns.stream.makeAsyncIterator()
        _ = await turn.next()
        while true {
            try Task.checkCancellation()
            let result: (Int, Duration) = state.withLock { state in
                refill(&state)
                guard let rate = state.rate else { return (bytes, .zero) }
                if state.transition != nil { return (0, .zero) }
                if receptionOwner != nil, state.receiver != nil { return (0, .zero) }
                let count = min(bytes, 64 << 10, max(1, Int(Self.capacity(rate))))
                if state.tokens >= Double(count) {
                    state.tokens -= Double(count)
                    if let receptionOwner {
                        state.receiver = receptionOwner; state.reservations[receptionOwner] = count
                    }
                    return (count, .zero)
                }
                // Zero is reserved for turn handoffs, not a rounded credit wait.
                return (0, max(.nanoseconds(1), .seconds(min(0.1, (Double(count) - state.tokens) / Double(rate)))))
            }
            if result.0 > 0 { return result.0 }
            if result.1 == .zero { _ = await turn.next(); continue }
            do { try await sleep(result.1) }
            catch { if Task.isCancelled { throw LauncherError.cancelled }; throw error }
        }
    }

    func releaseReception(_ owner: UUID) {
        let next = state.withLock { state in
            guard state.receiver == owner else { return nil as AsyncStream<Void>.Continuation? }
            state.receiver = nil
            return state.waiters.first?.turn
        }
        next?.yield(())
    }

    func waitForReceptionSlice() async throws { try await sleep(.milliseconds(100)) }

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
