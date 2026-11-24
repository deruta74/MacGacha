// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Shared live admission policy for delivery work. Existing pipeline limits
/// still apply normally. During gameplay, each lane admits one worker after
/// already admitted work finishes; mode changes never cancel work or commits.
public final class DeliveryWorkController: Sendable {
    package enum Kind: Hashable, Sendable { case transfer, assembly }
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var gameplay = false
        var active: [Kind: Int] = [:]
        var waiters: [Kind: [Waiter]] = [:]
    }
    private let state = Mutex(State())
    public init() {}
    package var isGameplayActive: Bool { state.withLock { $0.gameplay } }

    public func setGameplayActive(_ active: Bool) {
        let granted = state.withLock { s in
            s.gameplay = active
            return Self.grant(.transfer, state: &s) + Self.grant(.assembly, state: &s)
        }
        for waiter in granted { waiter.resume() }
    }

    package func acquire(_ kind: Kind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let queued = state.withLock { s -> Bool? in
                    if Task.isCancelled { return nil }
                    if s.waiters[kind, default: []].isEmpty && (!s.gameplay || s.active[kind, default: 0] < 1) {
                        s.active[kind, default: 0] += 1
                        return false
                    }
                    s.waiters[kind, default: []].append(Waiter(id: id, continuation: continuation))
                    return true
                }
                switch queued {
                case nil: continuation.resume(throwing: LauncherError.cancelled)
                case false: continuation.resume()
                case true: OperationWork.record(.deliveryWorkWaiting)
                }
            }
        } onCancel: { self.cancel(id, kind: kind) }
    }

    package func release(_ kind: Kind) {
        let granted = state.withLock { s in
            precondition(s.active[kind, default: 0] > 0)
            s.active[kind, default: 0] -= 1
            return Self.grant(kind, state: &s)
        }
        for waiter in granted { waiter.resume() }
    }

    private func cancel(_ id: UUID, kind: Kind) {
        let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            guard let index = s.waiters[kind]?.firstIndex(where: { $0.id == id }) else { return nil }
            return s.waiters[kind]?.remove(at: index).continuation
        }
        continuation?.resume(throwing: LauncherError.cancelled)
    }

    private static func grant(_ kind: Kind, state: inout State) -> [CheckedContinuation<Void, any Error>] {
        var result: [CheckedContinuation<Void, any Error>] = []
        while state.waiters[kind]?.isEmpty == false && (!state.gameplay || state.active[kind, default: 0] < 1) {
            result.append(state.waiters[kind]!.removeFirst().continuation)
            state.active[kind, default: 0] += 1
        }
        return result
    }
}
