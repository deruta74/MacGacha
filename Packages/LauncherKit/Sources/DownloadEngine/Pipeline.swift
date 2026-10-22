// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Synchronization
import LauncherCore

/// Both bounds apply to a contiguous look-ahead window. A file larger than the
/// window runs alone; its complete part set is reserved by the disk model.
public struct PipelineConfiguration: Sendable, Equatable {
    public let prefetchBytes: Int64
    public let prefetchObjects: Int
    public let assemblies: Int
    public init(prefetchBytes: Int64 = 1 << 30, prefetchObjects: Int = 256, assemblies: Int = 8) {
        self.prefetchBytes = prefetchBytes; self.prefetchObjects = prefetchObjects; self.assemblies = assemblies
    }
    public static let `default` = PipelineConfiguration()
    package func validate() throws {
        guard prefetchBytes > 0, prefetchObjects > 0, assemblies > 0 else { throw LauncherError.io("Invalid pipeline limits") }
    }
}

/// The stream owns work, not the reusable staging session. Discarding an idle
/// iterator cancels its bounded producer, even without another next() call.
private final class PipelineLifetime: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let abandon: @Sendable () -> Void
    init(abandon: @escaping @Sendable () -> Void) { self.abandon = abandon }
    func replace(_ value: Task<Void, Never>) { task.withLock { $0?.cancel(); $0 = value } }
    func cancel() { task.withLock { $0?.cancel() } }
    deinit { cancel(); abandon() }
}

/// One coalesced progress snapshot plus at most one file event per window file.
/// No per-byte tasks or unbounded event producer survive a stopped consumer.
package final class PipelineChannel: Sendable {
    private struct State {
        var events: [OperationEvent] = []
        var waiter: CheckedContinuation<OperationEvent?, any Error>?
        var ended = false
        var progressSequence: UInt64 = 0
        var error: (any Error)?
    }
    private let state = Mutex(State())
    func send(_ event: OperationEvent) {
        if case .progress = event { preconditionFailure("Progress publication requires a sequenced snapshot") }
        publish(event, sequence: nil)
    }
    func send(_ snapshot: PipelineProgressSnapshot) { publish(snapshot.event, sequence: snapshot.sequence) }
    private func publish(_ event: OperationEvent, sequence: UInt64?) {
        let waiter = state.withLock { s -> CheckedContinuation<OperationEvent?, any Error>? in
            guard !s.ended else { return nil }
            if let sequence {
                guard sequence > s.progressSequence else { return nil }
                s.progressSequence = sequence
            }
            if let waiter = s.waiter { s.waiter = nil; return waiter }
            if case .progress = event { s.events.removeAll { if case .progress = $0 { true } else { false } } }
            s.events.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }
    func finish(_ error: (any Error)? = nil) {
        let waiter = state.withLock { s in s.ended = true; s.error = error; let w = s.waiter; s.waiter = nil; return w }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }
    func next() async throws -> OperationEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<OperationEvent?, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(LauncherError.cancelled) }
                    if !s.events.isEmpty { return .success(s.events.removeFirst()) }
                    if let error = s.error { return .failure(error) }
                    if s.ended { return .success(nil) }
                    s.waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: { self.finish(LauncherError.cancelled) }
    }
}

package actor PipelineLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    init(_ limit: Int) { self.limit = limit }
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: LauncherError.cancelled) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() } else { active -= 1 }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: LauncherError.cancelled)
        }
    }
}

package struct PipelineProgressSnapshot: Sendable {
    fileprivate let sequence: UInt64
    package let event: OperationEvent
}

package final class PipelineProgress: Sendable {
    private struct State {
        var downloaded: Int64 = 0, total: Int64 = 0, staged: Int64 = 0, totalStaged: Int64 = 0
        var sequence: UInt64 = 0
        var credited = Set<String>(), predicted = Set<String>()
        var bytes: [String: Int64] = [:]
        var last = ContinuousClock.now
    }
    private let state = Mutex(State())
    private let sizes: [String: Int64]
    init(_ plan: InstallPlan) { sizes = plan.objects.mapValues(\.transferSize) }
    func initialize(downloaded: Int64, total: Int64, credited: Set<String>, predicted: Set<String>) {
        state.withLock { s in s.downloaded = downloaded; s.total = total; s.credited = credited; s.predicted = predicted }
    }
    func stage(_ staged: Int64, total: Int64) { state.withLock { $0.staged = staged; $0.totalStaged = total } }
    func total(_ value: Int64) { state.withLock { $0.total = max(value, $0.downloaded) } }
    func update(_ id: String, _ bytes: Int64) -> PipelineProgressSnapshot? {
        state.withLock { s in
            let size = sizes[id] ?? 0
            if s.predicted.insert(id).inserted { s.total = Self.add(s.total, size) }
            guard !s.credited.contains(id) else { return nil }
            let next = max(s.bytes[id] ?? 0, min(size, bytes)), previous = s.bytes[id] ?? 0
            s.bytes[id] = next; s.downloaded = Self.add(s.downloaded, next - previous)
            s.total = max(s.total, s.downloaded)
            guard s.last.duration(to: .now) >= .milliseconds(50) else { return nil }
            s.last = .now
            return Self.snapshot(&s)
        }
    }
    func snapshot() -> PipelineProgressSnapshot { state.withLock { Self.snapshot(&$0) } }
    private static func snapshot(_ s: inout State) -> PipelineProgressSnapshot {
        s.sequence += 1
        return PipelineProgressSnapshot(sequence: s.sequence, event: event(s))
    }
    func event() -> OperationEvent { state.withLock { Self.event($0) } }
    private static func event(_ s: State) -> OperationEvent {
        .progress(downloaded: s.downloaded, totalNetwork: s.total, staged: s.staged, totalStaged: s.totalStaged)
    }
    private static func add(_ a: Int64, _ b: Int64) -> Int64 { let (sum, overflow) = a.addingReportingOverflow(b); return overflow ? Int64.max : sum }
}

/// Keep the lifetime implementation private while sharing stream construction.
package func pipelineStream(abandon: @escaping @Sendable () -> Void,
    _ pull: @escaping @Sendable (@escaping @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent?) -> AsyncThrowingStream<OperationEvent, any Error> {
    let lifetime = PipelineLifetime(abandon: abandon)
    return AsyncThrowingStream(unfolding: {
        try await withTaskCancellationHandler {
            try await pull { lifetime.replace($0) }
        } onCancel: { lifetime.cancel() }
    })
}

/// Native reader/writer lock: data writes share it; a free-space snapshot takes
/// the exclusive side. Only synchronous filesystem calls run under this lock.
package final class PipelineIOGate: @unchecked Sendable {
    @TaskLocal static var objectID: String?
    @TaskLocal static var output: SafeRelativePath?
    private struct Allocation { var parts: [String: Int64] = [:]; var outputs: [SafeRelativePath: Int64] = [:] }
    private let allocation = Mutex(Allocation())
    private let pointer: UnsafeMutablePointer<pthread_rwlock_t>
    init() {
        pointer = .allocate(capacity: 1); pointer.initialize(to: pthread_rwlock_t())
        precondition(pthread_rwlock_init(pointer, nil) == 0)
    }
    deinit { pthread_rwlock_destroy(pointer); pointer.deinitialize(count: 1); pointer.deallocate() }
    func enter() { pthread_rwlock_rdlock(pointer) }
    func leave() { pthread_rwlock_unlock(pointer) }
    func snapshot<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(pointer); defer { pthread_rwlock_unlock(pointer) }
        return try body()
    }
    func opened(_ descriptor: Int32) throws {
        guard Self.objectID != nil || Self.output != nil else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect allocation") }
        record(Int64(info.st_size), replacing: true)
    }
    func wrote(_ descriptor: Int32) throws {
        guard Self.objectID != nil || Self.output != nil else { return }
        let position = lseek(descriptor, 0, SEEK_CUR)
        guard position >= 0 else { throw LauncherError.io("Cannot inspect allocation") }
        record(position, replacing: false)
    }
    private func record(_ bytes: Int64, replacing: Bool) {
        allocation.withLock { s in
            if let id = Self.objectID { s.parts[id] = replacing ? bytes : max(s.parts[id] ?? 0, bytes) }
            else if let path = Self.output { s.outputs[path] = replacing ? bytes : max(s.outputs[path] ?? 0, bytes) }
        }
    }
    func seedPart(_ id: String, bytes: Int64) { allocation.withLock { $0.parts[id] = bytes } }
    func removePart(_ id: String) { allocation.withLock { _ = $0.parts.removeValue(forKey: id) } }
    func removeOutput(_ path: SafeRelativePath) { allocation.withLock { _ = $0.outputs.removeValue(forKey: path) } }
    func allocations() -> (parts: [String: Int64], outputs: [SafeRelativePath: Int64]) { allocation.withLock { ($0.parts, $0.outputs) } }
}

package struct PipelineFileOps: AllocationFileOps {
    let base: any FileOps
    let gate: PipelineIOGate
    package func beginAllocation() { gate.enter() }
    package func endAllocation() { gate.leave() }
    package func openedForWriting(_ descriptor: Int32) throws { try gate.opened(descriptor) }
    package func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        gate.enter(); defer { gate.leave() }
        let count = try base.write(descriptor, bytes: bytes)
        try gate.wrote(descriptor)
        return count
    }
    package func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    package func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    package func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try base.unlink(name, in: directory, isDirectory: isDirectory) }
}

/// A cancelled stream may terminate without another unfolding call. Keep its
/// OS lock alive until all workers join; only resumes encountering that known
/// drain wait for it. Unrelated live operations still get nonblocking .busy.
package protocol PipelineDrainOwner: Sendable {
    func pipelineWillDrain(wait: @escaping @Sendable () async throws -> Void)
}

package final class PipelineRootRetention: Sendable {
    private final class Drain: Sendable {
        private struct State {
            var finished = false
            var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        }
        private let state = Mutex(State())
        func finish() {
            let waiters = state.withLock { s in s.finished = true; let values = Array(s.waiters.values); s.waiters.removeAll(); return values }
            for waiter in waiters { waiter.resume() }
        }
        func wait() async throws {
            OperationWork.record(.ownershipDrainWait)
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let result: Result<Void, any Error>? = state.withLock { s in
                        if Task.isCancelled { return .failure(LauncherError.cancelled) }
                        if s.finished { return .success(()) }
                        s.waiters[id] = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
                waiter?.resume(throwing: LauncherError.cancelled)
            }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
        }
    }
    private struct Entry: Sendable { let owner: UUID; let drain: Drain }
    private struct State { var lock: InstallLock?; var owner: UUID?; var active = false; var drain: Drain?; var retainedOwner: (any Sendable)? }
    private static let draining = Mutex<[String: Entry]>([:])
    private let key: String
    private let state = Mutex(State())
    init(key: String) { self.key = key }
    func hold(_ lock: InstallLock?, owner: UUID, retaining retainedOwner: (any Sendable)?) {
        state.withLock { if !$0.active { $0.lock = lock; $0.owner = owner; $0.retainedOwner = retainedOwner } }
    }
    func activate(_ owner: UUID?) { state.withLock { if $0.owner == owner { $0.active = true } } }
    func abandon(_ owner: UUID?) {
        state.withLock { s in
            guard s.owner == owner else { return }
            if !s.active { s.lock = nil; s.retainedOwner = nil; return }
            if s.drain == nil, s.lock != nil, let owner {
                let drain = Drain(); s.drain = drain
                Self.draining.withLock { $0[key] = Entry(owner: owner, drain: drain) }
                (s.retainedOwner as? any PipelineDrainOwner)?.pipelineWillDrain { try await drain.wait() }
            }
        }
    }
    func release(_ owner: UUID?) {
        let drain = state.withLock { s -> Drain? in
            guard s.owner == owner else { return nil }
            s.lock = nil; s.active = false; s.retainedOwner = nil
            let drain = s.drain; s.drain = nil
            Self.draining.withLock { if $0[key]?.owner == owner { $0.removeValue(forKey: key) } }
            return drain
        }
        drain?.finish()
    }
    static func waitIfDraining(_ key: String) async throws {
        if let drain = draining.withLock({ $0[key]?.drain }) { try await drain.wait() }
    }
}
