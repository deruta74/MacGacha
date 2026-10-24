// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Synchronization

/// Bounded enqueueing never waits for storage. One drain owns the synchronous
/// sink, always on BlockingIO. A stuck disk retains at most one in-flight item
/// plus the bounded queue; overflow drops the oldest pending item.
package final class BestEffortLogWriter<Item: Sendable>: Sendable {
    private struct Work: Sendable { let id: UInt64; let item: Item; let bytes: Int }
    private struct State {
        var pending: [Work] = []
        var bytes = 0
        var active = false
        var submitted: UInt64 = 0
        var completed: UInt64 = 0
        var dropped: UInt64 = 0
        var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
        mutating func takeWaiters() -> [CheckedContinuation<Void, Never>] {
            let ready = waiters.filter { $0.0 <= completed }.map(\.1)
            waiters.removeAll { $0.0 <= completed }
            return ready
        }
    }
    private let state = Mutex(State())
    private let maxPendingCount: Int
    private let maxPendingBytes: Int
    private let write: @Sendable (Item) throws -> Void

    package init(maxPendingCount: Int = 128, maxPendingBytes: Int = 8 << 20,
        write: @escaping @Sendable (Item) throws -> Void) {
        self.maxPendingCount = max(1, maxPendingCount)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.write = write
    }

    package var droppedCount: UInt64 { state.withLock { $0.dropped } }

    @discardableResult package func post(_ item: Item, bytes: Int) -> UInt64 {
        let result = state.withLock { state -> (UInt64, Bool, [CheckedContinuation<Void, Never>]) in
            state.submitted += 1
            let id = state.submitted, bytes = max(0, bytes)
            guard bytes <= maxPendingBytes else {
                state.dropped += 1
                if !state.active { state.completed = id }
                return (id, false, state.takeWaiters())
            }
            while state.pending.count >= maxPendingCount || state.bytes > maxPendingBytes - bytes {
                state.bytes -= state.pending.removeFirst().bytes
                state.dropped += 1
            }
            state.pending.append(Work(id: id, item: item, bytes: bytes))
            state.bytes += bytes
            let start = !state.active
            state.active = true
            return (id, start, [])
        }
        result.2.forEach { $0.resume() }
        if result.1 { Task.detached { await self.run() } }
        return result.0
    }

    /// For async log callers and explicit test/export barriers, never supervision.
    package func wait(through ticket: UInt64) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.completed >= ticket { return true }
                state.waiters.append((ticket, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    package func drain() async { await wait(through: state.withLock { $0.submitted }) }

    private func run() async {
        while let work = state.withLock({ state -> Work? in
            guard !state.pending.isEmpty else { state.active = false; return nil }
            let work = state.pending.removeFirst()
            state.bytes -= work.bytes
            return work
        }) {
            // No actor-isolated sink: executor preference must cover every syscall.
            _ = try? await BlockingIO.run { try self.write(work.item) }
            let ready = state.withLock { state in
                // Gaps before the next queued ID were dropped, so are settled too.
                state.completed = state.pending.first.map { $0.id - 1 } ?? state.submitted
                return state.takeWaiters()
            }
            ready.forEach { $0.resume() }
        }
    }
}
