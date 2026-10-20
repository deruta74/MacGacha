// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct InstallOperation: Sendable {
    public enum Mode: Sendable, Equatable {
        case automatic
        case batched(approved: Bool)
    }

    private let plan: InstallPlan
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let disk: any DiskSpaceProbe
    private let mode: Mode

    public init(plan: InstallPlan, installRoot: URL, fetcher: ChunkFetcher,
        disk: any DiskSpaceProbe = SystemDiskSpaceProbe(), mode: Mode = .automatic) throws {
        try plan.validate()
        self.plan = plan; fs = try ContainedFileSystem(root: installRoot)
        self.fetcher = fetcher; self.disk = disk; self.mode = mode
    }

    /// Pull-driven events: cancellation follows the consumer task, and discarding the
    /// stream releases the root lock without leaving a producer running in the background.
    public func run() -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = CommitSession(requested: plan, fs: fs, fetcher: fetcher, disk: disk, mode: mode)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }
}

private struct CommitPaths: Sendable {
    let id: SafeIdentifier
    var directory: SafeRelativePath { get throws { try SafeRelativePath(".macgacha-staging/\(id)") } }
    var plan: SafeRelativePath { get throws { try SafeRelativePath(".macgacha-staging/\(id)/plan.json") } }
    var journal: SafeRelativePath { get throws { try SafeRelativePath(".macgacha-staging/\(id)/journal.jsonl") } }
    func staged(_ path: SafeRelativePath) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(id)/files/\(path)") }
    func object(_ object: ChunkObject) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(id)/objects/\(object.partFileName)") }
}

private actor CommitSession {
    private enum Step { case start, space, staging, commit, delete, cleanup, done }
    private struct Stored: Sendable {
        let plan: InstallPlan
        let journal: OperationJournal
        let state: JournalState
    }
    private let requested: InstallPlan
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let disk: any DiskSpaceProbe
    private let mode: InstallOperation.Mode
    private var lock: InstallLock?
    private var active: Stored?
    private var state = JournalState()
    private var batch: [FileTask] = []
    private var batchIndex = 0
    private var staging: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var step = Step.start
    private var pendingError: LauncherError?
    private var pulling = false
    private static let planLimit = 64 << 20

    init(requested: InstallPlan, fs: ContainedFileSystem, fetcher: ChunkFetcher,
        disk: any DiskSpaceProbe, mode: InstallOperation.Mode) {
        self.requested = requested; self.fs = fs; self.fetcher = fetcher; self.disk = disk; self.mode = mode
    }

    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("install stream already in use") }
        pulling = true
        defer { pulling = false }
        if step == .done { return nil }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if let pendingError { throw pendingError }
            switch step {
            case .start:
                // Dot-prefixed control files cannot collide with a SafeIdentifier plan ID.
                lock = try InstallLock(fs: fs, path: SafeRelativePath(".macgacha-staging/.lock"))
                try await selectStoredOrRequested()
                return try activate()
            case .space: return try await chooseBatch()
            case .staging:
                guard var iterator = staging else { throw LauncherError.journalCorrupt("Missing staging stream") }
                staging = nil
                let event = try await iterator.next(isolation: self)
                staging = iterator
                if let event { return event }
                staging = nil
                try refresh()
                try await beginCommit()
                return .phase(.committing)
            case .commit:
                try await commitBatch()
                step = .space
                return .phase(.checkingSpace)
            case .delete:
                try await deleteFiles()
                try await record(.operationCompleted)
                step = .cleanup
                return .phase(.cleaningUp)
            case .cleanup:
                let finished = try context().plan
                try cleanup(finished)
                if finished.planDigest != requested.planDigest {
                    try await createRequested()
                    return try activate()
                }
                step = .done; lock = nil
                return .phase(.completed)
            case .done: return nil
            }
        } catch {
            step = .done; staging = nil; lock = nil
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func context() throws -> Stored {
        guard let active else { throw LauncherError.journalCorrupt("Missing active install plan") }
        return active
    }

    private func refresh() throws {
        let context = try context()
        state = try OperationJournal.replay(fs: fs, path: CommitPaths(id: context.plan.id).journal)
    }

    private func record(_ record: JournalRecord) async throws {
        let context = try context()
        try await context.journal.append(record)
        state.apply(record)
    }

    private func selectStoredOrRequested() async throws {
        let root = try SafeRelativePath(".macgacha-staging")
        let marker = try InstallStateMarker.load(fs: fs)
        var stored: [Stored] = []
        var loadedBytes = 0
        for path in try fs.contentsOfDirectory(at: root).sorted(by: { $0.description < $1.description }) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard try fs.itemType(at: path) == .directory else { continue }
            let id = try SafeIdentifier(path.components.last ?? "")
            let paths = CommitPaths(id: id)
            guard try fs.itemType(at: paths.plan) != nil else { continue }
            guard stored.count < 64 else { throw LauncherError.journalCorrupt("Too many stored plans") }
            let bytes = try fs.readFile(at: paths.plan, maxBytes: Self.planLimit)
            guard bytes.count <= Self.planLimit - loadedBytes else {
                throw LauncherError.fileTooLarge(path: ".macgacha-staging", limit: Self.planLimit)
            }
            loadedBytes += bytes.count
            let plan: InstallPlan
            do { plan = try JSONDecoder().decode(InstallPlan.self, from: bytes) }
            catch { throw LauncherError.journalCorrupt("Invalid stored install plan") }
            guard plan.id == id else { throw LauncherError.journalCorrupt("Stored plan directory mismatch") }
            let journal = try OperationJournal(fs: fs, path: paths.journal)
            let replay = try OperationJournal.replay(fs: fs, path: paths.journal)
            guard (replay.planID == nil || replay.planID == plan.id),
                  (replay.planDigest == nil || replay.planDigest == plan.planDigest) else {
                throw LauncherError.journalCorrupt("Stored plan digest mismatch")
            }
            stored.append(Stored(plan: plan, journal: journal, state: replay))
        }
        if let marker, !stored.contains(where: { $0.plan.id == marker.planID }) {
            throw LauncherError.journalCorrupt("Install marker has no stored plan")
        }
        let committing = stored.filter { !$0.state.completed && !$0.state.commitStartedBatches.isEmpty }
        guard committing.count <= 1 else { throw LauncherError.journalCorrupt("Multiple unfinished committed plans") }
        let selected = committing.first ?? stored.first(where: { $0.plan.planDigest == requested.planDigest })
        if let selected, let marker, !selected.state.commitStartedBatches.isEmpty,
           !selected.state.completed, marker.planID != selected.plan.id {
            throw LauncherError.journalCorrupt("Install marker belongs to another plan")
        }
        for other in stored where other.plan.id != selected?.plan.id {
            // Any unfinished committed plan was selected above. Only disposable pre-commit
            // staging or completed cleanup remains, and all paths stay inside CFS.
            try cleanup(other.plan)
        }
        if let selected {
            active = selected; state = selected.state
            try validateDeletions(selected.plan)
            if state.planID == nil {
                try await record(.planStored(planID: selected.plan.id, planDigest: selected.plan.planDigest))
                try await record(.operationStarted)
            }
        } else { try await createRequested() }
    }

    private func createRequested() async throws {
        try validateDeletions(requested)
        let paths = CommitPaths(id: requested.id)
        if let type = try fs.itemType(at: paths.directory) {
            guard type == .directory else { throw LauncherError.unsafePath(try paths.directory.description) }
            // A directory without plan.json can remain after interrupted completed cleanup.
            // Its old journal must never be reused for a new plan with the same identifier.
            try fs.removeItem(at: paths.directory)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(requested)
        guard bytes.count <= Self.planLimit else { throw LauncherError.fileTooLarge(path: try paths.plan.description, limit: Self.planLimit) }
        try fs.writeAtomically(bytes, to: paths.plan)
        let journal = try OperationJournal(fs: fs, path: paths.journal)
        active = Stored(plan: requested, journal: journal, state: JournalState()); state = JournalState()
        try await record(.planStored(planID: requested.id, planDigest: requested.planDigest))
        try await record(.operationStarted)
    }

    private func activate() throws -> OperationEvent {
        if state.completed { step = .cleanup; return .phase(.cleaningUp) }
        let plan = try context().plan
        if let current = state.currentBatch, state.commitStartedBatches.contains(current) {
            let paths = Set(plan.files.map(\.path))
            guard state.batchFiles.isSubset(of: paths) else { throw LauncherError.journalCorrupt("Batch references an unknown file") }
            batch = plan.files.filter { state.batchFiles.contains($0.path) }
            batchIndex = current
            try ensureMarker(plan.id)
            step = .commit
            return .phase(.committing)
        }
        step = .space
        return .phase(.checkingSpace)
    }

    private func pendingPlan() throws -> InstallPlan {
        let plan = try context().plan
        let files = plan.files.filter { !state.committedFiles.contains($0.path) }
        return projection(plan, files: files)
    }

    private func projection(_ plan: InstallPlan, files: [FileTask]) -> InstallPlan {
        let ids = Set(files.flatMap { references($0) })
        return InstallPlan(id: plan.id, objects: plan.objects.filter { ids.contains($0.key) }, files: files)
    }

    private func chooseBatch() async throws -> OperationEvent {
        let plan = try context().plan
        let pending = try pendingPlan()
        if pending.files.isEmpty {
            if state.commitStartedBatches.isEmpty, plan.deletions.contains(where: { !state.deletedFiles.contains($0) }) {
                batch = []; batchIndex = 0
                try await beginCommit()
                return .phase(.committing)
            }
            step = .delete; return .phase(.deleting)
        }
        let available = try fs.availableBytes(using: disk)
        let required = try SpaceBudget.required(plan: pending, state: state, fs: fs).disk
        if required <= available { batch = pending.files }
        else {
            let largest = try SpaceBudget.requiredLargestFile(plan: pending, state: state, fs: fs)
            guard largest <= available else { throw LauncherError.insufficientSpace(required: required, available: available) }
            let candidate = try partitionPrefix(pending, available: available)
            try preserveLocalSources(batch: candidate, pending: pending, required: required, available: available)
            // A durable commit is an already-started operation: recovery must roll forward,
            // including any remaining batches of the previously approved stored plan.
            if state.commitStartedBatches.isEmpty, mode != .batched(approved: true) {
                pendingError = .insufficientSpace(required: required, available: available)
                return .needsBatchApproval(required: required, available: available)
            }
            batch = candidate
        }
        if let started = state.currentBatch, !state.commitStartedBatches.contains(started) {
            batchIndex = started
        } else {
            let previous = max(state.currentBatch ?? -1, state.commitStartedBatches.max() ?? -1)
            let (next, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw LauncherError.journalCorrupt("Batch index overflow") }
            batchIndex = next
        }
        let stager = try Stager(plan: pending, fs: fs, fetcher: fetcher, journal: context().journal, disk: disk)
        staging = stager.stage(files: batch).makeAsyncIterator()
        step = .staging
        return .phase(.staging)
    }

    private func partitionPrefix(_ pending: InstallPlan, available: Int64) throws -> [FileTask] {
        let paths = CommitPaths(id: pending.id)
        var selected: [FileTask] = [], counted = Set<String>()
        var cost = SpaceBudget.margin
        var transferCosts: [String: Int64] = [:]
        for object in pending.objects.values {
            let verified = try state.verifiedObjects.contains(object.id) && fs.size(at: paths.object(object)) == object.transferSize
            transferCosts[object.id] = verified ? 0 : object.transferSize
        }
        for file in pending.files {
            let present = try state.stagedFiles.contains(file.path) && fs.size(at: paths.staged(file.path)) == file.size
            var added: Int64 = present ? 0 : file.size
            let ids = references(file)
            for id in ids.subtracting(counted) { added = try sum(added, transferCosts[id] ?? 0) }
            let next = try sum(cost, added)
            if next > available { break }
            selected.append(file); counted.formUnion(ids); cost = next
        }
        guard !selected.isEmpty else { throw LauncherError.insufficientSpace(required: try SpaceBudget.requiredLargestFile(plan: pending, state: state, fs: fs), available: available) }
        return selected
    }

    private func preserveLocalSources(batch: [FileTask], pending: InstallPlan, required: Int64, available: Int64) throws {
        let selected = Set(batch.map(\.path))
        let overwritten = Set(batch.map { folded($0.path) })
        let paths = CommitPaths(id: pending.id)
        for later in pending.files where !selected.contains(later.path) {
            if state.stagedFiles.contains(later.path), try fs.size(at: paths.staged(later.path)) == later.size { continue }
            for extent in later.extents where extent.fallbackChunkID == nil {
                if case .local(let source, _) = extent.source, overwritten.contains(folded(source)) {
                    // Committing would destroy the only recoverable copy of this local range.
                    throw LauncherError.insufficientSpace(required: required, available: available)
                }
            }
        }
    }

    private func folded(_ path: SafeRelativePath) -> String {
        path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func beginCommit() async throws {
        try await record(.batchStarted(index: batchIndex))
        try ensureMarker(context().plan.id)
        try await record(.commitStarted(batch: batchIndex))
        step = .commit
    }

    private func ensureMarker(_ id: SafeIdentifier) throws {
        if let marker = try InstallStateMarker.load(fs: fs), marker.planID != id {
            throw LauncherError.journalCorrupt("Install marker belongs to another plan")
        }
        try InstallStateMarker(planID: id).write(fs: fs)
    }

    private func commitBatch() async throws {
        let plan = try context().plan
        let paths = CommitPaths(id: plan.id)
        for file in batch {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if state.committedFiles.contains(file.path) { continue }
            let staged = try paths.staged(file.path)
            let stagedSize = try fs.size(at: staged)
            if state.stagedFiles.contains(file.path), stagedSize == file.size {
                try fs.rename(from: staged, to: file.path)
            } else if stagedSize == nil, try destinationMatches(file) {
                // Rename persisted, but its journal append did not.
                try fs.fullSync(at: file.path)
            } else {
                try await record(.fileUnstaged(path: file.path))
                let stager = try Stager(plan: pendingPlan(), fs: fs, fetcher: fetcher, journal: context().journal, disk: disk)
                for try await _ in stager.stage(files: [file]) {}
                try refresh()
                guard state.stagedFiles.contains(file.path), try fs.size(at: staged) == file.size else {
                    throw LauncherError.journalCorrupt("Restaged file is missing")
                }
                try fs.rename(from: staged, to: file.path)
            }
            try await record(.fileCommitted(path: file.path))
        }
    }

    private func destinationMatches(_ file: FileTask) throws -> Bool {
        guard try fs.size(at: file.path) == file.size else { return false }
        let input = try fs.openForReading(at: file.path)
        defer { try? input.close() }
        var remaining = file.size
        var hasher = StreamingHasher(file.digest.algorithm)
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let data = try autoreleasepool(invoking: { try input.read(upToCount: Int(min(65_536, remaining))) }), !data.isEmpty else { return false }
            hasher.update(data); remaining -= Int64(data.count)
        }
        return hasher.finalize() == file.digest
    }

    private func validateDeletions(_ plan: InstallPlan) throws {
        for path in plan.deletions {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if let type = try fs.itemType(at: path), type != .regularFile { throw LauncherError.unsafePath(path.description) }
        }
    }

    private func deleteFiles() async throws {
        for path in try context().plan.deletions where !state.deletedFiles.contains(path) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            try fs.removeFile(at: path)
            try await record(.fileDeleted(path: path))
        }
    }

    private func cleanup(_ plan: InstallPlan) throws {
        let marker = try InstallStateMarker.load(fs: fs)
        if marker == nil || marker?.planID == plan.id {
            try InstallStateMarker.clear(fs: fs, matching: plan.id)
        }
        try fs.removeItem(at: CommitPaths(id: plan.id).directory)
    }

    private func references(_ file: FileTask) -> Set<String> {
        var ids = Set<String>()
        for extent in file.extents {
            if case .chunk(let id) = extent.source { ids.insert(id) }
            if let id = extent.fallbackChunkID { ids.insert(id) }
        }
        return ids
    }

    private func sum(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw LauncherError.io("Space budget overflow") }
        return value
    }
}
