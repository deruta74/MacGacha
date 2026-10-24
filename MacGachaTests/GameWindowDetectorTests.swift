// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor
struct GameWindowDetectorTests {
    @Test func ownerPIDAndNonzeroBoundsAreRequired() async {
        let detector = GameWindowDetector { [
            GameWindowInfo(ownerPID: 10, width: 640, height: 480),
            GameWindowInfo(ownerPID: 20, width: 0, height: 480),
            GameWindowInfo(ownerPID: 30, width: 640, height: 0)
        ] }
        #expect(await detector.hasVisibleWindow(ownerPIDs: [10]))
        #expect(await !detector.hasVisibleWindow(ownerPIDs: [20, 30, 40]))
        #expect(await !detector.hasVisibleWindow(ownerPIDs: []))
    }

    @Test func gameWindowMarksReadyAndMinimizes() async {
        let clock = NativeWindowClock(), actions = NativeWindowActions(), provider = NativeWindowProvider()
        let ready = Mutex(0)
        let coordinator = LaunchWindowCoordinator(detector: provider, actions: actions, clock: clock)
        coordinator.running(gameID: "genshin", processIDs: { [101] }, markReady: { ready.withLock { $0 += 1 } })
        await clock.waitForSleep(.milliseconds(500))
        await clock.waitForSleep(.seconds(20))
        #expect(actions.minimizations == 0)
        provider.visible.withLock { $0 = true }
        clock.advance(by: .milliseconds(500))
        await actions.waitForMinimize()
        #expect(ready.withLock { $0 } == 1)
        #expect(provider.seenPIDs.withLock { $0 } == [101])
        coordinator.ready(gameID: "genshin")
        #expect(actions.minimizations == 1)
        coordinator.ended(gameID: "genshin")
        #expect(actions.restorations == 1)
    }

    @Test func twentySecondFallbackDoesNotDeclareReady() async {
        let clock = NativeWindowClock(), actions = NativeWindowActions(), provider = NativeWindowProvider()
        let ready = Mutex(0)
        let coordinator = LaunchWindowCoordinator(detector: provider, actions: actions, clock: clock)
        coordinator.running(gameID: "genshin", processIDs: { [101] }, markReady: { ready.withLock { $0 += 1 } })
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20))
        clock.advance(by: .seconds(20))
        await actions.waitForMinimize()
        #expect(actions.minimizations == 1)
        #expect(ready.withLock { $0 } == 0)
        coordinator.ended(gameID: "genshin")
        #expect(actions.restorations == 1)
    }

    @Test func sessionEndCancelsPollingAndFallback() async {
        let clock = NativeWindowClock(), actions = NativeWindowActions()
        let coordinator = LaunchWindowCoordinator(detector: NativeWindowProvider(), actions: actions, clock: clock)
        coordinator.running(gameID: "genshin", processIDs: { [] }, markReady: {})
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20))
        coordinator.ended(gameID: "genshin")
        await clock.waitForCancellations(2)
        #expect(clock.activeSleeps == 0)
        clock.advance(by: .seconds(20))
        #expect(actions.minimizations == 0)
        #expect(actions.restorations == 1)
    }

    @Test func repeatedRunningDoesNotPostponeFallback() async {
        let clock = NativeWindowClock(), actions = NativeWindowActions()
        let coordinator = LaunchWindowCoordinator(detector: NativeWindowProvider(), actions: actions, clock: clock)
        coordinator.running(gameID: "genshin", processIDs: { [] }, markReady: {})
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20))
        clock.advance(by: .seconds(10))
        coordinator.running(gameID: "genshin", processIDs: { [] }, markReady: {})
        clock.advance(by: .seconds(10))
        await actions.waitForMinimize()
        #expect(actions.minimizations == 1)
        coordinator.ended(gameID: "genshin")
    }

    @Test func unrelatedSessionEndDoesNotCancelActiveSession() async {
        let clock = NativeWindowClock(), actions = NativeWindowActions()
        let coordinator = LaunchWindowCoordinator(detector: NativeWindowProvider(), actions: actions, clock: clock)
        coordinator.running(gameID: "genshin", processIDs: { [] }, markReady: {})
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20))
        coordinator.ended(gameID: "zzz")
        #expect(actions.restorations == 0)
        clock.advance(by: .seconds(20))
        await actions.waitForMinimize()
        coordinator.ended(gameID: "genshin")
    }
}

final class NativeWindowProvider: GameWindowProviding, Sendable {
    let visible = Mutex(false)
    let seenPIDs = Mutex(Set<Int32>())
    func hasVisibleWindow(ownerPIDs: Set<Int32>) async -> Bool {
        seenPIDs.withLock { $0 = ownerPIDs }
        return visible.withLock { $0 }
    }
}

@MainActor final class NativeWindowActions: LaunchWindowActions {
    var minimizations = 0
    var restorations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func minimize() {
        minimizations += 1
        let continuations = waiters; waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
    func restore() { restorations += 1 }
    func waitForMinimize() async {
        guard minimizations == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Handshakes identify registered deadlines before advancing virtual time.
final class NativeWindowClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        let offset: Duration
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    private struct State {
        var now: Duration = .zero
        var sleepers: [UUID: (Instant, CheckedContinuation<Void, any Error>)] = [:]
        var registered: Set<Duration> = []
        var sleepObservers: [(Duration, CheckedContinuation<Void, Never>)] = []
        var cancellations = 0
        var cancelObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())
    var now: Instant { state.withLock { Instant(offset: $0.now) } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var activeSleeps: Int { state.withLock { $0.sleepers.count } }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) = state.withLock { state in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline.offset <= state.now { return (.success(()), []) }
                    let duration = deadline.offset - state.now
                    state.registered.insert(duration); state.sleepers[id] = (deadline, continuation)
                    let observers = state.sleepObservers.filter { state.registered.contains($0.0) }.map(\.1)
                    state.sleepObservers.removeAll { state.registered.contains($0.0) }
                    return (nil, observers)
                }
                result.1.forEach { $0.resume() }
                if let result = result.0 { continuation.resume(with: result) }
            }
        } onCancel: {
            let result = self.state.withLock { state in
                let sleeper = state.sleepers.removeValue(forKey: id)
                state.cancellations += 1
                let observers = state.cancelObservers.filter { $0.0 <= state.cancellations }.map(\.1)
                state.cancelObservers.removeAll { $0.0 <= state.cancellations }
                return (sleeper?.1, observers)
            }
            result.0?.resume(throwing: CancellationError()); result.1.forEach { $0.resume() }
        }
    }
    func waitForSleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.registered.contains(duration) { return true }
                state.sleepObservers.append((duration, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    func waitForCancellations(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.cancellations >= count { return true }
                state.cancelObservers.append((count, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now += duration
            let ready = state.sleepers.filter { $0.value.0.offset <= state.now }
            ready.keys.forEach { state.sleepers.removeValue(forKey: $0) }
            return ready.values.map(\.1)
        }
        ready.forEach { $0.resume() }
    }
}
