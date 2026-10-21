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
    private let crashHooks: CrashHooks
    private let writesCompletionReceipt: Bool
    private let requireRequestedPlan: Bool

    public init(plan: InstallPlan, installRoot: URL, fetcher: ChunkFetcher,
        disk: any DiskSpaceProbe = SystemDiskSpaceProbe(), mode: Mode = .automatic,
        fileOps: any FileOps = SystemFileOps(), crashHooks: CrashHooks = .none,
        writesCompletionReceipt: Bool = false, requireRequestedPlan: Bool = false,
        expectedRootIdentity: FileSystemIdentity? = nil, identityProvider: any FileSystemIdentityProvider = SystemFileSystemIdentityProvider()) throws {
        try plan.validate(supportedCodecs: ChunkCodec.supportedCodecs)
        self.plan = plan; fs = try ContainedFileSystem(root: installRoot, fileOps: fileOps, expectedRootIdentity: expectedRootIdentity, identityProvider: identityProvider)
        self.fetcher = fetcher; self.disk = disk; self.mode = mode; self.crashHooks = crashHooks
        self.writesCompletionReceipt = writesCompletionReceipt
        self.requireRequestedPlan = requireRequestedPlan
    }

    /// Pull-driven events: cancellation follows the consumer task, and discarding the
    /// stream releases the root lock without leaving a producer running in the background.
    public func run() -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = CommitSession(requested: plan, fs: fs, fetcher: fetcher, disk: disk, mode: mode, crashHooks: crashHooks,
            writesCompletionReceipt: writesCompletionReceipt, requireRequestedPlan: requireRequestedPlan)
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
    private struct Discovered {
        let plan: InstallPlan
        let state: JournalState
    }
    private let requested: InstallPlan
    private let fs: ContainedFileSystem
    private let fetcher: ChunkFetcher
    private let disk: any DiskSpaceProbe
    private let mode: InstallOperation.Mode
    private let crashHooks: CrashHooks
    private let writesCompletionReceipt: Bool
    private let requireRequestedPlan: Bool
    private var lock: InstallLock?
    private var active: Stored?
    private var state = JournalState()
    private var batch: [FileTask] = []
    private var plannedBatches: [[FileTask]] = []
    private var batchIndex = 0
    private var staging: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var step = Step.start
    private var pendingError: LauncherError?
    private var pulling = false
    private static let planLimit = InstallPlan.maximumEncodedBytes

    init(requested: InstallPlan, fs: ContainedFileSystem, fetcher: ChunkFetcher,
        disk: any DiskSpaceProbe, mode: InstallOperation.Mode, crashHooks: CrashHooks, writesCompletionReceipt: Bool,
        requireRequestedPlan: Bool) {
        self.requested = requested; self.fs = fs; self.fetcher = fetcher; self.disk = disk; self.mode = mode; self.crashHooks = crashHooks
        self.writesCompletionReceipt = writesCompletionReceipt
        self.requireRequestedPlan = requireRequestedPlan
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
                try await refresh()
                try await beginCommit()
                return .phase(.committing)
            case .commit:
                try await commitBatch()
                step = .space
                return .phase(.checkingSpace)
            case .delete:
                try await deleteFiles()
                crashHooks.reach(.beforeCompleted)
                try await record(.operationCompleted)
                crashHooks.reach(.afterOperationCompleted)
                step = .cleanup
                return .phase(.cleaningUp)
            case .cleanup:
                let finished = try context().plan
                if writesCompletionReceipt, finished.id == requested.id, finished.planDigest == requested.planDigest {
                    try CompletionReceipt(planID: finished.id, planDigest: finished.planDigest).write(fs: fs)
                    crashHooks.reach(.afterCompletionReceipt)
                }
                try cleanup(finished)
                crashHooks.reach(.afterEngineCleanup)
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

    private func refresh() async throws {
        let context = try context()
        state = try await context.journal.snapshot()
    }

    private func record(_ record: JournalRecord) async throws {
        let context = try context()
        try await context.journal.append(record)
        try state.apply(record)
    }

    private func selectStoredOrRequested() async throws {
        let root = try SafeRelativePath(".macgacha-staging")
        let marker = try InstallStateMarker.load(fs: fs)
        var stored: [Discovered] = []
        var orphans: [SafeRelativePath] = []
        var loadedBytes = 0
        for path in try fs.contentsOfDirectory(at: root).sorted(by: { $0.description < $1.description }) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard try fs.itemType(at: path) == .directory else { continue }
            let planPath = try SafeRelativePath("\(path)/plan.json")
            guard try fs.itemType(at: planPath) != nil else {
                // Interrupted completed cleanup may leave arbitrarily large retained data.
                // Reclaim it under the root lock before estimating the requested plan's space.
                guard marker?.planID.description != path.components.last else {
                    throw LauncherError.journalCorrupt("Install marker has no stored plan")
                }
                orphans.append(path)
                continue
            }
            let id = try SafeIdentifier(path.components.last ?? "")
            let paths = CommitPaths(id: id)
            guard stored.count < 64 else { throw LauncherError.journalCorrupt("Too many stored plans") }
            let bytes = try fs.readFile(at: paths.plan, maxBytes: Self.planLimit)
            guard bytes.count <= Self.planLimit - loadedBytes else {
                throw LauncherError.fileTooLarge(path: ".macgacha-staging", limit: Self.planLimit)
            }
            loadedBytes += bytes.count
            let plan: InstallPlan
            do { plan = try JSONDecoder().decode(InstallPlan.self, from: bytes) }
            catch { throw LauncherError.journalCorrupt("Invalid stored install plan") }
            // Structural corruption belongs to recovery; missing decoders keep their
            // actionable codec error, before any stored plan can fetch or commit.
            guard plan.id == id else { throw LauncherError.journalCorrupt("Stored plan directory mismatch") }
            try plan.validate()
            // Read-only discovery: constructing a journal can repair its tail.
            // No recovery writes are allowed until every plan passes identity checks.
            let replay = try OperationJournal.replay(fs: fs, path: paths.journal)
            guard (replay.planID == nil || replay.planID == plan.id),
                  (replay.planDigest == nil || replay.planDigest == plan.planDigest) else {
                throw LauncherError.journalCorrupt("Stored plan digest mismatch")
            }
            stored.append(Discovered(plan: plan, state: replay))
        }
        if requireRequestedPlan, stored.contains(where: {
            !$0.state.completed && ($0.plan.id != requested.id || $0.plan.planDigest != requested.planDigest)
        }) { throw LauncherError.journalCorrupt("staging holds another plan") }
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
        for orphan in orphans { try fs.removeItem(at: orphan) }
        for other in stored where other.plan.id != selected?.plan.id {
            // Any unfinished committed plan was selected above. Only disposable pre-commit
            // staging or completed cleanup remains, and all paths stay inside CFS.
            try cleanup(other.plan)
        }
        if let selected {
            let journal = try OperationJournal(fs: fs, path: CommitPaths(id: selected.plan.id).journal, crashHooks: crashHooks)
            active = Stored(plan: selected.plan, journal: journal, state: journal.recoveredState)
            state = journal.recoveredState
            try validateDeletions(selected.plan)
            if state.planID == nil {
                // plan.json is persisted first; a crash or repaired first line can leave
                // its journal empty. Restore plan identity before any later records.
                try await record(.planStored(planID: selected.plan.id, planDigest: selected.plan.planDigest))
                try await record(.operationStarted)
            }
        } else { try await createRequested() }
    }

    private func createRequested() async throws {
        try validateDeletions(requested)
        plannedBatches = []
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
        let journal = try OperationJournal(fs: fs, path: paths.journal, crashHooks: crashHooks)
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
        try await invalidateStaleStagedFiles(plan)
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
        if plannedBatches.isEmpty {
            let required = try SpaceBudget.required(plan: pending, state: state, fs: fs).disk
            if required <= available { plannedBatches = [pending.files] }
            else {
                let largest = try SpaceBudget.requiredLargestFile(plan: pending, state: state, fs: fs)
                guard largest <= available else { throw LauncherError.insufficientSpace(required: required, available: available) }
                // Validate every boundary before the first commit, and retain those boundaries
                // for this run. A later batch must not be split differently after an earlier commit.
                plannedBatches = try partitionAll(pending, required: required, available: available)
                // A durable commit is an already-started operation: recovery must roll forward,
                // including any remaining batches of the previously approved stored plan.
                if state.commitStartedBatches.isEmpty, mode != .batched(approved: true) {
                    pendingError = .insufficientSpace(required: required, available: available)
                    return .needsBatchApproval(required: required, available: available)
                }
            }
        }
        let next = plannedBatches[0]
        let need = try SpaceBudget.required(plan: projection(pending, files: next), state: state, fs: fs).disk
        let free = try fs.availableBytes(using: disk)
        guard need <= free else { throw LauncherError.insufficientSpace(required: need, available: free) }
        batch = plannedBatches.removeFirst()
        if let started = state.currentBatch, !state.commitStartedBatches.contains(started) {
            batchIndex = started
        } else {
            let previous = max(state.currentBatch ?? -1, state.commitStartedBatches.max() ?? -1)
            let (next, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw LauncherError.journalCorrupt("Batch index overflow") }
            batchIndex = next
        }
        let stager = try Stager(plan: pending, fs: fs, fetcher: fetcher, journal: context().journal, disk: disk, crashHooks: crashHooks)
        staging = stager.stage(files: batch).makeAsyncIterator()
        step = .staging
        return .phase(.staging)
    }

    private func invalidateStaleStagedFiles(_ plan: InstallPlan) async throws {
        let paths = CommitPaths(id: plan.id)
        for file in plan.files where state.stagedFiles.contains(file.path) && !state.committedFiles.contains(file.path) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if try fs.size(at: paths.staged(file.path)) != file.size {
                try await record(.fileUnstaged(path: file.path))
            }
        }
    }

    private func partitionAll(_ pending: InstallPlan, required _: Int64, available: Int64) throws -> [[FileTask]] {
        let minimum = try SpaceBudget.minimumBatchedPreflight(plan: pending, state: state, fs: fs)
        guard minimum <= available else { throw LauncherError.insufficientSpace(required: minimum, available: available) }
        do {
            let result = try SpaceBudget.batchedPreflight(plan: pending, state: state, fs: fs, available: available)
            if result.required <= available { return result.batches }
        } catch LauncherError.insufficientSpace {
            // Greedy boundaries can also invalidate a local-source dependency.
            // Other errors, including cancellation and I/O failures, propagate.
        }
        // More free space can change greedy boundaries and increase the shared
        // reserve or break dependencies. Retain the validated minimum partition.
        let fallback = try SpaceBudget.batchedPreflight(plan: pending, state: state, fs: fs, available: minimum)
        guard fallback.required <= available else { throw LauncherError.insufficientSpace(required: fallback.required, available: available) }
        return fallback.batches
    }

    private func beginCommit() async throws {
        guard Set(batch.map(\.path)) == state.stagedFiles.subtracting(state.committedFiles) else {
            throw LauncherError.journalCorrupt("Staged batch membership mismatch")
        }
        try await record(.batchStarted(index: batchIndex))
        try ensureMarker(context().plan.id)
        try await record(.commitStarted(batch: batchIndex))
        crashHooks.reach(.afterCommitStartedBeforeFirstRename)
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
                crashHooks.reach(.afterRenameBeforeJournal)
            } else if stagedSize == nil, try destinationMatches(file) {
                // Rename persisted, but its journal append did not.
                try fs.fullSync(at: file.path)
            } else {
                try await record(.fileUnstaged(path: file.path))
                let stager = try Stager(plan: pendingPlan(), fs: fs, fetcher: fetcher, journal: context().journal, disk: disk, crashHooks: crashHooks)
                for try await _ in stager.stage(files: [file]) {}
                try await refresh()
                guard state.stagedFiles.contains(file.path), try fs.size(at: staged) == file.size else {
                    throw LauncherError.journalCorrupt("Restaged file is missing")
                }
                try fs.rename(from: staged, to: file.path)
                crashHooks.reach(.afterRenameBeforeJournal)
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
        try cleanupInstallStaging(planID: plan.id, fs: fs)
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
