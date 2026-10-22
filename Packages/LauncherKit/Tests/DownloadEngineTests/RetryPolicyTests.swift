// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func retryDelaysAreBoundedAndHonorRetryAfter() {
    let policy = RetryPolicy()
    #expect(policy.maxAttempts == 6)
    #expect(policy.baseDelay == .milliseconds(500))
    #expect(policy.maxDelay == .seconds(30))
    #expect(policy.maxRetryAfter == .seconds(300))
    for attempt in 1...10 {
        for _ in 0..<20 {
            let delay = policy.delay(forAttempt: attempt, retryAfter: nil)
            #expect(delay >= .zero)
            #expect(delay <= policy.maxDelay)
            #expect(delay <= policy.baseDelay * (1 << (attempt - 1)))
            #expect(policy.delay(forAttempt: attempt, retryAfter: .seconds(7)) >= .seconds(7))
        }
    }
    #expect(policy.delay(forAttempt: Int.max, retryAfter: nil) <= policy.maxDelay)
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(60)) >= .seconds(60))
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(3600)) == .seconds(300))
}

@Test
func retryAfterCapIsConfigurable() {
    let policy = RetryPolicy(baseDelay: .zero, maxRetryAfter: .seconds(12))
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(3600)) == .seconds(12))
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(7)) == .seconds(7))
    #expect(policy.delay(forAttempt: 1, retryAfter: .seconds(-1)) == .zero)
}

@Test
func retryClassification() {
    let url = URL(string: "https://mock.cdn/blob")!
    let policy = RetryPolicy()
    let retryable: [LauncherError] = [
        .http(status: 408, url: url), .http(status: 429, url: url), .http(status: 503, url: url),
        .transport("x"), .digestMismatch(path: "a", expected: "a", actual: "b"),
        .sizeMismatch(path: "a", expected: 2, actual: 1),
    ]
    for error in retryable { #expect(policy.isRetryable(error)) }
    let permanent: [LauncherError] = [
        .http(status: 404, url: url), .http(status: 600, url: url), .cancelled, .unsafePath("x"),
        .insufficientSpace(required: 10, available: 1), .io("x"),
    ]
    for error in permanent { #expect(!policy.isRetryable(error)) }
    #expect(!policy.isRetryable(CancellationError()))
}

@Test(.timeLimit(.minutes(1)))
func sleepersRecordAndRespectCancellation() async throws {
    let instant = InstantSleeper()
    try await instant.sleep(for: .seconds(7))
    #expect(instant.delays == [.seconds(7)])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await ContinuousSleeper().sleep(for: .seconds(30))
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    let instantTask = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await instant.sleep(for: .seconds(30))
    }
    await #expect(throws: LauncherError.cancelled) { try await instantTask.value }
    #expect(instant.delays == [.seconds(7)])
}

@Test(.timeLimit(.minutes(1)))
func continuousSleeperMapsCancellationDuringSleep() async throws {
    let task = Task { try await ContinuousSleeper().sleep(for: .seconds(30)) }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
}
