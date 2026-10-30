// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import DownloadEngine
import LauncherCore

/// Only verification produces ahead of the consumer, with one coalesced byte
/// snapshot. The repair pipeline remains pull-driven and owns its existing lease.
actor VerificationStream {
    typealias Builder = @Sendable (@escaping @Sendable (OperationEvent) -> Void) async throws -> AsyncThrowingStream<OperationEvent, any Error>
    private var builder: Builder?
    private var progress: AsyncStream<OperationEvent>.Iterator?
    private var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var producer: Task<Void, Never>?
    private var failure: (any Error)?
    private var first = true
    init(_ builder: @escaping Builder) { self.builder = builder }

    func next(register: @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if first { first = false; return .phase(.verifying) }
        if let builder {
            self.builder = nil
            let channel = AsyncStream<OperationEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
            progress = channel.stream.makeAsyncIterator()
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let stream = try await builder { channel.continuation.yield($0) }
                    self.iterator = stream.makeAsyncIterator()
                } catch { self.failure = error }
                channel.continuation.finish()
            }
            producer = task; register(task)
            // Cancellation may have reached the lifetime before registration.
            if Task.isCancelled { task.cancel() }
        }
        if var current = progress {
            progress = nil
            let event = await current.next(isolation: self)
            progress = current
            if let event { return event }
            progress = nil
            // Cancellation joins verification cleanup before the outer session
            // releases ownership; discarding the stream cancels this same task.
            await producer?.value
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if let failure { throw failure }
        guard var current = iterator else { return nil }
        iterator = nil; let event = try await current.next(isolation: self); iterator = current
        return event
    }
}

func verification(_ builder: @escaping VerificationStream.Builder) -> AsyncThrowingStream<OperationEvent, any Error> {
    let session = VerificationStream(builder)
    return pipelineStream(abandon: {}) { register in try await session.next(register: register) }
}

final class VerificationByteProgress: Sendable {
    static let interval: Duration = .milliseconds(50)
    private struct State { var bytes: Int64 = 0; var last: ContinuousClock.Instant }
    private let state: Mutex<State>
    private let total: Int64
    private let now: @Sendable () -> ContinuousClock.Instant
    private let publish: @Sendable (OperationEvent) -> Void
    init(total: Int64, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        publish: @escaping @Sendable (OperationEvent) -> Void) {
        self.total = total; self.now = now; self.publish = publish
        state = Mutex(State(last: now()))
    }
    func advance(_ delta: Int64) {
        state.withLock { state in
            let (bytes, overflow) = state.bytes.addingReportingOverflow(max(0, delta))
            state.bytes = min(total, overflow ? total : bytes)
            let time = now()
            guard state.last.duration(to: time) >= Self.interval else { return }
            state.last = time
            publish(.progress(downloaded: 0, totalNetwork: 0, staged: state.bytes, totalStaged: total))
        }
    }
    func flush() {
        state.withLock { publish(.progress(downloaded: 0, totalNetwork: 0, staged: $0.bytes, totalStaged: total)) }
    }
}
