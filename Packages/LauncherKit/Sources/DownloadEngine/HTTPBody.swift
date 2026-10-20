// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// A single-consumer response body. Discarding the body or its iterator cancels the transfer.
public struct HTTPBody: AsyncSequence, Sendable {
    public typealias Element = Data

    private let source: HTTPBodySource

    public init(
        next: @escaping @Sendable () async throws -> Data?,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        source = HTTPBodySource(next: next, onCancel: onCancel)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(lifetime: source.claimIterator() ? HTTPBodyIteratorLifetime(source) : nil)
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        fileprivate let lifetime: HTTPBodyIteratorLifetime?

        public mutating func next() async throws -> Data? {
            guard let source = lifetime?.source else { throw LauncherError.transport("body already consumed") }
            return try await withTaskCancellationHandler {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let data = try await source.next()
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                return data
            } onCancel: {
                source.cancel()
            }
        }
    }
}

fileprivate final class HTTPBodySource: Sendable {
    private struct State {
        var claimed = false
        var cancelled = false
    }
    private let state = Mutex(State())
    private let produce: @Sendable () async throws -> Data?
    private let onCancel: @Sendable () -> Void

    init(next: @escaping @Sendable () async throws -> Data?, onCancel: @escaping @Sendable () -> Void) {
        produce = next
        self.onCancel = onCancel
    }

    deinit { cancel() }

    func claimIterator() -> Bool {
        state.withLock {
            guard !$0.claimed else { return false }
            $0.claimed = true
            return true
        }
    }

    func next() async throws -> Data? {
        guard !state.withLock({ $0.cancelled }) else { throw LauncherError.cancelled }
        return try await produce()
    }

    func cancel() {
        let first = state.withLock { state in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        if first { onCancel() }
    }
}

fileprivate final class HTTPBodyIteratorLifetime: Sendable {
    let source: HTTPBodySource
    init(_ source: HTTPBodySource) { self.source = source }
    deinit { source.cancel() }
}
