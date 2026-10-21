// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import Sophon

public enum GameStatus: Sendable, Equatable {
    case unknown, notInstalled, installed(tag: String), updateAvailable(from: String, to: String)
    case paused(PendingOperation.Kind), uninstallPaused, locationUnavailable(URL)
}
public struct GameEstimate: Sendable, Equatable {
    public let download: Int64
    public let diskWhole: Int64
    public let diskMinimum: Int64
    public let available: Int64?
    public init(download: Int64, diskWhole: Int64, diskMinimum: Int64, available: Int64?) {
        self.download = download; self.diskWhole = diskWhole; self.diskMinimum = diskMinimum; self.available = available
    }
}

public actor GameLibrary {
    private let paths: AppPaths
    private let api: DeliveryAPI
    private let runner: OperationRunner
    private let store: GameRecordStore
    private let disk: any DiskSpaceProbe
    private let log: EventLog?
    private let hooks: CrashHooks
    private let fileOps: any FileOps
    private var started = false
    private static let cleanupName = "uninstall-cleaned.json"

    public init(paths: AppPaths, api: DeliveryAPI, runner: OperationRunner, store: GameRecordStore,
        disk: any DiskSpaceProbe, log: EventLog?, crashHooks: CrashHooks = .none, fileOps: any FileOps = SystemFileOps()) {
        self.paths = paths; self.api = api; self.runner = runner; self.store = store
        self.disk = disk; self.log = log; hooks = crashHooks; self.fileOps = fileOps
    }

    public func start() async {
        guard !started else { return }; started = true
        do {
            for id in try await store.gameDirectories().sorted() {
                guard !Task.isCancelled else { return }
                do { _ = try await runner.reconcile(id) }
                catch { await log?.log(.error, "game-library", "Reconciliation failed", metadata: ["game": id]) }
            }
        } catch { await log?.log(.error, "game-library", "Record discovery failed") }
    }

    public func status(_ game: GameDefinition) async -> GameStatus {
        do {
            guard let record = try await store.load(game.id) else { return .notInstalled }
            do { try requireGameLocationAvailable(record.installPath) }
            catch { return .locationUnavailable(record.installPath) }
            if record.uninstalling { return .uninstallPaused }
            if let pending = record.pending { return .paused(pending.kind) }
            guard let installed = record.installed else { return .unknown }
            let branch = try? await branch(game, cachedFallback: true)
            if let branch, branch.tag != installed.tag { return .updateAvailable(from: installed.tag, to: branch.tag) }
            return .installed(tag: installed.tag)
        } catch { return .unknown }
    }

    public func estimate(_ game: GameDefinition, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        // Estimates only read operation state. Metadata caches are atomic and
        // verified on read, so they do not require the exclusive operation lease.
        let records = try await store.records()
        try GameRecordRules.check(.install, record: records[game.id], others: others(records, game))
        try checkNewLocation(location, records: records, game: game, empty: true)
        let target = try await resolve(game, voices: voices)
        let id = try planID(game, kind: .install, build: target.build, categories: target.categories)
        let plan = try SophonPlanner.fullPlan(id: id, target: target.categories)
        let fs = try ContainedFileSystem(root: location)
        let whole = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs)
        return GameEstimate(download: whole.network, diskWhole: whole.disk,
            diskMinimum: try SpaceBudget.minimumBatchedPreflight(plan: plan, state: JournalState(), fs: fs),
            available: try? disk.availableBytes(at: location))
    }

    public func install(_ game: GameDefinition, voices: Set<String>, at location: URL, approved: Bool) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, .install(voices, location, approved))
    }
    public func adopt(_ game: GameDefinition, folder: URL, voices: Set<String>) -> AsyncThrowingStream<OperationEvent, any Error> {
        stream(game, .adopt(voices, folder))
    }
    public func update(_ game: GameDefinition, approved: Bool) -> AsyncThrowingStream<OperationEvent, any Error> { stream(game, .update(approved)) }
    public func resume(_ game: GameDefinition, approved: Bool) -> AsyncThrowingStream<OperationEvent, any Error> { stream(game, .resume(approved)) }
    public func verify(_ game: GameDefinition, mode: Verifier.Mode) -> AsyncThrowingStream<OperationEvent, any Error> { stream(game, .verify(mode)) }
    public func setVoices(_ game: GameDefinition, _ voices: Set<String>) -> AsyncThrowingStream<OperationEvent, any Error> { stream(game, .voices(voices)) }

    public func uninstall(_ game: GameDefinition) async throws {
        let lease = try await store.acquireOperationLease(); defer { withExtendedLifetime(lease) {} }
        let records = try await store.records()
        try GameRecordRules.check(.uninstall, record: records[game.id], others: others(records, game))
        guard var record = records[game.id] else { throw LauncherError.io("game is not installed") }
        if !record.uninstallFilesRemoved {
            try requireGameLocationAvailable(record.installPath)
            try checkLocation(record.installPath, records: records, game: game)
            let fs: ContainedFileSystem?
            do { fs = try ContainedFileSystem(root: record.installPath, fileOps: fileOps).pinRootIfPresent() }
            catch LauncherError.unsafePath { throw LauncherError.io("install folder was replaced") }
            if let fs {
                guard try fs.rootIdentity() == record.installIdentity else { throw LauncherError.io("install folder was replaced") }
            } else if !record.uninstalling { throw LauncherError.io("install folder was replaced") }
            record.uninstalling = true
            try await store.save(record, for: game.id) // 1. Persist intent before removal.
            try checkLocation(record.installPath, records: records, game: game)
            if let fs {
                if record.ownership == .created {
                    try fs.removePinnedRoot(onlyIfEmpty: false)
                } else {
                    let managed = try await store.managedPaths(for: game.id, record: record)
                    var skipped = 0
                    for path in managed.sorted(by: { $0.components.count > $1.components.count }) {
                        guard !Task.isCancelled else { throw LauncherError.cancelled }
                        do {
                            if let type = try fs.itemType(at: path) {
                                if type == .regularFile { try fs.removeFile(at: path) }
                                else { skipped += 1 }
                            }
                        } catch LauncherError.unsafePath { skipped += 1 }
                    }
                    if skipped > 0 { await log?.log(.info, "game-library", "Managed paths left untouched", metadata: ["count": String(skipped)]) }
                    for name in [".macgacha-staging", ".macgacha-receipts"] { try fs.removeItem(at: SafeRelativePath(name)) }
                    try fs.removeFile(at: SafeRelativePath(".macgacha-state.json"))
                    try fs.pruneEmptyDirectories()
                    try fs.removePinnedRoot(onlyIfEmpty: true)
                }
            }
            // Keep the cleanup phase in the last-to-be-deleted record. It remains
            // authoritative even after every side file has been retired.
            record.uninstallFilesRemoved = true
            try await store.save(record, for: game.id)
        }
        hooks.reach(.afterGameFolderRemoved)
        try await store.deletePlan(for: game.id) // 4. Record outlives every side file.
        hooks.reach(.afterUninstallPlanDeleted)
        try await store.deleteManifestCache(for: game.id)
        hooks.reach(.afterUninstallManifestCacheDeleted)
        try await store.deleteState("branch.json", for: game.id)
        hooks.reach(.afterUninstallBranchDeleted)
        try await store.deleteState("managed-paths.json", for: game.id)
        hooks.reach(.afterUninstallManagedPathsDeleted)
        try await store.deleteState(Self.cleanupName, for: game.id)
        hooks.reach(.afterUninstallCleanupDeleted)
        hooks.reach(.beforeGameRecordDeleted)
        try await store.delete(game.id)
        hooks.reach(.afterUninstallRecordDeleted)
        try await store.deleteGameDirectory(game.id)
    }

    private func stream(_ game: GameDefinition, _ request: LibraryRequest) -> AsyncThrowingStream<OperationEvent, any Error> {
        let session = LibrarySession(owner: self, game: game, request: request)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }

    fileprivate func prepare(_ game: GameDefinition, request: LibraryRequest) async throws -> LibraryPrepared {
        let lease = try await store.acquireOperationLease()
        let records = try await store.records(); let record = records[game.id]
        try GameRecordRules.check(request.action, record: record, others: others(records, game))
        if let record { try requireGameLocationAvailable(record.installPath) }
        switch request {
        case .resume(let approved):
            return LibraryPrepared(lease: lease, stream: await runner.resume(game.id, approved: approved, lease: lease))
        case .install(let voices, let location, let approved):
            try checkNewLocation(location, records: records, game: game, empty: true)
            try await store.deleteState(Self.cleanupName, for: game.id)
            let config = try await api.config(biz: game.biz), target = try await resolve(game, voices: voices)
            let plan = try SophonPlanner.fullPlan(id: planID(game, kind: .install, build: target.build, categories: target.categories), target: target.categories)
            return LibraryPrepared(lease: lease, stream: await runner.startInstall(game.id, at: location, executable: config.executable, plan: plan,
                target: target.build, approved: approved, lease: lease, managedPaths: target.managedPaths,
                reservedLocations: [paths.root, paths.runtimes]))
        case .adopt(let voices, let location):
            try checkNewLocation(location, records: records, game: game, empty: false)
            let identity = try ContainedFileSystem(root: location).rootIdentity()
            try await store.deleteState(Self.cleanupName, for: game.id)
            let config = try await api.config(biz: game.biz), target = try await resolve(game, voices: voices)
            let record = GameRecord(installPath: location, ownership: .adopted, executable: config.executable, installIdentity: identity)
            return LibraryPrepared(lease: lease, stream: verification {
                try await self.verifyAndRun(game, record: record, target: target, kind: .adopt, mode: .full, lease: lease)
            })
        case .verify(let mode):
            guard let record, let installed = record.installed else { throw LauncherError.io("game is not installed") }
            let target = LibraryTarget(build: installed, categories: try await planned(installed.categories, game: game))
            return LibraryPrepared(lease: lease, stream: verification {
                try await self.verifyAndRun(game, record: record, target: target, kind: .repair, mode: mode, lease: lease)
            })
        case .update(let approved):
            guard let record, let installed = record.installed else { throw LauncherError.io("game is not installed") }
            let target = try await resolve(game, voices: installed.voices)
            return try await updateStream(game, record: record, installed: installed, target: target, kind: .update, approved: approved, lease: lease)
        case .voices(let voices):
            guard let record, let installed = record.installed else { throw LauncherError.io("game is not installed") }
            let target: LibraryTarget
            if voices.isSubset(of: installed.voices) {
                let known = Set(game.voices.map(\.code))
                let selected = installed.categories.filter { !known.contains($0.matchingField) || voices.contains($0.matchingField) }
                target = LibraryTarget(build: InstalledBuild(tag: installed.tag, buildID: installed.buildID, categories: selected, voices: voices),
                    categories: try await planned(selected, game: game))
            } else {
                target = try await resolve(game, voices: voices, tag: installed.tag)
                guard target.build.buildID == installed.buildID, target.build.tag == installed.tag else { throw LauncherError.io("installed build unavailable") }
            }
            return try await updateStream(game, record: record, installed: installed, target: target, kind: .voices, approved: false, lease: lease)
        }
    }

    private func updateStream(_ game: GameDefinition, record: GameRecord, installed: InstalledBuild, target: LibraryTarget,
        kind: PendingOperation.Kind, approved: Bool, lease: GameOperationLease) async throws -> LibraryPrepared {
        let snapshot = InstalledSnapshot(categories: try await planned(installed.categories, game: game))
        let plan = try SophonPlanner.plan(id: planID(game, kind: kind, build: target.build, categories: target.categories), target: target.categories, installed: snapshot)
        return LibraryPrepared(lease: lease, stream: await runner.start(game.id, record: record, plan: plan, kind: kind,
            target: target.build, approved: approved, lease: lease, managedPaths: target.managedPaths,
                reservedLocations: [paths.root, paths.runtimes]))
    }

    private func verifyAndRun(_ game: GameDefinition, record: GameRecord, target: LibraryTarget, kind: PendingOperation.Kind,
        mode: Verifier.Mode, lease: GameOperationLease) async throws -> AsyncThrowingStream<OperationEvent, any Error> {
        let full = try SophonPlanner.fullPlan(id: planID(game, kind: kind, build: target.build, categories: target.categories), target: target.categories)
        if kind == .adopt, !full.files.contains(where: { $0.path == record.executable }),
            try ContainedFileSystem(root: record.installPath).itemType(at: record.executable) != .regularFile {
            throw LauncherError.io("game executable missing")
        }
        let report = try await Verifier().verify(fs: ContainedFileSystem(root: record.installPath, expectedRootIdentity: record.installIdentity), files: full.files.map(ManifestFile.init), mode: mode)
        if report.isClean, kind == .repair {
            return AsyncThrowingStream { continuation in continuation.yield(.phase(.completed)); continuation.finish() }
        }
        let id = try planID(game, kind: kind, build: target.build, categories: target.categories, repaired: Array(report.problems.keys))
        let plan = try repairPlan(from: report, plan: full, id: id)
        return await runner.start(game.id, record: record, plan: plan, kind: kind, target: target.build, approved: false, lease: lease, managedPaths: target.managedPaths,
            reservedLocations: [paths.root, paths.runtimes])
    }

    private func resolve(_ game: GameDefinition, voices: Set<String>, tag: String? = nil) async throws -> LibraryTarget {
        let branch = try await branch(game, cachedFallback: false)
        let build = try await api.build(branch, tag: tag)
        let selected = try SophonPlanner.selectCategories(branch, build: build, voices: voices)
        return LibraryTarget(build: InstalledBuild(tag: build.tag, buildID: build.buildID, categories: selected, voices: voices),
            categories: try await planned(selected, game: game))
    }

    private func branch(_ game: GameDefinition, cachedFallback: Bool) async throws -> GameBranch {
        let value: GameBranch
        do {
            value = try await api.branch(biz: game.biz)
        } catch {
            if Task.isCancelled { throw LauncherError.cancelled }
            if cachedFallback, let data = try? await store.readState("branch.json", for: game.id, maxBytes: 2 << 20),
                let value = try? JSONDecoder().decode(GameBranch.self, from: data), value.biz == game.biz { return value }
            throw error
        }
        do {
            try await store.writeCacheState(JSONEncoder().encode(value), named: "branch.json", for: game.id)
        } catch {
            try await cacheFailure(error, game: game, kind: "branch", action: "write")
        }
        return value
    }

    private func planned(_ categories: [BuildCategory], game: GameDefinition) async throws -> [PlannedCategory] {
        let cache: ContainedFileSystem?
        do {
            cache = try ContainedFileSystem(root: await store.manifestCache(for: game.id), fileOps: fileOps)
        } catch {
            try await cacheFailure(error, game: game, kind: "manifest", action: "open")
            cache = nil
        }
        var result: [PlannedCategory] = []
        for category in categories {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let name: String
            if let safe = try? SafeIdentifier(category.manifest.id) { name = safe.rawValue }
            else {
                // Delivery IDs are opaque (including separators); cache only a
                // stable leaf, never a path supplied by delivery metadata.
                var hash = StreamingHasher(.sha256); hash.update(Data(category.manifest.id.utf8))
                // Percent is valid in SafeRelativePath but forbidden in SafeIdentifier,
                // keeping opaque IDs disjoint from normal manifest filenames.
                name = "%sha256-" + hash.finalize().hex
            }
            let path = try SafeRelativePath("\(name).zst")
            if let cache {
                do {
                    if try cache.itemType(at: path) != nil {
                        let bytes = try cache.readFile(at: path, maxBytes: Int(category.manifest.compressedSize))
                        let manifest = try DeliveryAPI.decodeManifest(bytes, ref: category.manifest)
                        result.append(PlannedCategory(category: category, manifest: manifest)); continue
                    }
                } catch {
                    try await cacheFailure(error, game: game, kind: "manifest", action: "read")
                    // A bad cache is disposable; failure to remove it must not
                    // prevent a verified network response from being used.
                    try? cache.removeFile(at: path)
                }
            }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let fetched = try await api.manifest(category)
            if let cache {
                do {
                    try cache.writeCacheAtomically(fetched.compressed, to: path)
                } catch {
                    try await cacheFailure(error, game: game, kind: "manifest", action: "write")
                }
            }
            result.append(PlannedCategory(category: category, manifest: fetched.manifest))
        }
        return result
    }

    private func cacheFailure(_ error: any Error, game: GameDefinition, kind: String, action: String) async throws {
        if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled {
            throw LauncherError.cancelled
        }
        // Cache errors can carry paths, URLs or selectors. Log only fixed fields.
        await log?.log(.warning, "game-library", "Metadata cache unavailable",
            metadata: ["game": game.id, "cache": kind, "action": action])
    }

    private func checkNewLocation(_ location: URL, records: [String: GameRecord], game: GameDefinition, empty: Bool) throws {
        try requireGameLocationAvailable(location)
        try checkLocation(location, records: records, game: game)
        if empty { try GameRecordRules.checkInstallFolder(location) }
    }
    private func checkLocation(_ location: URL, records: [String: GameRecord], game: GameDefinition) throws {
        try GameRecordRules.checkLocation(location, others: others(records, game), reserved: [paths.root, paths.runtimes])
    }
    private func others(_ records: [String: GameRecord], _ game: GameDefinition) -> [GameRecord] { records.filter { $0.key != game.id }.map(\.value) }

}

private struct LibraryTarget: Sendable {
    let build: InstalledBuild
    let categories: [PlannedCategory]
    var managedPaths: Set<SafeRelativePath> { Set(categories.flatMap { $0.manifest.files.map(\.path) }) }
}
fileprivate struct LibraryPrepared: Sendable { let lease: GameOperationLease; let stream: AsyncThrowingStream<OperationEvent, any Error> }
fileprivate enum LibraryRequest: Sendable {
    case install(Set<String>, URL, Bool), adopt(Set<String>, URL), update(Bool), resume(Bool), verify(Verifier.Mode), voices(Set<String>)
    var action: GameAction {
        switch self { case .install: .install; case .adopt: .adopt; case .update: .update; case .resume: .resume; case .verify: .repair; case .voices: .voices }
    }
}
private actor LibrarySession {
    let owner: GameLibrary; let game: GameDefinition; let request: LibraryRequest
    var lease: GameOperationLease?
    var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    var prepared = false, done = false, pulling = false
    init(owner: GameLibrary, game: GameDefinition, request: LibraryRequest) { self.owner = owner; self.game = game; self.request = request }
    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("game stream already in use") }
        pulling = true; defer { pulling = false }
        if done { return nil }
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if !prepared {
                let value = try await owner.prepare(game, request: request)
                lease = value.lease; iterator = value.stream.makeAsyncIterator(); prepared = true
            }
            guard var current = iterator else { throw LauncherError.io("missing library stream") }
            iterator = nil; let event = try await current.next(isolation: self); iterator = current
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if event == nil || event == .phase(.completed) { done = true; iterator = nil; lease = nil }
            return event
        } catch { done = true; iterator = nil; lease = nil; throw error }
    }
}
private actor VerificationStream {
    var builder: (@Sendable () async throws -> AsyncThrowingStream<OperationEvent, any Error>)?
    var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    var first = true
    init(_ builder: @escaping @Sendable () async throws -> AsyncThrowingStream<OperationEvent, any Error>) { self.builder = builder }
    func next() async throws -> OperationEvent? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if first { first = false; return .phase(.verifying) }
        if let builder { iterator = try await builder().makeAsyncIterator(); self.builder = nil }
        guard var current = iterator else { return nil }
        iterator = nil; let event = try await current.next(isolation: self); iterator = current; return event
    }
}
private func verification(_ builder: @escaping @Sendable () async throws -> AsyncThrowingStream<OperationEvent, any Error>) -> AsyncThrowingStream<OperationEvent, any Error> {
    let session = VerificationStream(builder); return AsyncThrowingStream(unfolding: { try await session.next() })
}
private func planID(_ game: GameDefinition, kind: PendingOperation.Kind, build: InstalledBuild,
    categories: [PlannedCategory], repaired: [SafeRelativePath] = []) throws -> SafeIdentifier {
    let ids = categories.map(\.category.id).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let paths = repaired.map(\.description).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var hash = StreamingHasher(.sha256); hash.update(try encoder.encode(["categories": ids, "paths": paths]))
    let suffix = hash.finalize().hex.prefix(12)
    let candidate = "\(game.id)-\(kind.rawValue)-\(build.buildID)-\(suffix)"
    if let safe = try? SafeIdentifier(candidate) { return safe }
    // Delivery build IDs are opaque. Preserve ordinary IDs, but represent an
    // unsafe or overlong ID by a stable digest within the bounded identifier.
    var buildHash = StreamingHasher(.sha256); buildHash.update(Data(build.buildID.utf8))
    return try SafeIdentifier("\(game.id)-\(kind.rawValue)-sha256-\(buildHash.finalize().hex)-\(suffix)")
}
