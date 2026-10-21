// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore
import DownloadEngine

public enum RunOutcome: Sendable, Equatable { case completed, paused }

/// Persists exact plans before pending records. Streams are pull-driven: no
/// detached producer can keep installing after the consumer pauses or cancels.
public actor OperationRunner {
    private let store: GameRecordStore
    private let fetcher: ChunkFetcher
    private let disk: any DiskSpaceProbe
    private let log: EventLog?
    private let crashHooks: CrashHooks
    private let identityProvider: any FileSystemIdentityProvider
    private let fileOps: any FileOps

    public init(store: GameRecordStore, fetcher: ChunkFetcher, disk: any DiskSpaceProbe, log: EventLog?,
        crashHooks: CrashHooks = .none, fileOps: any FileOps = SystemFileOps(),
        identityProvider: any FileSystemIdentityProvider = SystemFileSystemIdentityProvider()) {
        self.store = store; self.fetcher = fetcher; self.disk = disk; self.log = log
        self.crashHooks = crashHooks; self.fileOps = fileOps; self.identityProvider = identityProvider
    }

    /// managedPaths is the complete target build's path set, including files
    /// unchanged by this plan. A delta plan cannot reconstruct that ownership.
    public func start(_ game: String, record: GameRecord, plan: InstallPlan, kind: PendingOperation.Kind,
        target: InstalledBuild, approved: Bool, managedPaths: Set<SafeRelativePath>) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, request: .start(.record(record), plan, kind, target, managedPaths, []), approved: approved)
    }

    public func resume(_ game: String, approved: Bool) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, request: .resume, approved: approved)
    }

    package func start(_ game: String, record: GameRecord, plan: InstallPlan, kind: PendingOperation.Kind,
        target: InstalledBuild, approved: Bool, lease: GameOperationLease,
        managedPaths: Set<SafeRelativePath>, reservedLocations: [URL] = []) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, request: .start(.record(record), plan, kind, target, managedPaths, reservedLocations), approved: approved, lease: lease)
    }
    package func resume(_ game: String, approved: Bool, lease: GameOperationLease) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, request: .resume, approved: approved, lease: lease)
    }

    /// Claims a fresh root under the store lease. A persisted GameRecord is never
    /// manufactured until the root exists and its identity has been measured.
    package func startInstall(_ game: String, at root: URL, executable: SafeRelativePath, plan: InstallPlan,
        target: InstalledBuild, approved: Bool, lease: GameOperationLease? = nil,
        managedPaths: Set<SafeRelativePath>, reservedLocations: [URL] = []) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, request: .start(.fresh(root, executable), plan, .install, target, managedPaths, reservedLocations), approved: approved, lease: lease)
    }

    public func reconcile(_ game: String) async throws -> GameRecord? {
        let lease = try await store.acquireOperationLease()
        defer { withExtendedLifetime(lease) {} }
        guard let record = try await store.load(game) else {
            try await store.cleanupOrphanGameDirectory(game)
            return nil
        }
        if record.uninstalling { return record }
        let fs = try ContainedFileSystem(root: record.installPath, expectedRootIdentity: record.installIdentity, identityProvider: identityProvider)
        try CompletionReceipt.discardInterruptedWrites(fs: fs)
        if let pending = record.pending {
            for receipt in try CompletionReceipt.unacknowledged(fs: fs) where receipt.planID != pending.planID {
                try receipt.finishCleanup(fs: fs)
                try CompletionReceipt.acknowledge(fs: fs, planID: receipt.planID)
            }
            if let receipt = try CompletionReceipt.load(fs: fs, planID: pending.planID) {
                try GameCompletion.requireMatch(receipt, pending)
                return try await GameCompletion.save(game, record: record, receipt: receipt, store: store, hooks: crashHooks, log: log, identityProvider: identityProvider)
            }
            // Paused before engine setup or with staging: resume owns validation
            // and execution of the stored plan; reconciliation never rebuilds it.
            return record
        }
        try await store.deletePlan(for: game)
        for receipt in try CompletionReceipt.unacknowledged(fs: fs) {
            try receipt.finishCleanup(fs: fs)
            try CompletionReceipt.acknowledge(fs: fs, planID: receipt.planID)
        }
        return record
    }

    private func stream(_ game: String, request: RunnerRequest, approved: Bool, lease: GameOperationLease? = nil) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = RunnerSession(game: game, request: request, approved: approved, store: store, fetcher: fetcher,
            disk: disk, log: log, hooks: crashHooks, fileOps: fileOps, lease: lease, identityProvider: identityProvider)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }
}

private enum RunnerRequest: Sendable {
    case start(RunnerRecordProposal, InstallPlan, PendingOperation.Kind, InstalledBuild, Set<SafeRelativePath>, [URL])
    case resume
}

private enum RunnerRecordProposal: Sendable {
    case record(GameRecord)
    case fresh(URL, SafeRelativePath)
    var record: GameRecord? { if case .record(let value) = self { value } else { nil } }
    var root: URL { switch self { case .record(let value): value.installPath; case .fresh(let root, _): root } }
    var executable: SafeRelativePath { switch self { case .record(let value): value.executable; case .fresh(_, let executable): executable } }
}

private actor RunnerSession {
    private let game: String
    private let request: RunnerRequest
    private let approved: Bool
    private let store: GameRecordStore
    private let fetcher: ChunkFetcher
    private let disk: any DiskSpaceProbe
    private let log: EventLog?
    private let hooks: CrashHooks
    private let identityProvider: any FileSystemIdentityProvider
    private let fileOps: any FileOps
    private var lease: GameOperationLease?
    private var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    private var record: GameRecord?
    private var prepared = false
    private var done = false
    private var pulling = false
    private var awaitingApprovalFailure = false

    init(game: String, request: RunnerRequest, approved: Bool, store: GameRecordStore, fetcher: ChunkFetcher,
        disk: any DiskSpaceProbe, log: EventLog?, hooks: CrashHooks, fileOps: any FileOps, lease: GameOperationLease?,
        identityProvider: any FileSystemIdentityProvider) {
        self.game = game; self.request = request; self.approved = approved; self.store = store
        self.fetcher = fetcher; self.disk = disk; self.log = log; self.hooks = hooks; self.fileOps = fileOps
        self.lease = lease; self.identityProvider = identityProvider
    }

    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("game stream already in use") }
        pulling = true
        defer { pulling = false }
        if done { return nil }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if !prepared {
                if lease == nil { lease = try await store.acquireOperationLease() }
                if try await prepare() {
                    finish()
                    return .phase(.completed) // An earlier durable receipt was reconciled.
                }
                prepared = true
            }
            guard var active = iterator else { throw LauncherError.journalCorrupt("Missing engine stream") }
            iterator = nil
            let event = try await active.next(isolation: self)
            iterator = active
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let event else {
                // An exhausted/cancelled iterator is paused unless completed was seen.
                finish(); return nil
            }
            awaitingApprovalFailure = if case .needsBatchApproval = event { true } else { false }
            if event == .phase(.completed) {
                guard let original = record, let pending = original.pending,
                    let receipt = try CompletionReceipt.load(fs: ContainedFileSystem(root: original.installPath,
                        expectedRootIdentity: original.installIdentity, identityProvider: identityProvider), planID: pending.planID),
                    receipt.planDigest == pending.planDigest else {
                    throw LauncherError.journalCorrupt("Missing or mismatched completion receipt")
                }
                guard let current = try await store.load(game), current == original else {
                    throw LauncherError.journalCorrupt("Game record changed during operation")
                }
                _ = try await GameCompletion.save(game, record: current, receipt: receipt, store: store, hooks: hooks, log: log, identityProvider: identityProvider)
                finish()
            }
            return event
        } catch {
            let approval = awaitingApprovalFailure
            finish()
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            if approval, case LauncherError.insufficientSpace = error { return nil }
            throw error
        }
    }

    /// Returns true only when a previous completed run was reconciled offline.
    private func prepare() async throws -> Bool {
        let plan: InstallPlan
        var current: GameRecord
        switch request {
        case .start(let proposal, let requested, let kind, let target, let managedPaths, let reserved):
            let proposed = proposal.record
            try requested.validate(supportedCodecs: ChunkCodec.supportedCodecs)
            let existing = try await store.load(game)
            if existing?.pending != nil || proposed?.pending != nil {
                throw LauncherError.busy("finish or uninstall the paused operation first")
            }
            guard existing?.uninstalling != true, proposed?.uninstalling != true else { throw LauncherError.busy("finish uninstall first") }
            guard existing == nil || existing == proposed else { throw LauncherError.busy("game record changed") }
            try requireGameLocationAvailable(proposal.root)
            let others = try await store.records().filter { $0.key != game }.map(\.value)
            try GameRecordRules.checkLocation(proposal.root, others: others, reserved: reserved)
            let fresh = kind == .install && proposed?.installed == nil
            if fresh { try GameRecordRules.checkInstallFolder(proposal.root) }
            let root = try ContainedFileSystem(root: proposal.root, fileOps: fileOps,
                expectedRootIdentity: proposed?.installIdentity, identityProvider: identityProvider)
            if proposed == nil { try root.createRootDurably() }
            let pinned = try root.pinRoot()
            let identity = try pinned.rootIdentity()
            // Durable order 1 -> 2. The engine is not constructed until both finish.
            try await store.savePlan(requested, for: game)
            hooks.reach(.afterGamePlanSaved)
            current = proposed ?? GameRecord(installPath: proposal.root, ownership: .created, executable: proposal.executable, installIdentity: identity)
            try await store.prepareManagedPaths(managedPaths, target: target, record: current, for: game)
            try GameRecordRules.checkLocation(proposal.root, others: others, reserved: reserved)
            if fresh, try !pinned.contentsOfRootDirectory().isEmpty {
                throw LauncherError.io("folder is not empty — use an existing installation instead")
            }
            guard try root.rootIdentity() == identity else { throw LauncherError.io("install folder was replaced") }
            current.pending = PendingOperation(kind: kind, planID: requested.id, planDigest: requested.planDigest, target: target)
            try await store.save(current, for: game)
            hooks.reach(.afterGamePendingSaved)
            plan = requested
        case .resume:
            guard let saved = try await store.load(game) else { throw LauncherError.io("no pending operation") }
            try GameRecordRules.check(.resume, record: saved, others: [])
            guard let pending = saved.pending else { throw LauncherError.io("no pending operation") }
            try requireGameLocationAvailable(saved.installPath)
            if let receipt = try CompletionReceipt.load(fs: ContainedFileSystem(root: saved.installPath, expectedRootIdentity: saved.installIdentity, identityProvider: identityProvider), planID: pending.planID) {
                try GameCompletion.requireMatch(receipt, pending)
                _ = try await GameCompletion.save(game, record: saved, receipt: receipt, store: store, hooks: hooks, log: log, identityProvider: identityProvider)
                return true
            }
            guard let stored = try await store.loadPlan(for: game), stored.id == pending.planID,
                stored.planDigest == pending.planDigest else { throw LauncherError.journalCorrupt("Missing or mismatched pending plan") }
            current = saved; plan = stored
            _ = try ContainedFileSystem(root: saved.installPath, fileOps: fileOps,
                expectedRootIdentity: saved.installIdentity, identityProvider: identityProvider).rootIdentity()
        }
        record = current
        let engine = try InstallOperation(plan: plan, installRoot: current.installPath, fetcher: fetcher, disk: disk,
            mode: .batched(approved: approved), fileOps: fileOps, crashHooks: hooks, writesCompletionReceipt: true,
            requireRequestedPlan: true, expectedRootIdentity: current.installIdentity, identityProvider: identityProvider)
        iterator = engine.run().makeAsyncIterator()
        return false
    }

    private func finish() { done = true; iterator = nil; lease = nil }
}

private enum GameCompletion {
    static func requireMatch(_ receipt: CompletionReceipt, _ pending: PendingOperation) throws {
        guard receipt.planID == pending.planID, receipt.planDigest == pending.planDigest else {
            throw LauncherError.journalCorrupt("Missing or mismatched completion receipt")
        }
    }

    static func save(_ game: String, record: GameRecord, receipt: CompletionReceipt, store: GameRecordStore,
        hooks: CrashHooks, log: EventLog?, identityProvider: any FileSystemIdentityProvider) async throws -> GameRecord {
        guard let pending = record.pending else { throw LauncherError.journalCorrupt("Missing pending operation") }
        try requireMatch(receipt, pending)
        let fs = try ContainedFileSystem(root: record.installPath, expectedRootIdentity: record.installIdentity, identityProvider: identityProvider)
        if pending.kind == .adopt {
            guard try fs.itemType(at: record.executable) == .regularFile else {
                throw LauncherError.io("game executable missing")
            }
        }
        var completed = record; completed.installed = pending.target; completed.pending = nil
        // Require authoritative ownership metadata before advancing the record.
        _ = try await store.managedPaths(for: game, record: completed)
        try receipt.finishCleanup(fs: fs)
        try await store.save(completed, for: game)
        try await store.completeManagedPaths(record: completed, for: game)
        await log?.log(.info, "game-operation", "Operation completed", metadata: [
            "game": game, "tag": pending.target.tag, "build_id": pending.target.buildID,
        ])
        hooks.reach(.afterGameRecordSaved)
        try await store.deletePlan(for: game)
        hooks.reach(.afterGamePlanDeleted)
        try CompletionReceipt.acknowledge(fs: fs, planID: receipt.planID)
        hooks.reach(.afterReceiptAcknowledged)
        return completed
    }
}

package func requireGameLocationAvailable(_ root: URL) throws {
    let components = root.pathComponents
    let folded = components.map { $0.lowercased() }
    let name: String?
    if folded.count >= 3, folded[1] == "volumes" { name = components[2] }
    else if folded.count >= 6, folded[1...4].elementsEqual(["system", "volumes", "data", "volumes"]) { name = components[5] }
    else { name = nil }
    if let name {
        let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(name)
        var info = stat()
        guard stat(volume.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw LauncherError.io("install location unavailable")
        }
    }
}
