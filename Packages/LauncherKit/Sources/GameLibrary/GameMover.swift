// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public enum GameMoveCheckpoint: String, CaseIterable, Sendable {
    case planned, copying, verified, published, switched, cleaned
}

/// Owns both ordinary operation and game-session exclusion until cleanup joins.
/// The durable record decides authority even when an atomic write reports failure.
public struct GameMover: Sendable {
    private let paths: AppPaths
    private let store: GameRecordStore
    private let disk: any DiskSpaceProbe
    private let fileOps: any FileOps
    private let locationProbe: any GameLocationProbing
    private let operationGuard: (any GameOperationGuard)?
    private let log: EventLog?
    private let sameVolume: @Sendable (FileSystemIdentity, FileSystemIdentity) -> Bool
    private let checkpoint: @Sendable (GameMoveCheckpoint) async throws -> Void
    private static let journalName = "move-journal.json"

    public init(paths: AppPaths, store: GameRecordStore, disk: any DiskSpaceProbe = SystemDiskSpaceProbe(),
        fileOps: any FileOps = SystemFileOps(), locationProbe: any GameLocationProbing = SystemGameLocationProbe(),
        guard operationGuard: (any GameOperationGuard)? = nil, log: EventLog? = nil,
        sameVolume: @escaping @Sendable (FileSystemIdentity, FileSystemIdentity) -> Bool = { $0.volume == $1.volume },
        checkpoint: @escaping @Sendable (GameMoveCheckpoint) async throws -> Void = { _ in }) {
        self.paths = paths; self.store = store; self.disk = disk; self.fileOps = fileOps
        self.locationProbe = locationProbe; self.operationGuard = operationGuard; self.log = log
        self.sameVolume = sameVolume; self.checkpoint = checkpoint
    }

    public func move(_ game: GameDefinition, to folder: URL,
        progress: @escaping @Sendable (OperationEvent) -> Void = { _ in }) async throws {
        try await operationGuard?.willOperate(on: game.id)
        try await BlockingIO.run {
            let lock = try gameLock(game.id)
            let lease = try await store.acquireOperationLease(retainedGameLock: lock)
            defer { withExtendedLifetime(lease) {} }
            guard try await store.readState(Self.journalName, for: game.id, maxBytes: 65536) == nil else {
                throw LauncherError.busy("Move recovery is required")
            }
            let record = try await requireMovable(game.id)
            let destination = folder.appendingPathComponent(game.defaultInstallDirectoryName, isDirectory: true)
            let records = try await store.records()
            try GameRecordRules.checkLocation(destination, others: Array(records.values), reserved: [paths.root, paths.runtimes])
            try requireVolumes(record.installPath, destination)
            let source = try sourceFS(record)
            let parent = try ContainedFileSystem(root: folder, fileOps: fileOps).pinRoot()
            let final = try SafeRelativePath(game.defaultInstallDirectoryName)
            let staging = try SafeRelativePath(".macgacha-moving-\(SafeIdentifier(game.id).rawValue)")
            guard try parent.itemType(at: final, allowingLeafSymlink: true) == nil,
                try parent.itemType(at: staging, allowingLeafSymlink: true) == nil else {
                throw LauncherError.io("Move destination exists")
            }
            try requireNoRecovery(game.id, record: record, source: source)
            let entries = try source.inspectTree(allowingExternalHardLinks: true)
            try validateLinks(entries)
            let cache = try PreDownloadStore(fs: source).load()
            let sourceParent = try ContainedFileSystem(root: record.installPath.deletingLastPathComponent(), fileOps: fileOps).pinRoot()
            var journal = MoveJournal(original: record, destination: destination, parentIdentity: try parent.rootIdentity(),
                sourceParentIdentity: try sourceParent.rootIdentity(), sameVolume: sameVolume(record.installIdentity, try parent.rootIdentity()))
            if !journal.sameVolume {
                var bytes: Int64 = 0
                for entry in entries where entry.type == .regularFile {
                    guard let size = try source.size(at: entry.path), size >= 0, size <= Int64.max - bytes else {
                        throw LauncherError.io("Move size exceeds limit")
                    }
                    bytes += size
                }
                let margin = max(Int64(64 << 20), bytes / 20)
                guard bytes <= Int64.max - margin else { throw LauncherError.io("Move size exceeds limit") }
                let required = bytes + margin, available = try parent.availableBytes(using: disk)
                guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
            }
            try await save(journal, game: game.id)
            log?.post(.info, "game", "Move started", metadata: ["game": game.id])
            do {
                try await checkpoint(.planned)
                try check(record.installPath, destination)
                journal.phase = .copying
                try await save(journal, game: game.id)
                if journal.sameVolume {
                    try await checkpoint(.copying)
                    journal.destinationIdentity = record.installIdentity
                    journal.phase = .verified
                    try await save(journal, game: game.id)
                    progress(.phase(.verifying))
                    try await checkpoint(.verified)
                    try check(record.installPath, destination)
                    progress(.phase(.committing))
                    try sourceParent.moveDirectory(at: SafeRelativePath(record.installPath.lastPathComponent),
                        to: final, in: parent, matching: record.installIdentity)
                } else {
                    let target = try parent.createExclusiveDirectory(at: staging)
                    journal.destinationIdentity = try target.rootIdentity()
                    try await save(journal, game: game.id)
                    try await checkpoint(.copying)
                    try copy(entries, source: source, target: target, original: record.installPath,
                        destination: destination, progress: progress)
                    progress(.phase(.verifying))
                    try verify(entries, source: source, target: target, original: record.installPath,
                        destination: destination, progress: progress)
                    if let cache { try rebind(cache, to: target) }
                    // Restore directory times only after their last child write.
                    for entry in entries.reversed() where entry.type == .directory {
                        try source.copyMoveDirectoryAttributes(to: target, at: entry.path)
                    }
                    try source.copyMoveDirectoryAttributes(to: target)
                    journal.phase = .verified
                    try await save(journal, game: game.id)
                    try await checkpoint(.verified)
                    try check(record.installPath, destination)
                    progress(.phase(.committing))
                    try parent.moveDirectory(at: staging, to: final, in: parent, matching: target.rootIdentity())
                }
                try await checkpoint(.published)
                try check(record.installPath, destination)
                var moved = record
                moved.installPath = destination
                moved.installIdentity = journal.destinationIdentity!
                try await store.save(moved, for: game.id)
                // Once switched, cancellation must not interrupt cleanup or release ownership.
                let committed = journal
                try await Task.detached {
                    try await BlockingIO.run { try await finish(committed, game: game.id) }
                }.value
                progress(.phase(.completed))
                log?.post(.info, "game", "Move finished", metadata: ["game": game.id])
            } catch {
                let failure = error
                do {
                    try await Task.detached { try await BlockingIO.run { try await recoverOwned(game.id) } }.value
                } catch {
                    // A missing volume or changed identity retains the journal and
                    // blocks new launches/operations until recovery can prove ownership.
                    log?.post(.warning, "game", "Move recovery deferred", metadata: ["game": game.id])
                }
                log?.post(.warning, "game", "Move failed", metadata: ["game": game.id])
                throw failure
            }
        }
    }

    public func recover(_ id: String) async throws {
        try await operationGuard?.willOperate(on: id)
        try await BlockingIO.run {
            let lock = try gameLock(id)
            let lease = try await store.acquireOperationLease(retainedGameLock: lock)
            defer { withExtendedLifetime(lease) {} }
            try await recoverOwned(id)
        }
    }

    private func gameLock(_ id: String) throws -> InstallLock {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        try fs.createRootDurably()
        let directory = try SafeRelativePath("Games/\(SafeIdentifier(id).rawValue)")
        try fs.createDirectoryDurably(at: directory)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("\(directory)/.session.lock"))
        try LaunchMutationBarrier.requireNoJournal(paths: paths, game: id)
        return lock
    }

    private func requireMovable(_ id: String) async throws -> GameRecord {
        guard let record = try await store.load(id), record.installed != nil,
            record.pending == nil, !record.uninstalling, !record.uninstallFilesRemoved,
            try await store.readState("pending-plan.json", for: id, maxBytes: 1) == nil else {
            throw LauncherError.busy("Finish the current game operation before moving")
        }
        return record
    }

    private func requireNoRecovery(_ id: String, record: GameRecord, source: ContainedFileSystem) throws {
        let app = try ContainedFileSystem(root: paths.root)
        let parent = try ContainedFileSystem(root: record.installPath.deletingLastPathComponent())
        for (fs, name) in [(app, "Games/\(id)/recovery"), (parent, ".macgacha-recovery/\(id)"),
            (source, ".macgacha-recovery"), (source, ".macgacha-state.json")] {
            guard try fs.itemType(at: SafeRelativePath(name), allowingLeafSymlink: true) == nil else {
                throw LauncherError.busy("Game recovery is required")
            }
        }
        let noticePath = try SafeRelativePath("RecoveryNotices/\(id).json")
        if try app.itemType(at: noticePath, allowingLeafSymlink: true) != nil {
            let bytes = try app.readFile(at: noticePath, maxBytes: 1 << 20)
            guard let notices = try JSONSerialization.jsonObject(with: bytes) as? [Any], notices.isEmpty else {
                throw LauncherError.busy("Game recovery needs acknowledgment")
            }
        }
        let staging = try SafeRelativePath(".macgacha-staging")
        if try source.itemType(at: staging) != nil {
            // An idle engine leaves its lock inode, which is relative and portable.
            guard try source.contentsOfDirectory(at: staging).allSatisfy({ $0.components.last == ".lock" }) else {
                throw LauncherError.busy("Finish the current game operation before moving")
            }
        }
        guard try CompletionReceipt.unacknowledged(fs: source).isEmpty else {
            throw LauncherError.busy("Game completion recovery is required")
        }
    }

    private func sourceFS(_ record: GameRecord) throws -> ContainedFileSystem {
        try ContainedFileSystem(root: record.installPath, fileOps: fileOps, expectedRootIdentity: record.installIdentity).pinRoot()
    }
    private func requireVolumes(_ source: URL, _ destination: URL) throws {
        try locationProbe.requireAvailable(at: source)
        try locationProbe.requireAvailable(at: destination)
    }
    private func check(_ source: URL, _ destination: URL) throws {
        // Prefer the typed eject reason when cancellation races a volume notification.
        try requireVolumes(source, destination)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
    }
    private func save(_ journal: MoveJournal, game: String) async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(journal)
        guard bytes.count <= 65536 else { throw LauncherError.io("Move journal exceeds size limit") }
        try await store.writeState(bytes, named: Self.journalName, for: game)
    }

    private func recoverOwned(_ id: String) async throws {
        guard let data = try await store.readState(Self.journalName, for: id, maxBytes: 65536) else { return }
        let journal: MoveJournal
        do { journal = try JSONDecoder().decode(MoveJournal.self, from: data) }
        catch { throw LauncherError.journalCorrupt("Invalid move journal") }
        try journal.validate(game: id)
        guard let current = try await store.load(id) else { throw LauncherError.journalCorrupt("Missing move record") }
        if current == journal.movedRecord {
            try await finish(journal, game: id)
            return
        }
        guard current == journal.original else { throw LauncherError.journalCorrupt("Move record changed") }
        try requireVolumes(journal.original.installPath, journal.destination)
        let parent = try ContainedFileSystem(root: journal.destination.deletingLastPathComponent(), fileOps: fileOps,
            expectedRootIdentity: journal.parentIdentity).pinRoot()
        let sourceParent = try ContainedFileSystem(root: current.installPath.deletingLastPathComponent(), fileOps: fileOps,
            expectedRootIdentity: journal.sourceParentIdentity).pinRoot()
        let final = try SafeRelativePath(journal.destination.lastPathComponent)
        if journal.sameVolume {
            if try sourceParent.itemType(at: SafeRelativePath(current.installPath.lastPathComponent)) == nil {
                try parent.moveDirectory(at: final, to: SafeRelativePath(current.installPath.lastPathComponent),
                    in: sourceParent, matching: current.installIdentity)
            }
            _ = try sourceFS(current)
        } else {
            _ = try sourceFS(current)
            if let identity = journal.destinationIdentity {
                for path in [try SafeRelativePath(".macgacha-moving-\(id)"), final] {
                    if let fs = try parent.pinDirectoryIfPresent(at: path) {
                        guard try fs.rootIdentity() == identity else { throw LauncherError.io("Move destination changed") }
                        try fs.removeMoveRoot { try requireVolumes(journal.original.installPath, journal.destination) }
                    }
                }
            } else {
                let staging = try SafeRelativePath(".macgacha-moving-\(id)")
                if let emptyClaim = try parent.pinDirectoryIfPresent(at: staging) {
                    // No copy may begin until the identity is durable. A crash
                    // in that gap can leave only an empty mkdir claim.
                    guard try emptyClaim.contentsOfRootDirectory().isEmpty else {
                        throw LauncherError.io("Unidentified move staging is not empty")
                    }
                    try emptyClaim.removePinnedRoot(onlyIfEmpty: true)
                }
            }
        }
        try await store.deleteState(Self.journalName, for: id)
        log?.post(.info, "game", "Move rolled back", metadata: ["game": id])
    }

    private func finish(_ original: MoveJournal, game: String) async throws {
        var journal = original
        guard try await store.load(game) == journal.movedRecord else {
            throw LauncherError.journalCorrupt("Move record changed")
        }
        try requireVolumes(journal.original.installPath, journal.destination)
        guard let identity = journal.destinationIdentity else { throw LauncherError.journalCorrupt("Missing move identity") }
        _ = try ContainedFileSystem(root: journal.destination, fileOps: fileOps, expectedRootIdentity: identity).pinRoot()
        journal.phase = .switched
        try await save(journal, game: game)
        try await checkpoint(.switched)
        if !journal.sameVolume {
            let parent = try ContainedFileSystem(root: journal.original.installPath.deletingLastPathComponent(), fileOps: fileOps,
                expectedRootIdentity: journal.sourceParentIdentity).pinRoot()
            if let source = try parent.pinDirectoryIfPresent(at: SafeRelativePath(journal.original.installPath.lastPathComponent)) {
                guard try source.rootIdentity() == journal.original.installIdentity else { throw LauncherError.io("Move source changed") }
                try source.removeMoveRoot { try requireVolumes(journal.original.installPath, journal.destination) }
            }
        }
        journal.phase = .cleaned
        try await save(journal, game: game)
        try await checkpoint(.cleaned)
        try await store.deleteState(Self.journalName, for: game)
    }
}

private extension GameMover {
    func validateLinks(_ entries: [ContainedFileSystem.TreeEntry]) throws {
        let links = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.linkTarget.map { (entry.path.description, $0) } })
        for entry in entries where entry.linkTarget != nil {
            var pending = Array(entry.path.components.reversed()), resolved: [String] = [], followed = 0
            while let next = pending.popLast() {
                if next == "." || next.isEmpty { continue }
                if next == ".." {
                    guard !resolved.isEmpty else { throw LauncherError.unsafePath("move symlink") }
                    resolved.removeLast(); continue
                }
                resolved.append(next)
                if let target = links[resolved.joined(separator: "/")] {
                    followed += 1
                    guard followed <= 40, !target.hasPrefix("/"), !target.utf8.contains(0) else {
                        throw LauncherError.unsafePath("move symlink")
                    }
                    resolved.removeLast()
                    pending.append(contentsOf: target.split(separator: "/", omittingEmptySubsequences: false).map(String.init).reversed())
                }
            }
        }
    }

    func copy(_ entries: [ContainedFileSystem.TreeEntry], source: ContainedFileSystem, target: ContainedFileSystem,
        original: URL, destination: URL, progress: @Sendable (OperationEvent) -> Void) throws {
        progress(.phase(.staging))
        let files = entries.filter { $0.type == .regularFile }
        var done: Int64 = 0
        for entry in entries {
            try check(original, destination)
            if entry.type == .directory { try target.createDirectory(at: entry.path) }
            else if let link = entry.linkTarget { try target.createSymbolicLink(at: entry.path, target: link) }
            else {
                try source.copyMoveFile(at: entry.path, to: target)
                done += 1
                progress(.progress(downloaded: 0, totalNetwork: 0, staged: done, totalStaged: Int64(files.count)))
            }
        }
    }

    func verify(_ entries: [ContainedFileSystem.TreeEntry], source: ContainedFileSystem, target: ContainedFileSystem,
        original: URL, destination: URL, progress: @Sendable (OperationEvent) -> Void) throws {
        // A fresh snapshot also catches files added or removed during the copy.
        let after = try source.inspectTree(allowingExternalHardLinks: true)
        guard entries.map(\.path) == after.map(\.path), entries.map(\.linkTarget) == after.map(\.linkTarget) else {
            throw LauncherError.io("Move source changed")
        }
        let files = entries.filter { $0.type == .regularFile }
        for (index, entry) in files.enumerated() {
            try check(original, destination)
            guard try source.size(at: entry.path) == target.size(at: entry.path),
                try hash(source, entry.path, original: original, destination: destination) == hash(target, entry.path, original: original, destination: destination) else {
                throw LauncherError.io("Move verification failed")
            }
            progress(.progress(downloaded: 0, totalNetwork: 0, staged: Int64(index + 1), totalStaged: Int64(files.count)))
        }
    }

    func hash(_ fs: ContainedFileSystem, _ path: SafeRelativePath, original: URL, destination: URL) throws -> Digest {
        var hasher = StreamingHasher(.sha256)
        try fs.readFile(at: path) { bytes in
            try check(original, destination)
            hasher.update(bytes)
        }
        return hasher.finalize()
    }

    func rebind(_ state: PreDownloadState, to fs: ContainedFileSystem) throws {
        let plan = state.plan
        let rebound = try PreDownloadPlan(edition: plan.edition, region: plan.region, installation: fs.rootIdentity(),
            sourceTag: plan.sourceTag, targetTag: plan.targetTag, buildID: plan.buildID, patchID: plan.patchID,
            categories: plan.categories, voices: Set(plan.voices), containers: plan.containers)
        var result = try PreDownloadState(plan: rebound)
        result.verified = state.verified; result.completed = state.completed; result.withdrawn = state.withdrawn
        try PreDownloadStore(fs: fs).save(result)
    }
}

private struct MoveJournal: Codable, Sendable {
    enum Phase: String, Codable { case planned, copying, verified, switched, cleaned }
    let original: GameRecord
    let destination: URL
    let parentIdentity: FileSystemIdentity
    let sourceParentIdentity: FileSystemIdentity
    let sameVolume: Bool
    var destinationIdentity: FileSystemIdentity?
    var phase: Phase = .planned

    var movedRecord: GameRecord? {
        guard let destinationIdentity else { return nil }
        var moved = original
        moved.installPath = destination
        moved.installIdentity = destinationIdentity
        return moved
    }

    func validate(game: String) throws {
        guard let definition = GameDefinition.find(game), destination.isFileURL,
            destination.query == nil, destination.fragment == nil,
            destination.lastPathComponent == definition.defaultInstallDirectoryName,
            original.installed != nil, original.pending == nil, !original.uninstalling else {
            throw LauncherError.journalCorrupt("Invalid move journal")
        }
        try GameRecordRules.checkLocation(destination, others: [original], reserved: [])
    }
}
