// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Stages verified files without modifying installed files or completing the operation.
/// The caller holds InstallLock. The returned stream owns bounded look-ahead
/// and assembly work; discarding it cancels that work and drains its root lease.
public struct Stager: Sendable {
    private let plan: InstallPlan
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let journal: OperationJournal
    private let disk: any DiskSpaceProbe
    private let maxConcurrentObjects: Int
    private let pipeline: PipelineConfiguration
    private let crashHooks: CrashHooks
    private let gate = StagingGate()
    private var durableFiles = false

    public init(plan: InstallPlan, fs: ContainedFileSystem, fetcher: ChunkFetcher, journal: OperationJournal,
        disk: any DiskSpaceProbe = SystemDiskSpaceProbe(), maxConcurrentObjects: Int = SpaceBudget.defaultMaxConcurrentObjects, crashHooks: CrashHooks = .none, pipeline: PipelineConfiguration = .default) throws {
        try plan.validate()
        try pipeline.validate()
        guard maxConcurrentObjects > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        self.plan = plan; self.fs = fs; self.fetcher = fetcher; self.journal = journal
        self.disk = disk; self.maxConcurrentObjects = maxConcurrentObjects; self.crashHooks = crashHooks; self.pipeline = pipeline
    }

    package func forRecovery() -> Self { var copy = self; copy.durableFiles = true; return copy }

    /// One bounded window may run ahead. Byte progress is coalesced, while every
    /// fileVerified event is retained. Discarding the iterator cancels workers.
    public func stage(files: [FileTask]) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = StagingSession(plan: plan, files: files, fs: fs, fetcher: fetcher, journal: journal,
            disk: disk, limit: maxConcurrentObjects, lease: StagingLease(gate: gate), crashHooks: crashHooks, pipeline: pipeline, durableFiles: durableFiles)
        return pipelineStream(abandon: { Task { await session.abandon(nil) } }) { try await session.next(register: $0) }
    }
    package func forOperation() throws -> OperationStager {
        let retention = PipelineRootRetention(key: fs.caseFoldedPathKey(for: try SafeRelativePath(".macgacha-staging/.lock")))
        return OperationStager(retention: retention, session: StagingSession(plan: plan, files: [], fs: fs, fetcher: fetcher, journal: journal,
            disk: disk, limit: maxConcurrentObjects, lease: StagingLease(gate: gate), crashHooks: crashHooks, pipeline: pipeline, retention: retention, durableFiles: durableFiles))
    }

}

/// One validated plan, referrer index and progress history for the locked operation.
package struct OperationStager: Sendable {
    fileprivate let retention: PipelineRootRetention
    fileprivate let session: StagingSession
    package func stage(files: [FileTask], holding lock: InstallLock? = nil, retaining owner: (any Sendable)? = nil) -> AsyncThrowingStream<OperationEvent, any Error> {
        let token = UUID()
        retention.hold(lock, owner: token, retaining: owner)
        return pipelineStream(abandon: { retention.abandon(token); Task { await session.abandon(token) } }) {
            try await session.next(files: files, token: token, register: $0)
        }
    }
    package func committed(_ files: [FileTask]) async throws { try await session.committed(files) }
}

private final class StagingGate: Sendable {
    private let active = Mutex<UUID?>(nil)
    func claim(_ id: UUID) throws {
        try active.withLock { current in
            guard current == nil || current == id else { throw LauncherError.busy("staging already in use") }
            current = id
        }
    }
    func release(_ id: UUID) {
        let released = active.withLock { value in
            if value == id { value = nil; return true }; return false
        }
        if released { OperationWork.record(.stagingLeaseReleased) }
    }
}

private final class StagingLease: Sendable {
    private let id = UUID()
    private let gate: StagingGate
    init(gate: StagingGate) { self.gate = gate }
    func claim() throws { try gate.claim(id) }
    func release() { gate.release(id) }
    deinit { gate.release(id) }
}

private actor StagingSession {
    private let durableFiles: Bool
    private enum Step { case start, file, progress, done }
    private let plan: InstallPlan
    private var files: [FileTask]
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let journal: OperationJournal
    private let disk: any DiskSpaceProbe
    private let limit: Int
    private let pipeline: PipelineConfiguration
    private let transferLimiter: PipelineLimiter
    private let assemblyLimiter: PipelineLimiter
    private let progressTracker: PipelineProgress
    private let ioGate: PipelineIOGate
    private var inFlightObjects = Set<String>()
    private var transfers: [String: Task<Int, any Error>] = [:]
    private var runningOutputs = Set<SafeRelativePath>()
    private var wave: PipelineChannel?
    private var waveTask: Task<Void, Never>?
    private let retention: PipelineRootRetention
    private let lease: StagingLease
    private let crashHooks: CrashHooks
    private let layout: StagingLayout
    private let referrers: [String: Set<SafeRelativePath>]
    private let known: [SafeRelativePath: FileTask]
    private var initialized = false
    private var token: UUID?
    private var donePaths = Set<SafeRelativePath>()
    private var step = Step.start
    private var state = JournalState()
    private var cursor = 0
    private var downloaded: Int64 = 0
    private var totalNetwork: Int64 = 0
    private var networkObjects = Set<String>()
    private var downloadedObjects = Set<String>()
    private var objectMirrors: [String: Int] = [:]
    private var objectFailures: [String: Int] = [:]
    private var staged: Int64 = 0
    private var totalStaged: Int64 = 0
    private var allocation: RemainingAllocation?
    private var lastProgress: OperationEvent?

    init(plan: InstallPlan, files: [FileTask], fs: ContainedFileSystem, fetcher: ChunkFetcher,
        journal: OperationJournal, disk: any DiskSpaceProbe, limit: Int, lease: StagingLease, crashHooks: CrashHooks, pipeline: PipelineConfiguration, retention: PipelineRootRetention = PipelineRootRetention(key: ""), durableFiles: Bool = false) {
        let ioGate = PipelineIOGate(); self.ioGate = ioGate
        self.plan = plan; self.files = files; self.fs = fs.replacingFileOps(PipelineFileOps(base: fs.fileOps, gate: ioGate)); self.fetcher = fetcher; self.journal = journal
        self.disk = disk; self.limit = limit; self.lease = lease; self.crashHooks = crashHooks; layout = StagingLayout(id: plan.id)
        OperationWork.record(.referrerIndexBuild)
        self.retention = retention; self.durableFiles = durableFiles
        self.pipeline = pipeline; transferLimiter = PipelineLimiter(limit); assemblyLimiter = PipelineLimiter(pipeline.assemblies)
        progressTracker = PipelineProgress(plan)
        var refs: [String: Set<SafeRelativePath>] = [:]
        for file in plan.files { for id in SpaceBudget.references(file) { refs[id, default: []].insert(file.path) } }
        referrers = refs
        known = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, $0) })
    }

    func next(files incoming: [FileTask], token incomingToken: UUID, register: @escaping @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        if token != incomingToken {
            guard token == nil || step == .done else { throw LauncherError.busy("staging already in use") }
            retention.activate(incomingToken)
            token = incomingToken; files = incoming; cursor = 0; allocation = nil; lastProgress = nil; step = .start
        }
        return try await next(register: register)
    }

    func committed(_ batch: [FileTask]) throws {
        for file in batch { try state.apply(.fileCommitted(path: file.path)); donePaths.insert(file.path) }
    }

    func next(register: @escaping @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        if step == .done { return nil }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            try lease.claim()
            switch step {
            case .start:
                try await prepare()
                step = .file
                return progress()
            case .progress:
                step = .file
                return progress()
            case .file:
                while true {
                    if let channel = wave {
                        if let event = try await channel.next() {
                            if case .progress = event { lastProgress = event }
                            return event
                        }
                        wave = nil
                    }
                    let selected = try nextWindow()
                    if selected.isEmpty { break }
                    let channel = PipelineChannel(); wave = channel
                    let task = Task { await self.runWindow(selected, channel: channel) }
                    waveTask = task
                    register(task)
                }
                // Drop predictions satisfied through local reuse. Refcounts avoid
                // rehashing future local ranges merely to display final progress.
                reconcileFinishedPredictions()
                step = .done; retention.release(token); lease.release()
                progressTracker.total(totalNetwork)
                let previous = lastProgress
                let event = progress()
                return event == previous ? nil : event
            case .done: return nil
            }
        } catch {
            step = .done; cancelTransfers(); waveTask?.cancel()
            await waveTask?.value
            retention.release(token); lease.release()
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func prepare() async throws {
        guard Set(files.map(\.path)).count == files.count, files.allSatisfy({ known[$0.path] == $0 }) else {
            throw LauncherError.io("Staging files are not a unique subset of the plan")
        }
        if !initialized {
            state = try await journal.snapshot()
            for file in plan.files where state.stagedFiles.contains(file.path) && !state.committedFiles.contains(file.path) {
                if try await !FileAssembler.matches(file, plan: plan, fs: fs) { try await record(.fileUnstaged(path: file.path)) }
            }
            donePaths = state.stagedFiles.union(state.committedFiles)
            // A synced journal line does not make disposable part data durable.
            // Validate resident transfer bytes once per operation before reuse.
            for id in state.verifiedObjects {
                guard let object = plan.objects[id], referrers[id]?.isSubset(of: donePaths) != true else { continue }
                let part = try layout.object(object)
                if try fs.size(at: part) != nil, try await !ChunkFetcher.verifiedPart(object, fs: fs, part: part) {
                    try fs.removeFile(at: part)
                    objectFailures[id] = 1
                    objectMirrors[id] = 1 % object.urls.count
                }
            }
            downloadedObjects = state.verifiedObjects.intersection(plan.objects.keys)
            for file in plan.files where donePaths.contains(file.path) {
                for extent in file.extents { if case .chunk(let id) = extent.source { downloadedObjects.insert(id) } }
            }
            downloaded = progressBytes(downloadedObjects)
            try refreshNetworkPrediction()
            progressTracker.initialize(downloaded: downloaded, total: totalNetwork, credited: downloadedObjects, predicted: networkObjects)
            try cleanupObjects(ids: Set(plan.objects.keys))
            initialized = true
        }
        let remaining = files.filter { !donePaths.contains($0.path) }, selected = Set(files.map(\.path))
        // Unjournaled output is disposable (and may be sparse after an older
        // writer). Reclaim it before crediting allocation or doing preflight.
        for file in remaining {
            let path = try layout.file(file.path)
            if try fs.size(at: path) != nil { try fs.removeFile(at: path) }
        }
        let objects = try SpaceBudget.networkObjectIDs(files: remaining, plan: plan, state: state, fs: fs)
        var external = Set<String>()
        for file in remaining {
            for id in SpaceBudget.references(file) {
                if referrers[id]?.contains(where: { !selected.contains($0) && !donePaths.contains($0) }) == true { external.insert(id) }
            }
        }
        allocation = try RemainingAllocation(files: remaining,
            costs: Dictionary(uniqueKeysWithValues: objects.map { ($0, plan.objects[$0]!.transferSize) }),
            retainedObjects: external, limit: limit, pipeline: pipeline)
        try checkCapacity()
        // Recheck only this batch's sources. Initial prediction visited future
        // ranges once; commits can invalidate later reuse without a rescan.
        for id in objects where networkObjects.insert(id).inserted { totalNetwork = progressAdding(totalNetwork, plan.objects[id]!.transferSize) }
        let uncommitted = files.filter { !state.committedFiles.contains($0.path) }
        totalStaged = try uncommitted.reduce(Int64(0)) { try SpaceBudget.adding($0, $1.size) }
        staged = try uncommitted.filter { state.stagedFiles.contains($0.path) }.reduce(Int64(0)) { try SpaceBudget.adding($0, $1.size) }
        progressTracker.stage(staged, total: totalStaged)
    }

    private func progress() -> OperationEvent {
        let event = progressTracker.event()
        lastProgress = event
        return event
    }

    /// Display only: an unreadable local range predicts its fallback; actual
    /// staging owns the I/O error policy. Predictions never authorize transfers.
    private func refreshNetworkPrediction() throws {
        var predicted = downloadedObjects
        let done = state.stagedFiles.union(state.committedFiles)
        for file in plan.files where !done.contains(file.path) {
            OperationWork.record(.predictionFile)
            for extent in file.extents {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                switch extent.source {
                case .chunk(let id): predicted.insert(id)
                case .local(let path, let offset):
                    if let fallback = extent.fallbackChunkID,
                        (try? LocalRange.matches(path: path, offset: offset, length: extent.length, digest: extent.digest, fs: fs)) != true {
                        predicted.insert(fallback)
                    }
                }
            }
        }
        networkObjects = predicted
        totalNetwork = progressBytes(predicted)
    }

    private func progressBytes(_ ids: Set<String>) -> Int64 {
        ids.reduce(Int64(0)) { progressAdding($0, plan.objects[$1]?.transferSize ?? 0) }
    }
    private func progressAdding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : sum
    }

    private func reconcileFinishedPredictions() {
        for file in files {
            for id in SpaceBudget.references(file) where !downloadedObjects.contains(id) {
                if referrers[id]?.isSubset(of: donePaths) == true, networkObjects.remove(id) != nil {
                    totalNetwork -= plan.objects[id]!.transferSize
                }
            }
        }
    }

    private func record(_ record: JournalRecord) async throws {
        try await journal.append(record)
        try state.apply(record)
        switch record {
        case .fileStaged(let path): donePaths.insert(path)
        case .fileUnstaged(let path): if !state.committedFiles.contains(path) { donePaths.remove(path) }
        default: break
        }
    }

    private func fetchObjects(_ ids: Set<String>, channel: PipelineChannel? = nil) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            func submit(_ id: String) {
                OperationWork.record(.fetchTaskSubmitted)
                group.addTask { defer { OperationWork.record(.fetchTaskFinished) }; try await self.fetchObject(id, channel: channel) }
            }
            for _ in 0..<min(limit, ids.count) { if let id = iterator.next() { submit(id) } }
            do {
                while let _ = try await group.next() {
                    try Task.checkCancellation()
                    if let id = iterator.next() { submit(id) }
                }
            }
            catch { group.cancelAll(); cancelTransfers(); throw error }
        }
    }

    private func fetchObject(_ id: String, channel: PipelineChannel?) async throws {
        try Task.checkCancellation()
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        if !inFlightObjects.contains(id), state.verifiedObjects.contains(id) {
            if try fs.size(at: layout.object(object)) == object.transferSize { return }
            transfers.removeValue(forKey: id)
        }
        let task: Task<Int, any Error>
        if let existing = transfers[id] { task = existing }
        else {
            let fs = fs, fetcher = fetcher, journal = journal, layout = layout, crashHooks = crashHooks
            let limiter = transferLimiter, tracker = progressTracker, mirror = objectMirrors[id] ?? 0
            inFlightObjects.insert(id)
            task = Task {
                defer { self.inFlightObjects.remove(id) }
                try await limiter.acquire()
                do {
                    let mirror = try await PipelineIOGate.$objectID.withValue(id) {
                        try await fetcher.fetch(object, fs: fs, part: layout.object(object), startingMirror: mirror,
                            progress: { if let event = tracker.update(id, $0) { channel?.send(event) } })
                    }
                    try await journal.append(.objectVerified(id: id))
                    crashHooks.reach(.afterObjectVerified)
                    try self.completedFetch(object, mirror: mirror)
                    await limiter.release()
                    return mirror
                } catch { await limiter.release(); throw error }
            }
            transfers[id] = task
        }
        do {
            _ = try await task.value
            transfers.removeValue(forKey: id)
            try Task.checkCancellation()
        } catch {
            if error is CorruptObjectError { throw AssemblyBadObject(id: id, cause: error) }
            if let value = error as? LauncherError {
                switch value {
                case .digestMismatch, .sizeMismatch: throw AssemblyBadObject(id: id, cause: value)
                default: break
                }
            }
            throw error
        }
    }

    private func completedFetch(_ object: ChunkObject, mirror: Int) throws {
        let id = object.id
        objectMirrors[id] = mirror
        try state.apply(.objectVerified(id: id)); try allocation?.setCost(id, to: 0)
        if networkObjects.insert(id).inserted { totalNetwork = progressAdding(totalNetwork, object.transferSize) }
        if downloadedObjects.insert(id).inserted { downloaded = progressAdding(downloaded, object.transferSize) }
    }

    private func cancelTransfers() { for task in transfers.values { task.cancel() } }

    private func nextWindow() throws -> [FileTask] {
        var selected: [FileTask] = [], ids = Set<String>(), bytes: Int64 = 0
        while cursor < files.count {
            let file = files[cursor]
            if donePaths.contains(file.path) { cursor += 1; continue }
            let direct = Set(file.extents.compactMap { if case .chunk(let id) = $0.source { id } else { nil as String? } })
            let referenced = SpaceBudget.references(file).filter { networkObjects.contains($0) || direct.contains($0) }
            let added = referenced.filter { !ids.contains($0) }
            let size = try added.reduce(Int64(0)) { try SpaceBudget.adding($0, plan.objects[$1]!.transferSize) }
            if !selected.isEmpty, (ids.count + added.count > pipeline.prefetchObjects || size > pipeline.prefetchBytes - min(bytes, pipeline.prefetchBytes)
                || selected.count >= pipeline.prefetchObjects) { break }
            selected.append(file); ids.formUnion(added); bytes = try SpaceBudget.adding(bytes, size); cursor += 1
            if bytes >= pipeline.prefetchBytes || ids.count >= pipeline.prefetchObjects { break }
        }
        return selected
    }

    private func runWindow(_ selected: [FileTask], channel: PipelineChannel) async {
        do {
            while true {
                try Task.checkCancellation()
                do {
                    try await withTaskCancellationHandler {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            for file in selected where !donePaths.contains(file.path) {
                                group.addTask { try await self.stageFile(file, channel: channel) }
                            }
                            do { while let _ = try await group.next() {} }
                            catch { group.cancelAll(); cancelTransfers(); throw error }
                        }
                    } onCancel: { Task { await self.cancelWindow() } }
                    break
                } catch let bad as AssemblyBadObject {
                    // The group has cancelled AND joined every reader before
                    // shared part replacement. No worker can open a stale path.
                    try Task.checkCancellation()
                    guard let object = plan.objects[bad.id] else { throw bad.cause }
                    cancelTransfers()
                    for task in transfers.values { _ = await task.result }
                    transfers.removeAll(); inFlightObjects.removeAll()
                    try cleanupObjects(ids: Set(selected.flatMap { SpaceBudget.references($0) }))
                    try fs.removeFile(at: layout.object(object)); ioGate.removePart(bad.id)
                    for file in selected where !donePaths.contains(file.path) {
                        try fs.removeFile(at: layout.file(file.path))
                        ioGate.removeOutput(file.path); runningOutputs.remove(file.path)
                        try await record(.fileUnstaged(path: file.path))
                    }
                    objectFailures[bad.id, default: 0] += 1
                    guard objectFailures[bad.id, default: 0] < object.urls.count + 1 else { throw bad.cause }
                    objectMirrors[bad.id] = ((objectMirrors[bad.id] ?? 0) + 1) % object.urls.count
                }
            }
            // All readers and their transfers have joined. Keep completed Task
            // storage bounded by this window, rather than the full game plan.
            transfers.removeAll()
            channel.finish()
        } catch {
            cancelTransfers()
            for task in transfers.values { _ = await task.result }
            channel.finish(Task.isCancelled || error is CancellationError ? LauncherError.cancelled : error)
        }
    }
    private func cancelWindow() { cancelTransfers() }
    func abandon(_ owner: UUID?) async {
        guard token == owner else { retention.release(owner); return }
        waveTask?.cancel(); cancelTransfers()
        await waveTask?.value
        guard token == owner else { return }
        step = .done; retention.release(token); lease.release()
    }

    private func stageFile(_ file: FileTask, channel: PipelineChannel) async throws {
        var wholeFileFailures = 0
        let wholeFileAttemptLimit = 2
        while true {
            do {
                let direct = Set(file.extents.compactMap { extent -> String? in
                    if case .chunk(let id) = extent.source { return id }; return nil
                })
                // A retry may have deleted a corrupt part; admit it again before
                // allocating. Unfinished output already occupies disk space.
                for id in direct { try admitMissingPart(id) }
                try checkCapacity(written: min(file.size, try fs.size(at: layout.file(file.path)) ?? 0))
                try await fetchObjects(direct, channel: channel)
                try await assemblyLimiter.acquire()
                runningOutputs.insert(file.path)
                do {
                    try await PipelineIOGate.$output.withValue(file.path) {
                        try await FileAssembler.assemble(file, plan: plan, fs: fs, durable: durableFiles) { id in
                            try await self.fetchFallback(id, channel: channel)
                        }
                    }
                    await assemblyLimiter.release()
                } catch { await assemblyLimiter.release(); throw error }
                crashHooks.reach(.afterFileStagedBeforeJournal)
                try await record(.fileStaged(path: file.path))
                try allocation?.finish(file)
                runningOutputs.remove(file.path); ioGate.removeOutput(file.path)
                staged = try SpaceBudget.adding(staged, file.size)
                progressTracker.stage(staged, total: totalStaged)
                channel.send(.fileVerified(file.path)); channel.send(progressTracker.snapshot())
                try cleanupObjects(ids: SpaceBudget.references(file))
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                if let bad = error as? AssemblyBadObject { throw bad }
                let failure = error
                guard failure is CorruptObjectError || failure is LauncherError else {
                    throw LauncherError.io("Cannot stage file")
                }
                let corrupt: Bool
                if failure is CorruptObjectError { corrupt = true }
                else if let failure = failure as? LauncherError {
                    switch failure { case .digestMismatch, .sizeMismatch: corrupt = true; default: corrupt = false }
                } else { corrupt = false }
                if corrupt {
                    wholeFileFailures += 1
                    let canRetry = wholeFileFailures < wholeFileAttemptLimit
                    try fs.removeFile(at: layout.file(file.path)); ioGate.removeOutput(file.path)
                    try await record(.fileUnstaged(path: file.path))
                    if !canRetry { throw failure }
                } else { throw failure }
            }
        }
    }

    private func fetchFallback(_ id: String, channel: PipelineChannel) async throws {
        try Task.checkCancellation()
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        let part = try layout.object(object)
        let resident = try state.verifiedObjects.contains(id) && fs.size(at: part) == object.transferSize
        if !resident {
            try admitMissingPart(id)
            do { try checkCapacity() }
            catch { try fs.removeFile(at: part); throw error }
        }
        try await fetchObject(id, channel: channel)
    }

    private func admitMissingPart(_ id: String) throws {
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        let size = try ioGate.snapshot {
            let size = try fs.size(at: layout.object(object)) ?? 0
            ioGate.seedPart(id, bytes: min(size, object.transferSize))
            return size
        }
        let cached = state.verifiedObjects.contains(id) && size == object.transferSize
        try allocation?.setCost(id, to: cached ? 0 : object.transferSize)
    }

    private func checkCapacity(written: Int64 = 0) throws {
        try ioGate.snapshot {
            let snapshot = ioGate.allocations()
            var allocated: Int64 = 0
            for path in runningOutputs { allocated = try SpaceBudget.adding(allocated, min(known[path]!.size, snapshot.outputs[path] ?? 0)) }
            let partial = snapshot.parts
            guard let required = try allocation?.disk(written: max(written, allocated), partialParts: partial) else { throw LauncherError.io("Missing session allocation") }
            let available = try fs.availableBytes(using: disk)
            guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
        }
    }

    private func cleanupObjects(ids: Set<String>) throws {
        for id in ids {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if let refs = referrers[id], refs.isSubset(of: donePaths), let object = plan.objects[id] {
                try fs.removeFile(at: layout.object(object))
                transfers.removeValue(forKey: id); ioGate.removePart(id)
            }
        }
    }
}
