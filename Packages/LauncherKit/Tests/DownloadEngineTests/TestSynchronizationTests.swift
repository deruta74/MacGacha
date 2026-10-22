// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import TestSupport
import Dispatch
import Synchronization

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func testEventRetainsSignalsAndDoesNotHideCancellation(signalFirst: Bool) async throws {
    let event = TestEvent()
    if signalFirst { event.signal() }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await event.wait()
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let waiters = (0..<8).map { _ in Task { try await event.wait() } }
    defer { for waiter in waiters { waiter.cancel() } }
    event.signal()
    for waiter in waiters { try await waiter.value }
    try await event.wait() // Signal remains visible to late arrivals.
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func fileAppearanceEventHandlesCreationOnEitherSideOfSubscription(createFirst: Bool) async throws {
    let temp = try TempDir(), file = temp.url.appendingPathComponent("ready")
    if createFirst { try Data().write(to: file) }
    let watcher = try FileAppearanceEvent(file)
    let waiter = Task { try await watcher.wait() }
    defer { waiter.cancel() }
    if !createFirst { try Data().write(to: file) }
    try await waiter.value
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test(.timeLimit(.minutes(1)))
func fileAppearanceEventHandlesCreationDuringRegistration() async throws {
    let temp = try TempDir(), file = temp.url.appendingPathComponent("ready")
    let checkedMissing = TestEvent()
    let pendingSource = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    let watcher = try FileAppearanceEvent(file, register: { source in
        pendingSource.withLock { $0 = source }
    }, initialMiss: { checkedMissing.signal() })
    let waiter = Task { try await watcher.wait() }
    defer { waiter.cancel() }
    try await checkedMissing.wait()
    // No source has registered yet: this write cannot produce a directory event.
    try Data().write(to: file)
    let source = try #require(pendingSource.withLock { $0 })
    source.resume()
    try await withTaskCancellationHandler {
        try await waiter.value
    } onCancel: {
        waiter.cancel()
    }
    #expect(FileManager.default.fileExists(atPath: file.path))
}
