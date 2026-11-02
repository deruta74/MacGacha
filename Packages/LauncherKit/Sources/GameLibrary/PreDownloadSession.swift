// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import LauncherCore
import DownloadEngine

struct PreparedPreDownload: Sendable {
    let transfer: PreDownloadTransfer
    let lease: GameOperationLease
    let lock: InstallLock
}

/// Transfer tasks must not capture exclusion ownership: the drain barrier drops
/// that ownership before waking callers, independently of the task's lifetime.
struct PreDownloadTransfer: Sendable {
    let state: PreDownloadState
    let cache: PreDownloadStore
    let fetcher: ChunkFetcher
    let disk: any DiskSpaceProbe
    let hooks: CrashHooks
    let maxConcurrentObjects: Int
    let pipeline: PipelineConfiguration
}

/// Owns only cache transfer work. There is no normal completion receipt or
/// installed-record advancement, even when every container has arrived.
actor PreDownloadSession {
    /// Scoped diagnostic seam after transfer work and ownership release, before
    /// the worker task returns. Normal operations leave it unset.
    @TaskLocal static var afterWorkerRelease: (@Sendable () async -> Void)? = nil
    nonisolated private let queue = DispatchSerialQueue(label: "org.macgacha.predownload")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let library: GameLibrary
    private let game: GameDefinition
    private let resume: Bool
    private let expected: SafeIdentifier?
    private let owner = UUID()
    private let retention = PipelineRootRetention(key: "predownload-" + UUID().uuidString)
    private let channel = PipelineChannel()
    private var worker: Task<Void, Never>?
    private var pulling = false
    init(library: GameLibrary, game: GameDefinition, resume: Bool, expected: SafeIdentifier?) {
        self.library = library; self.game = game; self.resume = resume; self.expected = expected
    }
    nonisolated func stream() -> AsyncThrowingStream<OperationEvent, any Error> {
        pipelineStream(abandon: { [retention, owner] in
            retention.abandon(owner); Task { await self.abandon() }
        }) { try await self.next(register: $0) }
    }
    private func next(register: @escaping @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("pre-download stream already in use") }
        pulling = true; defer { pulling = false }
        do {
            if worker == nil {
                let prepared = try await prepareTransfer()
                let retention = retention, owner = owner, channel = channel
                let task = Task {
                    do { try await Self.transfer(prepared, channel: channel); channel.finish() }
                    catch { channel.finish(Task.isCancelled || error is CancellationError ? LauncherError.cancelled : error) }
                    retention.release(owner)
                    await Self.afterWorkerRelease?()
                }
                worker = task; register(task)
            }
            let event = try await channel.next()
            if event == .phase(.completed) || event == nil { await worker?.value }
            return event
        } catch {
            worker?.cancel(); await worker?.value
            retention.release(owner)
            throw Task.isCancelled || error is CancellationError ? LauncherError.cancelled : error
        }
    }
    private func abandon() async { worker?.cancel(); await worker?.value; retention.release(owner) }

    private func prepareTransfer() async throws -> PreDownloadTransfer {
        // Discovery runs in the consumer task. Return only transfer inputs, so
        // this frame's extra lease/lock references are gone before work starts.
        let prepared = try await library.preparePreDownload(game, resume: resume, expected: expected)
        try Task.checkCancellation()
        retention.hold(prepared.lock, owner: owner, retaining: prepared.lease); retention.activate(owner)
        return prepared.transfer
    }

    @concurrent private static func transfer(_ prepared: PreDownloadTransfer, channel: PipelineChannel) async throws {
        try await BlockingIO.run {
            var state = prepared.state
            let cache = prepared.cache, plan = state.plan
            let objects = plan.containers.values.map(\.object).sorted { $0.id < $1.id }
            let progress = PipelineProgress(sizes: plan.containers.mapValues { $0.object.transferSize })
            channel.send(.phase(.verifying))
            // Journaled receipts are revalidated once on each run; a complete
            // unjournaled part is also adopted without a redundant HTTP request.
            for object in objects {
                try Task.checkCancellation()
                let part = try cache.part(object), size = try cache.fs.size(at: part)
                if size == object.transferSize, try await ChunkFetcher.verifiedPart(object, fs: cache.fs, part: part) {
                    state.verified.insert(object.id)
                } else {
                    state.verified.remove(object.id)
                    if let size, size >= object.transferSize { try cache.fs.removeFile(at: part) }
                }
            }
            state.completed = false; try cache.save(state)
            let downloaded = try state.verified.reduce(Int64(0)) { try SpaceBudget.adding($0, plan.containers[$1]!.object.transferSize) }
            progress.initialize(downloaded: downloaded, total: try plan.bytes, credited: state.verified, predicted: Set(plan.containers.keys))
            channel.send(.phase(.checkingSpace)); channel.send(progress.snapshot())
            let pending = objects.filter { !state.verified.contains($0.id) }
            var cursor = 0
            while cursor < pending.count {
                try Task.checkCancellation()
                // No worker is writing between windows: this live capacity
                // snapshot cannot race truncation or count bytes twice. Reserve
                // all remaining cache growth, since completed parts stay resident.
                let remaining = try pending[cursor...].reduce(Int64(0)) { total, object in
                    let size = min(object.transferSize, try cache.fs.size(at: cache.part(object)) ?? 0)
                    return try SpaceBudget.adding(total, object.transferSize - size)
                }
                let required = try SpaceBudget.adding(SpaceBudget.margin, remaining), available = try cache.fs.availableBytes(using: prepared.disk)
                guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
                if cursor == 0 { channel.send(.phase(.staging)) }
                // Match normal prefetch bounds, including one oversized object
                // running alone. Only the concurrency limit's tasks are submitted;
                // a campaign never creates a task/waiter for every container.
                let start = cursor
                var bytes: Int64 = 0
                while cursor < pending.count, cursor - start < prepared.pipeline.prefetchObjects {
                    let size = pending[cursor].transferSize
                    if cursor > start, size > prepared.pipeline.prefetchBytes - min(bytes, prepared.pipeline.prefetchBytes) { break }
                    bytes = try SpaceBudget.adding(bytes, size); cursor += 1
                    if bytes >= prepared.pipeline.prefetchBytes { break }
                }
                try await withThrowingTaskGroup(of: ChunkObject.self) { group in
                    var iterator = pending[start..<cursor].makeIterator()
                    func submit(_ object: ChunkObject) {
                        OperationWork.record(.fetchTaskSubmitted)
                        group.addTask {
                            defer { OperationWork.record(.fetchTaskFinished) }
                            return try await BlockingIO.run {
                                let part = try cache.part(object)
                                try await prepared.fetcher.fetch(object, fs: cache.fs, part: part) { bytes in
                                    if let snapshot = progress.update(object.id, bytes) { channel.send(snapshot) }
                                }
                                try cache.fs.fullSync(at: part)
                                return object
                            }
                        }
                    }
                    for _ in 0..<min(prepared.maxConcurrentObjects, cursor - start) {
                        if let object = iterator.next() { submit(object) }
                    }
                    do {
                        while let object = try await group.next() {
                            try Task.checkCancellation()
                            // Only this coordinator publishes receipts. Each
                            // worker verified and synced payload before returning.
                            state.verified.insert(object.id); try cache.save(state)
                            prepared.hooks.reach(.afterPreDownloadObjectStored)
                            _ = progress.update(object.id, object.transferSize); channel.send(progress.snapshot())
                            if let object = iterator.next() { submit(object) }
                        }
                    } catch { group.cancelAll(); throw error } // The scope joins every sibling before releasing exclusion.
                }
            }
            try Task.checkCancellation()
            state.completed = true; try cache.save(state)
            prepared.hooks.reach(.afterPreDownloadCompleted)
            channel.send(progress.snapshot()); channel.send(.phase(.completed))
        }
    }
}
