// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Dispatch
import Synchronization
import Darwin
import LauncherCore

/// Sticky event: signal-before-wait and multiple waiters are supported without
/// polling. Cancellation releases an awaiting task and is never mistaken for signal.
public final class TestEvent: Sendable {
    private struct State {
        var signalled = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private let state = Mutex(State())
    public init() {}
    public func signal() {
        let waiters = state.withLock { state in
            state.signalled = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.signalled { return .success(()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}

/// Watch the containing directory before launching the writer. Every wake checks
/// the file; checking initially also handles creation before wait() is called.
public final class FileAppearanceEvent: @unchecked Sendable {
    private let url: URL
    private let source: any DispatchSourceFileSystemObject
    private let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let initialMiss: @Sendable () -> Void

    public convenience init(_ url: URL) throws {
        try self.init(url, register: { $0.resume() }, initialMiss: {})
    }

    // Test seam for delaying registration until after the first existence check.
    init(_ url: URL, register: (any DispatchSourceFileSystemObject) -> Void,
        initialMiss: @escaping @Sendable () -> Void) throws {
        self.initialMiss = initialMiss
        self.url = url
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw LauncherError.io("Cannot watch test signal directory") }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
            queue: DispatchQueue.global())
        let continuation = changes.continuation
        // resume() is not a registration barrier. A write before registration
        // can be missed, so registration itself must trigger an existence check.
        source.setRegistrationHandler { continuation.yield(()) }
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler { close(descriptor); continuation.finish() }
        register(source)
    }
    deinit { source.cancel() }
    public func wait() async throws {
        defer { source.cancel() }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: url.path) { return }
        initialMiss()
        for await _ in changes.stream {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) { return }
        }
        throw LauncherError.cancelled
    }
}
