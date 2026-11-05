// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch

/// Filesystem calls may block even without an explicit semaphore (quota,
/// device flush, slow storage). Keep them off Swift's cooperative pool.
/// An executor preference preserves task locals and cancellation across awaits;
/// a bare queue.async closure would lose both parts of the I/O contract.
public enum BlockingIO {
    private static let executor = DispatchQueue(label: "org.macgacha.blocking-io", qos: .userInitiated, attributes: .concurrent)

    /// Failed-transfer cleanup must finish even after its caller is cancelled.
    package static func finish(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(executorPreference: executor) { try body() }.value
    }

    /// Keep the caller task so cancellation at an I/O boundary is immediately
    /// visible without racing cross-task cancellation-handler registration.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskExecutorPreference(executor, isolation: nil) {
            try Task.checkCancellation()
            return try await body()
        }
    }
}
