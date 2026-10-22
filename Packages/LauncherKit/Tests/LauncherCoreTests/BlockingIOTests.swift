// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Testing
import LauncherCore

private enum IOTestContext {
    @TaskLocal static var value = 0
}

@Test(.timeLimit(.minutes(1)))
func blockedIOPreservesTaskLocalsAndCancellationWithoutStarvingTheCaller() async throws {
    let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    @Sendable func block() throws {
        entered.continuation.yield(IOTestContext.value)
        guard release.wait(timeout: .now() + 30) == .success else { throw LauncherError.io("I/O test timed out") }
        try Task.checkCancellation()
    }
    let worker = Task {
        try await IOTestContext.$value.withValue(42) {
            try await BlockingIO.run { try block() }
        }
    }
    defer { release.signal(); worker.cancel() }
    var iterator = entered.stream.makeAsyncIterator()
    #expect(await iterator.next() == 42)
    // Reaching this continuation while the I/O worker is blocked proves that
    // even a width-one cooperative pool remains available to cancel/release it.
    worker.cancel()
    release.signal()
    await #expect(throws: CancellationError.self) { try await worker.value }
}
