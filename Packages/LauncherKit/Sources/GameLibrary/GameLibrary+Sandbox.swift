// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import Sophon

/// Validates the sandbox archive policy before sizing or extracting into contained staging.
public protocol SandboxPackageExtracting: Sendable {
    func expandedSize(archive: SafeRelativePath, in fs: ContainedFileSystem, listPath: SafeRelativePath) async throws -> Int64
    func extract(archive: SafeRelativePath, in fs: ContainedFileSystem, to target: SafeRelativePath,
        listPath: SafeRelativePath, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

extension GameLibrary {
    /// The model uses this metadata and local presence to schedule optional work.
    public func sandboxState(_ game: GameDefinition) async throws -> SandboxState? {
        guard game.family == .genshin, let record = try await store.load(game.id), record.installed != nil,
            !record.uninstalling else { return nil }
        try locationProbe.requireAvailable(at: record.installPath)
        let config = try await gameConfig(game)
        guard let list = SandboxFiles.supportedList(config.wpfPackageVersion), let executable = config.wpfExecutable else { return nil }
        try validateSandboxConfig(list: list, executable: executable)
        guard try await !sandboxListIsManaged(game.id, record: record) else { return nil }
        guard let package = try await api.sandboxPackage(biz: game.biz) else { return nil }
        let fs = try sandboxFilesystem(record)
        let local = try record.sandbox ?? SandboxFiles.detect(in: fs, listPath: list)
        guard let local else { return .notInstalled(size: package.size) }
        if record.sandbox == nil { try await rememberDetectedSandbox(game, record: record, installation: local) }
        // A missing package list/editor is actionable even with a current record.
        if local.version == package.version, try fs.itemType(at: local.listPath) == .regularFile,
            try fs.itemType(at: executable) == .regularFile { return .installed(version: package.version) }
        return .outdated(installed: local.version, available: package.version, size: package.size)
    }
    public func installSandbox(_ game: GameDefinition) -> AsyncThrowingStream<OperationEvent, any Error> { sandboxStream(game, remove: false) }
    public func updateSandbox(_ game: GameDefinition) -> AsyncThrowingStream<OperationEvent, any Error> { sandboxStream(game, remove: false) }
    public func removeSandbox(_ game: GameDefinition) -> AsyncThrowingStream<OperationEvent, any Error> { sandboxStream(game, remove: true) }

    /// Revalidate the observed offer and the game's update priority under the same
    /// exclusions as an explicit sandbox update. A stale offer is a quiet no-op.
    public func automaticallyUpdateSandbox(_ game: GameDefinition, expectedVersion: String) -> AsyncThrowingStream<OperationEvent, any Error> {
        sandboxWork(prepare: { try await self.acquireSandboxLease(game, allowRecovery: false) }) { progress in
            do {
                try await self.performSandbox(game, remove: false, expectedVersion: expectedVersion, progress: progress)
            } catch {
                let outcome = Task.isCancelled ? "cancelled" : "failed"
                self.log?.post(.info, "sandbox", "Automatic sandbox update", metadata: ["outcome": outcome])
                throw error
            }
        }
    }

    /// Play joins abandoned transfers and refuses an unresolved publication.
    public func waitForSandboxDrain(_ id: String) async throws {
        try await store.waitForPipelineDrain()
        try LaunchMutationBarrier.requireNoSandbox(paths: paths, game: id)
    }

    private func sandboxStream(_ game: GameDefinition, remove: Bool) -> AsyncThrowingStream<OperationEvent, any Error> {
        sandboxWork(prepare: { try await self.acquireSandboxLease(game, allowRecovery: true) }) { progress in
            try await self.performSandbox(game, remove: remove, progress: progress)
        }
    }

    private func acquireSandboxLease(_ game: GameDefinition, allowRecovery: Bool) async throws -> GameOperationLease {
        guard game.family == .genshin else { throw LauncherError.io("Sandbox is unavailable") }
        if !allowRecovery { try LaunchMutationBarrier.requireNoJournal(paths: paths, game: game.id) }
        try await operationGuard?.willOperate(on: game.id)
        let gameLock = try acquireGameLock(game.id, allowSandboxRecovery: allowRecovery)
        return try await store.acquireOperationLease(retainedGameLock: gameLock)
    }

    private func performSandbox(_ game: GameDefinition, remove: Bool, expectedVersion: String? = nil,
        progress: @escaping @Sendable (OperationEvent) -> Void) async throws {
        if expectedVersion == nil { try await recoverSandbox(game.id) }
        guard var record = try await store.load(game.id), let build = record.installed else {
            throw LauncherError.io("Game is not installed")
        }
        try GameRecordRules.check(.repair, record: record, others: [])
        try await requireSandboxLocation(record, game: game.id)
        guard try await store.loadPlan(for: game.id) == nil else { throw LauncherError.busy("Finish the current game operation") }
        if expectedVersion != nil, try await checkForUpdate(game) != .installed(tag: build.tag) {
            progress(.phase(.completed))
            return
        }
        guard try await !sandboxListIsManaged(game.id, record: record) else { throw LauncherError.io("Sandbox list belongs to the game") }
        if remove {
            let fs = try sandboxFilesystem(record)
            if record.sandbox == nil {
                if let config = try? await gameConfig(game), let list = SandboxFiles.supportedList(config.wpfPackageVersion) {
                    record.sandbox = try SandboxFiles.detect(in: fs, listPath: list)
                }
            }
            guard record.sandbox != nil else { throw LauncherError.io("Sandbox is not installed") }
            try await store.save(record, for: game.id)
            let stage = try prepareSandboxStage(fs)
            progress(.sandboxPhase(.removing)); progress(.phase(.deleting))
            try await sandboxPublisher.publish(game: game.id, record: record, stage: stage, installation: nil)
            log?.post(.info, "sandbox", "Sandbox operation", metadata: ["outcome": "removed", "bytes": "0"])
        } else {
            let config = try await gameConfig(game)
            guard let list = SandboxFiles.supportedList(config.wpfPackageVersion), let executable = config.wpfExecutable,
                let package = try await api.sandboxPackage(biz: game.biz) else {
                if expectedVersion != nil { progress(.phase(.completed)); return }
                throw LauncherError.io("Sandbox is unavailable")
            }
            try validateSandboxConfig(list: list, executable: executable)
            let fs = try sandboxFilesystem(record)
            let local = try record.sandbox ?? SandboxFiles.detect(in: fs, listPath: list)
            if let expectedVersion {
                guard let local, package.version == expectedVersion else { progress(.phase(.completed)); return }
                if local.version == package.version, try fs.itemType(at: local.listPath) == .regularFile,
                    try fs.itemType(at: executable) == .regularFile {
                    progress(.phase(.completed))
                    return
                }
                guard local.listPath == list else { throw LauncherError.io("Sandbox list changed") }
                // Reject an invalid config before downloading or entering publication.
                _ = try SandboxFiles.configData(setting: package.version, in: fs)
            }
            if record.sandbox == nil {
                record.sandbox = local
                if record.sandbox != nil { try await store.save(record, for: game.id) }
            }
            try await installSandboxPackage(game, record: record, package: package, list: list, executable: executable,
                recoverOnFailure: expectedVersion != nil, progress: progress)
        }
        progress(.phase(.completed))
    }

    private func sandboxListIsManaged(_ game: String, record: GameRecord) async throws -> Bool {
        guard record.installed != nil else { return false }
        return try await SandboxFiles.listIsManaged(store.managedPaths(for: game, record: record))
    }

    func gameConfig(_ game: GameDefinition) async throws -> GameConfig {
        let config = try await api.config(biz: game.biz)
        sandboxConfigurations[game.id] = config
        return config
    }

    private func rememberDetectedSandbox(_ game: GameDefinition, record: GameRecord, installation: SandboxInstallation) async throws {
        do {
            try await operationGuard?.willOperate(on: game.id)
            let lock = try acquireGameLock(game.id)
            let lease = try await store.acquireOperationLease(retainedGameLock: lock)
            defer { withExtendedLifetime(lease) {} }
            guard var current = try await store.load(game.id), current == record,
                current.pending == nil, !current.uninstalling else { return }
            try await requireSandboxLocation(current, game: game.id)
            guard try await !sandboxListIsManaged(game.id, record: current) else { return }
            current.sandbox = installation
            current.sandboxListPath = installation.listPath
            try await store.save(current, for: game.id)
        } catch LauncherError.busy { /* A later idle refresh can retain the detection. */ }
    }

    /// Capture adoption before a game plan can replace or delete any managed path.
    func detectSandboxBeforeGameOperation(_ game: GameDefinition, record: GameRecord) async throws -> GameRecord {
        guard game.family == .genshin, record.installed != nil else { return record }
        let fs = try sandboxFilesystem(record)
        var updated = record
        if let config = sandboxConfigurations[game.id] {
            updated.sandboxListPath = SandboxFiles.supportedList(config.wpfPackageVersion)
        }
        if updated.sandbox == nil, let list = updated.sandboxListPath,
            try await !sandboxListIsManaged(game.id, record: record) {
            updated.sandbox = try SandboxFiles.detect(in: fs, listPath: list)
        }
        if updated != record {
            try await requireSandboxLocation(record, game: game.id)
            try await store.save(updated, for: game.id)
        }
        return updated
    }

    func needsSandboxConfigDiscovery(_ record: GameRecord) throws -> Bool {
        guard record.sandboxListPath == nil, record.sandbox == nil else { return false }
        return try sandboxFilesystem(record).itemType(at: SandboxFiles.assets) == .directory
    }

    /// Adopted uninstall removes owned editor files as well as Sophon files.
    func removeSandboxForUninstall(_ game: GameDefinition, record: GameRecord) async throws -> GameRecord {
        guard game.family == .genshin, record.ownership == .adopted, !record.uninstallFilesRemoved else { return record }
        let fs = try sandboxFilesystem(record)
        var current = record
        guard try await !sandboxListIsManaged(game.id, record: record) else { return record }
        if current.sandbox == nil, let list = record.sandboxListPath {
            current.sandbox = try SandboxFiles.detect(in: fs, listPath: list)
        }
        guard current.sandbox != nil else { return record }
        try await store.save(current, for: game.id)
        try await sandboxPublisher.publish(game: game.id, record: current, stage: prepareSandboxStage(fs), installation: nil)
        current.sandbox = nil
        return current
    }

    /// Called under the ordinary operation lease, before game reconciliation/mutation.
    func recoverSandbox(_ id: String) async throws {
        guard try await store.readState(SandboxPublisher.journalName, for: id, maxBytes: 65536) != nil else { return }
        guard let record = try await store.load(id) else { throw LauncherError.journalCorrupt("Missing sandbox game record") }
        try await requireSandboxLocation(record, game: id)
        try await sandboxPublisher.recover(game: id)
    }

    private func requireSandboxLocation(_ record: GameRecord, game: String) async throws {
        try locationProbe.requireAvailable(at: record.installPath)
        let others = try await store.records().filter { $0.key != game }.map(\.value)
        try GameRecordRules.checkLocation(record.installPath, others: others, reserved: [paths.root, paths.runtimes])
    }

    /// Shares the outer operation's lease. Optional maintenance errors have their
    /// own event and cannot undo a successfully committed game build.
    func sandboxMaintenance(_ game: GameDefinition, mode: Verifier.Mode?, lease: GameOperationLease) -> AsyncThrowingStream<OperationEvent, any Error> {
        sandboxWork(retaining: lease) { progress in
            do { try await self.maintainSandbox(game, mode: mode, progress: progress) }
            catch {
                if Task.isCancelled || error as? LauncherError == .cancelled || error is CancellationError { throw LauncherError.cancelled }
                progress(.sandboxFailed(error as? LauncherError ?? .io("Sandbox maintenance failed")))
                self.log?.post(.warning, "sandbox", "Sandbox operation", metadata: ["outcome": "failed"])
            }
            progress(.phase(.completed))
        }
    }
    private func maintainSandbox(_ game: GameDefinition, mode: Verifier.Mode?, progress: @escaping @Sendable (OperationEvent) -> Void) async throws {
        guard game.family == .genshin, var record = try await store.load(game.id), record.installed != nil else { return }
        try locationProbe.requireAvailable(at: record.installPath)
        let fs = try sandboxFilesystem(record)
        // Avoid making an absent optional package a prerequisite for game updates.
        guard record.sandbox != nil || record.sandboxListPath != nil,
            try await !sandboxListIsManaged(game.id, record: record) else { return }
        let detected = try record.sandbox ?? record.sandboxListPath.flatMap { try SandboxFiles.detect(in: fs, listPath: $0) }
        guard let local = detected else { return }
        try await requireSandboxLocation(record, game: game.id)
        let config = try await gameConfig(game)
        guard let list = SandboxFiles.supportedList(config.wpfPackageVersion), let executable = config.wpfExecutable else { return }
        guard let package = try await api.sandboxPackage(biz: game.biz) else { return }
        if record.sandbox == nil { record.sandbox = local; try await store.save(record, for: game.id) }
        try validateSandboxConfig(list: list, executable: executable)
        var damaged = false
        if let mode {
            progress(.sandboxPhase(.verifying)); progress(.phase(.verifying))
            do {
                damaged = try !SandboxFiles.verify(in: fs, listPath: local.listPath, mode: mode) { done, total in
                    progress(.progress(downloaded: 0, totalNetwork: 0, staged: done, totalStaged: total))
                }
            } catch {
                if Task.isCancelled { throw LauncherError.cancelled }
                damaged = true
            }
        }
        if damaged || local.version != package.version {
            try await installSandboxPackage(game, record: record, package: package, list: list, executable: executable, progress: progress)
        }
    }

    private func installSandboxPackage(_ game: GameDefinition, record: GameRecord, package: SandboxPackage,
        list: SafeRelativePath, executable: SafeRelativePath, recoverOnFailure: Bool = false,
        progress: @escaping @Sendable (OperationEvent) -> Void) async throws {
        guard let extractor = sandboxExtractor else { throw LauncherError.io("Sandbox extraction is unavailable") }
        let fs = try sandboxFilesystem(record)
        progress(.sandboxPhase(.downloading)); progress(.phase(.checkingSpace))
        // Admit the archive first, then inspect its verified directory before
        // admitting any expansion. The resident archive is already charged to free space.
        try requireSandboxSpace(package.size + SpaceBudget.margin, record: record)
        let stage = try prepareSandboxStage(fs)
        let archive = try SafeRelativePath(stage.description + "/package.zip")
        do {
            progress(.phase(.staging))
            let (_, body) = try await api.sandboxDownload(package)
            var downloaded: Int64 = 0, hash = StreamingHasher(.md5)
            try fs.writeAtomically(Data(), to: archive)
            for try await bytes in body {
                try Task.checkCancellation()
                try locationProbe.requireAvailable(at: record.installPath)
                guard Int64(bytes.count) <= package.size - downloaded else { throw LauncherError.io("Sandbox package size mismatch") }
                try fs.append(bytes, to: archive)
                hash.update(bytes); downloaded += Int64(bytes.count)
                progress(.progress(downloaded: downloaded, totalNetwork: package.size, staged: 0, totalStaged: 0))
            }
            guard downloaded == package.size, hash.finalize() == package.md5 else { throw LauncherError.io("Sandbox package verification failed") }
            try fs.fullSync(at: archive)
            let expanded = try await extractor.expandedSize(archive: archive, in: fs, listPath: list)
            try requireSandboxSpace(expanded + SpaceBudget.margin, record: record)
            progress(.sandboxPhase(.extracting)); progress(.phase(.staging))
            let target = try SafeRelativePath(stage.description + "/new")
            try await extractor.extract(archive: archive, in: fs, to: target, listPath: list) { done, total in
                progress(.progress(downloaded: package.size, totalNetwork: package.size, staged: done, totalStaged: total))
            }
            guard let staged = try fs.pinDirectoryIfPresent(at: target),
                try staged.itemType(at: executable) == .regularFile,
                try SandboxFiles.verify(in: staged, listPath: list, mode: .full) else { throw LauncherError.io("Sandbox package list verification failed") }
            try Task.checkCancellation()
            progress(.sandboxPhase(.finishing)); progress(.phase(.committing))
            try await sandboxPublisher.publish(game: game.id, record: record, stage: stage,
                installation: SandboxInstallation(version: package.version, listPath: list))
            log?.post(.info, "sandbox", "Sandbox operation", metadata: ["outcome": "installed", "version": package.version, "bytes": String(downloaded), "expanded": String(expanded)])
        } catch {
            // A durable publication journal owns its staging until recovery. A
            // failed or cancelled download has no resumable receipt: restart cleanly.
            let store = store
            let hasJournal = try? await Task.detached { try await store.readState(SandboxPublisher.journalName, for: game.id, maxBytes: 65536) != nil }.value
            if hasJournal == false { try? await BlockingIO.finish { try fs.removeItem(at: stage) } }
            if hasJournal == true, recoverOnFailure {
                // Keep the lease while rolling back pre-commit cancellation or
                // finishing a durable swap. Play can proceed only after this joins.
                let publisher = sandboxPublisher
                let committed = try await Task.detached { try await publisher.recover(game: game.id) }.value
                if committed {
                    log?.post(.info, "sandbox", "Sandbox operation", metadata: ["outcome": "installed", "version": package.version])
                    return
                }
            }
            log?.post(.warning, "sandbox", "Sandbox operation", metadata: ["outcome": Task.isCancelled ? "cancelled" : "failed", "version": package.version, "bytes": "0"])
            throw error
        }
    }
    private var sandboxPublisher: SandboxPublisher { SandboxPublisher(store: store, fileOps: fileOps, log: log) }
    private func sandboxFilesystem(_ record: GameRecord) throws -> ContainedFileSystem {
        try ContainedFileSystem(root: record.installPath, fileOps: fileOps, expectedRootIdentity: record.installIdentity).pinRoot()
    }
    private func prepareSandboxStage(_ fs: ContainedFileSystem) throws -> SafeRelativePath {
        let path = try SafeRelativePath(".macgacha-staging/sandbox-work")
        if try fs.itemType(at: path, allowingLeafSymlink: true) != nil { try fs.removeItem(at: path) }
        try fs.createDirectoryDurably(at: path)
        return path
    }
    private func requireSandboxSpace(_ required: Int64, record: GameRecord) throws {
        try locationProbe.requireAvailable(at: record.installPath)
        let available = try disk.availableBytes(at: record.installPath)
        guard available >= required else { throw LauncherError.insufficientSpace(required: required, available: available) }
    }
    private func validateSandboxConfig(list: SafeRelativePath, executable: SafeRelativePath) throws {
        try SandboxFiles.validateListPath(list)
        guard executable.components.count > 1, executable.components.first == "BeyondAssets" else { throw LauncherError.unsafePath("Invalid sandbox executable") }
    }
}

private func sandboxWork(retaining lease: GameOperationLease? = nil, prepare: (@Sendable () async throws -> GameOperationLease)? = nil,
    _ work: @escaping @Sendable (@escaping @Sendable (OperationEvent) -> Void) async throws -> Void) -> AsyncThrowingStream<OperationEvent, any Error> {
    let session = SandboxOperationStream(work, retaining: lease, prepare: prepare)
    return session.stream()
}
private actor SandboxOperationStream {
    private let work: @Sendable (@escaping @Sendable (OperationEvent) -> Void) async throws -> Void
    private let prepare: (@Sendable () async throws -> GameOperationLease)?
    private let channel = PipelineChannel()
    private var producer: Task<Void, Never>?
    private var pulling = false
    private let owner = UUID()
    private let retention = PipelineRootRetention(key: "sandbox-" + UUID().uuidString)
    init(_ work: @escaping @Sendable (@escaping @Sendable (OperationEvent) -> Void) async throws -> Void,
        retaining lease: GameOperationLease?, prepare: (@Sendable () async throws -> GameOperationLease)?) {
        self.work = work; self.prepare = prepare
        retention.hold(nil, owner: owner, retaining: lease)
    }
    nonisolated func stream() -> AsyncThrowingStream<OperationEvent, any Error> {
        pipelineStream(abandon: { [retention, owner] in retention.abandon(owner) }) {
            register in try await self.next(register: register)
        }
    }
    func next(register: @Sendable (Task<Void, Never>) -> Void) async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("Sandbox stream already in use") }
        pulling = true; defer { pulling = false }
        if producer == nil {
            if let prepare {
                let lease = try await prepare()
                try Task.checkCancellation()
                retention.hold(nil, owner: owner, retaining: lease)
            }
            let work = work, channel = channel, retention = retention, owner = owner
            retention.activate(owner)
            let task = Task {
                let counter = SandboxProgressChannel(channel: channel)
                do { try await work { counter.send($0) }; retention.release(owner); channel.finish() }
                catch {
                    retention.release(owner)
                    channel.finish(Task.isCancelled || error is CancellationError ? LauncherError.cancelled : error)
                }
            }
            producer = task; register(task)
            if Task.isCancelled { task.cancel() }
        }
        do {
            let event = try await channel.next()
            if event == nil || event == .phase(.completed) { await producer?.value }
            return event
        } catch { await producer?.value; throw error }
    }
}

/// Progress snapshots are coalesced; phase changes retain their order.
private final class SandboxProgressChannel: Sendable {
    let channel: PipelineChannel
    let counter = PipelineProgress(sizes: [:])
    init(channel: PipelineChannel) { self.channel = channel }
    func send(_ event: OperationEvent) {
        if case .progress(let downloaded, let network, let staged, let total) = event {
            counter.initialize(downloaded: downloaded, total: network, credited: [], predicted: [])
            counter.stage(staged, total: total); channel.send(counter.snapshot())
        } else { channel.send(event) }
    }
}
