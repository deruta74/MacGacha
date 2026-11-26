// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch

/// Filesystem calls may block even without an explicit semaphore (quota,
/// device flush, slow storage). Keep them off Swift's cooperative pool.
/// An executor preference preserves task locals and cancellation across awaits;
/// a bare queue.async closure would lose both parts of the I/O contract.
public enum BlockingIO {
    public enum Quality: Sendable {
        case standard, background

        package var actorQoS: DispatchQoS { self == .background ? .background : .unspecified }
    }

    @TaskLocal package static var quality: Quality = .standard
    @TaskLocal package static var executorObserver: (@Sendable (Quality) -> Void)? = nil

    private static let backgroundExecutor = DispatchQueue(label: "org.macgacha.background-io", qos: .background, attributes: .concurrent)
    private static let foregroundExecutor = DispatchQueue(label: "org.macgacha.blocking-io", qos: .userInitiated, attributes: .concurrent)

    private static var executor: DispatchQueue { quality == .background ? backgroundExecutor : foregroundExecutor }

    /// Failed-transfer cleanup must finish even after its caller is cancelled.
    package static func finish(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(executorPreference: executor, priority: quality == .background ? .background : nil) { try body() }.value
    }

    /// Keep the caller task so cancellation at an I/O boundary is immediately
    /// visible without racing cross-task cancellation-handler registration.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let selectedQuality = quality
        return try await withTaskExecutorPreference(executor, isolation: nil) {
            executorObserver?(selectedQuality)
            try Task.checkCancellation()
            return try await body()
        }
    }
}
