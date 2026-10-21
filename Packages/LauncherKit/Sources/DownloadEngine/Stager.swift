// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore

/// Stages verified files without modifying installed files or completing the operation.
/// The caller holds InstallLock. Each stream rereads the journal when first consumed.
public struct Stager: Sendable {
    private let plan: InstallPlan
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let journal: OperationJournal
    private let disk: any DiskSpaceProbe
    private let maxConcurrentObjects: Int
    private let crashHooks: CrashHooks
    private let gate = StagingGate()

    public init(plan: InstallPlan, fs: ContainedFileSystem, fetcher: ChunkFetcher, journal: OperationJournal,
        disk: any DiskSpaceProbe = SystemDiskSpaceProbe(), maxConcurrentObjects: Int = SpaceBudget.defaultMaxConcurrentObjects, crashHooks: CrashHooks = .none) throws {
        try plan.validate()
        guard maxConcurrentObjects > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        self.plan = plan; self.fs = fs; self.fetcher = fetcher; self.journal = journal
        self.disk = disk; self.maxConcurrentObjects = maxConcurrentObjects; self.crashHooks = crashHooks
    }

    /// Pull-driven: no producer or unbounded event buffer survives a stopped consumer.
    /// Progress is emitted initially and after each file; every fileVerified event is delivered.
    public func stage(files: [FileTask]) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = StagingSession(plan: plan, files: files, fs: fs, fetcher: fetcher, journal: journal,
            disk: disk, limit: maxConcurrentObjects, lease: StagingLease(gate: gate), crashHooks: crashHooks)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }
    package func forOperation() -> OperationStager {
        OperationStager(session: StagingSession(plan: plan, files: [], fs: fs, fetcher: fetcher, journal: journal,
            disk: disk, limit: maxConcurrentObjects, lease: StagingLease(gate: gate), crashHooks: crashHooks))
    }

}

/// One validated plan, referrer index and progress history for the locked operation.
package struct OperationStager: Sendable {
    fileprivate let session: StagingSession
    package func stage(files: [FileTask]) -> AsyncThrowingStream<OperationEvent, any Error> {
        let token = UUID()
        return AsyncThrowingStream(unfolding: { try await session.next(files: files, token: token) })
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
    func release(_ id: UUID) { active.withLock { if $0 == id { $0 = nil } } }
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
    private enum Step { case start, file, progress, done }
    private let plan: InstallPlan
    private var files: [FileTask]
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let journal: OperationJournal
    private let disk: any DiskSpaceProbe
    private let limit: Int
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
    private var staged: Int64 = 0
    private var totalStaged: Int64 = 0
    private var allocation: RemainingAllocation?
    private var lastProgress: OperationEvent?

    init(plan: InstallPlan, files: [FileTask], fs: ContainedFileSystem, fetcher: ChunkFetcher,
        journal: OperationJournal, disk: any DiskSpaceProbe, limit: Int, lease: StagingLease, crashHooks: CrashHooks) {
        self.plan = plan; self.files = files; self.fs = fs; self.fetcher = fetcher; self.journal = journal
        self.disk = disk; self.limit = limit; self.lease = lease; self.crashHooks = crashHooks; layout = StagingLayout(id: plan.id)
        OperationWork.record(.referrerIndexBuild)
        var refs: [String: Set<SafeRelativePath>] = [:]
        for file in plan.files { for id in SpaceBudget.references(file) { refs[id, default: []].insert(file.path) } }
        referrers = refs
        known = Dictionary(uniqueKeysWithValues: plan.files.map { ($0.path, $0) })
    }

    func next(files incoming: [FileTask], token incomingToken: UUID) async throws -> OperationEvent? {
        if token != incomingToken {
            guard token == nil || step == .done else { throw LauncherError.busy("staging already in use") }
            token = incomingToken; files = incoming; cursor = 0; allocation = nil; lastProgress = nil; step = .start
        }
        return try await next()
    }

    func committed(_ batch: [FileTask]) throws {
        for file in batch { try state.apply(.fileCommitted(path: file.path)); donePaths.insert(file.path) }
    }

    func next() async throws -> OperationEvent? {
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
                while cursor < files.count {
                    let file = files[cursor]; cursor += 1
                    if state.stagedFiles.contains(file.path) || state.committedFiles.contains(file.path) { continue }
                    try await stageFile(file)
                    staged = try SpaceBudget.adding(staged, file.size)
                    step = .progress
                    return .fileVerified(file.path)
                }
                // Drop predictions satisfied through local reuse. Refcounts avoid
                // rehashing future local ranges merely to display final progress.
                reconcileFinishedPredictions()
                let final = OperationEvent.progress(downloaded: downloaded, totalNetwork: totalNetwork, staged: staged, totalStaged: totalStaged)
                step = .done; lease.release()
                return final == lastProgress ? nil : progress()
            case .done: return nil
            }
        } catch {
            step = .done; lease.release()
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
                if try fs.size(at: layout.file(file.path)) != file.size { try await record(.fileUnstaged(path: file.path)) }
            }
            donePaths = state.stagedFiles.union(state.committedFiles)
            downloadedObjects = state.verifiedObjects.intersection(plan.objects.keys)
            for file in plan.files where donePaths.contains(file.path) {
                for extent in file.extents { if case .chunk(let id) = extent.source { downloadedObjects.insert(id) } }
            }
            downloaded = progressBytes(downloadedObjects)
            try refreshNetworkPrediction()
            try cleanupObjects(ids: Set(plan.objects.keys))
            initialized = true
        }
        let remaining = files.filter { !donePaths.contains($0.path) }, selected = Set(files.map(\.path))
        let objects = try SpaceBudget.networkObjectIDs(files: remaining, plan: plan, state: state, fs: fs)
        var external = Set<String>()
        for file in remaining {
            for id in SpaceBudget.references(file) {
                if referrers[id]?.contains(where: { !selected.contains($0) && !donePaths.contains($0) }) == true { external.insert(id) }
            }
        }
        allocation = try RemainingAllocation(files: remaining,
            costs: Dictionary(uniqueKeysWithValues: objects.map { ($0, plan.objects[$0]!.transferSize) }),
            retainedObjects: external, limit: limit)
        let written = try remaining.first.map { min($0.size, try fs.size(at: layout.file($0.path)) ?? 0) } ?? 0
        try checkCapacity(written: written)
        // Recheck only this batch's sources. Initial prediction visited future
        // ranges once; commits can invalidate later reuse without a rescan.
        for id in objects where networkObjects.insert(id).inserted { totalNetwork = progressAdding(totalNetwork, plan.objects[id]!.transferSize) }
        let uncommitted = files.filter { !state.committedFiles.contains($0.path) }
        totalStaged = try uncommitted.reduce(Int64(0)) { try SpaceBudget.adding($0, $1.size) }
        staged = try uncommitted.filter { state.stagedFiles.contains($0.path) }.reduce(Int64(0)) { try SpaceBudget.adding($0, $1.size) }
    }

    private func progress() -> OperationEvent {
        let event = OperationEvent.progress(downloaded: downloaded, totalNetwork: totalNetwork, staged: staged, totalStaged: totalStaged)
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

    private func fetchObjects(_ ids: Set<String>) async throws {
        var needed: [ChunkObject] = []
        for id in ids.sorted() {
            guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
            if state.verifiedObjects.contains(id), try fs.size(at: layout.object(object)) == object.transferSize { continue }
            needed.append(object)
        }
        let fs = fs, fetcher = fetcher, journal = journal, layout = layout, crashHooks = crashHooks
        // Capture only this fetch set: copying the growing full-plan mirror map on
        // every file would force quadratic copy-on-write work at game scale.
        let mirrors = Dictionary(uniqueKeysWithValues: needed.map { ($0.id, objectMirrors[$0.id] ?? 0) })
        try await withThrowingTaskGroup(of: (ChunkObject, Int).self) { group in
            var next = 0
            func submit(_ object: ChunkObject) {
                group.addTask {
                    let mirror = try await fetcher.fetch(object, fs: fs, part: layout.object(object),
                        startingMirror: mirrors[object.id] ?? 0, progress: { _ in })
                    try await journal.append(.objectVerified(id: object.id))
                    crashHooks.reach(.afterObjectVerified)
                    return (object, mirror)
                }
            }
            while next < min(limit, needed.count) { submit(needed[next]); next += 1 }
            while let (object, mirror) = try await group.next() {
                objectMirrors[object.id] = mirror
                try state.apply(.objectVerified(id: object.id))
                try allocation?.setCost(object.id, to: 0)
                if networkObjects.insert(object.id).inserted {
                    totalNetwork = progressAdding(totalNetwork, object.transferSize)
                }
                if downloadedObjects.insert(object.id).inserted {
                    downloaded = progressAdding(downloaded, object.transferSize)
                }
                if next < needed.count { submit(needed[next]); next += 1 }
            }
        }
    }

    private struct BadObject: Error { let id: String; let cause: any Error }

    private func stageFile(_ file: FileTask) async throws {
        var objectFailures: [String: Int] = [:]
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
                try await fetchObjects(direct)
                try await assemble(file)
                let path = try layout.file(file.path)
                let size = try fs.size(at: path) ?? 0
                guard size == file.size else { throw LauncherError.sizeMismatch(path: file.path.description, expected: file.size, actual: size) }
                let actual = try hashRange(path, offset: 0, length: file.size, algorithm: file.digest.algorithm)
                guard actual == file.digest else {
                    throw LauncherError.digestMismatch(path: file.path.description, expected: file.digest.hex, actual: actual.hex)
                }
                try fs.fullSync(at: path)
                crashHooks.reach(.afterFileStagedBeforeJournal)
                try await record(.fileStaged(path: file.path))
                try cleanupObjects(ids: SpaceBudget.references(file))
                try allocation?.finish(file)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                let bad = error as? BadObject
                let failure = bad?.cause ?? error
                guard failure is CorruptObjectError || failure is LauncherError else {
                    throw LauncherError.io("Cannot stage file")
                }
                let corrupt: Bool
                if failure is CorruptObjectError { corrupt = true }
                else if let failure = failure as? LauncherError {
                    switch failure { case .digestMismatch, .sizeMismatch: corrupt = true; default: corrupt = false }
                } else { corrupt = false }
                if corrupt {
                    let canRetry: Bool
                    if let bad, let object = plan.objects[bad.id] {
                        try fs.removeFile(at: layout.object(object))
                        // Each object gets a bounded mirror cycle, including a
                        // resumed part whose original transfer mirror is unknown.
                        objectFailures[bad.id, default: 0] += 1
                        canRetry = objectFailures[bad.id, default: 0] < object.urls.count + 1
                        objectMirrors[bad.id] = ((objectMirrors[bad.id] ?? 0) + 1) % object.urls.count
                    } else {
                        wholeFileFailures += 1
                        canRetry = wholeFileFailures < wholeFileAttemptLimit
                    }
                    try fs.removeFile(at: layout.file(file.path))
                    try await record(.fileUnstaged(path: file.path))
                    if !canRetry { throw failure }
                } else { throw failure }
            }
        }
    }

    private func assemble(_ file: FileTask) async throws {
        let staged = try layout.file(file.path)
        let output = try fs.openForWriting(at: staged, truncate: true)
        defer { try? output.close() }
        for extent in file.extents {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            switch extent.source {
            case .chunk(let id): try decode(id, extent: extent, output: output, staged: staged)
            case .local(let path, let offset):
                if try copyLocal(path, offset: offset, extent: extent, output: output) { continue }
                guard let fallback = extent.fallbackChunkID else {
                    throw LauncherError.digestMismatch(path: path.description, expected: extent.digest.hex, actual: "local range mismatch")
                }
                guard let object = plan.objects[fallback] else { throw LauncherError.io("Missing plan object") }
                let part = try layout.object(object)
                let cached = try state.verifiedObjects.contains(fallback) && fs.size(at: part) == object.transferSize
                if !cached {
                    try admitMissingPart(fallback)
                    do {
                        try checkCapacity(written: min(file.size, try fs.size(at: staged) ?? 0))
                    } catch {
                        // A partial unverified download is not a resumable object.
                        try fs.removeFile(at: part)
                        throw error
                    }
                }
                try await fetchObjects([fallback])
                try decode(fallback, extent: extent, output: output, staged: staged)
            }
        }
    }

    private func admitMissingPart(_ id: String) throws {
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        let cached = try state.verifiedObjects.contains(id) && fs.size(at: layout.object(object)) == object.transferSize
        try allocation?.setCost(id, to: cached ? 0 : object.transferSize)
    }

    private func checkCapacity(written: Int64 = 0) throws {
        guard let required = try allocation?.disk(written: written) else {
            throw LauncherError.io("Missing session allocation")
        }
        let available = try fs.availableBytes(using: disk)
        guard available >= required else {
            throw LauncherError.insufficientSpace(required: required, available: available)
        }
    }

    private func decode(_ id: String, extent: Extent, output: FileHandle, staged: SafeRelativePath) throws {
        guard let object = plan.objects[id] else { throw LauncherError.io("Missing plan object") }
        let input = try fs.openForReading(at: layout.object(object))
        defer { try? input.close() }
        do {
            guard object.decodedSize == extent.length else {
                throw LauncherError.sizeMismatch(path: id, expected: extent.length, actual: object.decodedSize)
            }
            try object.codec.decoder(fileOps: fs.fileOps).decode(input, expectedSize: object.decodedSize, into: output, at: extent.fileOffset)
            let actual = try hashRange(staged, offset: extent.fileOffset, length: extent.length, algorithm: object.decodedDigest.algorithm)
            guard actual == object.decodedDigest else {
                throw LauncherError.digestMismatch(path: id, expected: object.decodedDigest.hex, actual: actual.hex)
            }
            let extentActual: Digest
            if extent.digest.algorithm == object.decodedDigest.algorithm { extentActual = actual }
            else { extentActual = try hashRange(staged, offset: extent.fileOffset, length: extent.length, algorithm: extent.digest.algorithm) }
            guard extentActual == extent.digest else {
                throw LauncherError.digestMismatch(path: id, expected: extent.digest.hex, actual: extentActual.hex)
            }
        } catch let error as CorruptObjectError {
            throw BadObject(id: id, cause: error)
        } catch let error as LauncherError {
            switch error {
            case .sizeMismatch, .digestMismatch: throw BadObject(id: id, cause: error)
            default: throw error
            }
        }
    }

    private func copyLocal(_ path: SafeRelativePath, offset: Int64, extent: Extent, output: FileHandle) throws -> Bool {
        guard offset >= 0, extent.length >= 0, extent.fileOffset >= 0,
            let size = try fs.size(at: path), offset <= size, extent.length <= size - offset else { return false }
        OperationWork.record(.localRangeHash)
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset)); try output.seek(toOffset: UInt64(extent.fileOffset))
        var hasher = StreamingHasher(extent.digest.algorithm)
        var remaining = extent.length
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let data = try autoreleasepool(invoking: { try input.read(upToCount: Int(min(65_536, remaining))) }), !data.isEmpty else { return false }
            hasher.update(data); try fs.fileOps.writeAll(data, to: output.fileDescriptor); remaining -= Int64(data.count)
        }
        return hasher.finalize() == extent.digest
    }

    private func hashRange(_ path: SafeRelativePath, offset: Int64, length: Int64, algorithm: DigestAlgorithm) throws -> Digest {
        let input = try fs.openForReading(at: path)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        var hasher = StreamingHasher(algorithm)
        var remaining = length
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let data = try autoreleasepool(invoking: { try input.read(upToCount: Int(min(65_536, remaining))) }), !data.isEmpty else {
                throw LauncherError.sizeMismatch(path: path.description, expected: length, actual: length - remaining)
            }
            hasher.update(data); remaining -= Int64(data.count)
        }
        return hasher.finalize()
    }

    private func cleanupObjects(ids: Set<String>) throws {
        for id in ids {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if let refs = referrers[id], refs.isSubset(of: donePaths), let object = plan.objects[id] {
                try fs.removeFile(at: layout.object(object))
            }
        }
    }
}
