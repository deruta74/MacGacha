// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import RuntimeManager
import GameLibrary

public enum StorageSize: Equatable, Sendable {
    case available(Int64), unavailable
    public var bytes: Int64? { if case .available(let bytes) = self { bytes } else { nil } }
}

public struct EditionStorage: Equatable, Sendable, Identifiable {
    public let id: String
    public let game: StorageSize
    public let prefixes: StorageSize
    public let preDownload: StorageSize
    public init(id: String, game: StorageSize, prefixes: StorageSize, preDownload: StorageSize) {
        self.id = id; self.game = game; self.prefixes = prefixes; self.preDownload = preDownload
    }
}

public struct StorageCleanupCandidate: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case orphanedPrefix, runtimeVersion, oldSessionLog, inactiveRegionCache
    }
    public let id: UUID
    public let kind: Kind
    public let bytes: Int64
    public let gameID: String?
    public let runtimeID: String?
    public let prefixIdentity: String?
    public let region: Region?
    // Only a fresh inventory can mint a deletion target. No public path API.
    let targets: [SafeRelativePath]
    let stamps: [ContainedFileSystem.ClaimStamp]
    let cache: Bool
}

public struct StorageSnapshot: Equatable, Sendable {
    public let editions: [EditionStorage]
    public let runtimes: StorageSize
    public let logs: StorageSize
    public let artCache: StorageSize
    public let eventsCache: StorageSize
    public let candidates: [StorageCleanupCandidate]
    public init(editions: [EditionStorage], runtimes: StorageSize, logs: StorageSize, artCache: StorageSize,
        eventsCache: StorageSize, candidates: [StorageCleanupCandidate]) {
        self.editions = editions; self.runtimes = runtimes; self.logs = logs
        self.artCache = artCache; self.eventsCache = eventsCache; self.candidates = candidates
    }
}

public struct StorageContext: Sendable {
    public let region: Region
    public let selectedRuntimeIDs: Set<String>
    public let prefixSelectionKnown: Bool
    public let pinnedRuntimeIDs: Set<String>
    public let manifest: RuntimeManifest?
    public let cacheDirectory: URL?
    public init(region: Region, selectedRuntimeIDs: Set<String> = [], prefixSelectionKnown: Bool = true, pinnedRuntimeIDs: Set<String> = [],
        manifest: RuntimeManifest? = nil, cacheDirectory: URL? = nil) {
        self.region = region; self.selectedRuntimeIDs = selectedRuntimeIDs; self.pinnedRuntimeIDs = pinnedRuntimeIDs
        self.prefixSelectionKnown = prefixSelectionKnown
        self.manifest = manifest; self.cacheDirectory = cacheDirectory
    }
}

/// Metadata-only inventory. All walks and guarded deletions stay on BlockingIO.
public protocol StorageServicing: Sendable {
    func refresh(_ context: StorageContext) async throws -> StorageSnapshot
    func cleanUp(_ item: StorageCleanupCandidate, context: StorageContext) async throws
    func validateRuntimeCandidate(_ item: StorageCleanupCandidate, context: StorageContext) async throws
}

public struct StorageInventory: StorageServicing {
    private let paths: AppPaths
    private let locationProbe: any GameLocationProbing
    public init(paths: AppPaths, locationProbe: any GameLocationProbing = SystemGameLocationProbe()) {
        self.paths = paths; self.locationProbe = locationProbe
    }

    public func refresh(_ context: StorageContext) async throws -> StorageSnapshot {
        try await BlockingIO.run { try scan(context) }
    }

    public func validateRuntimeCandidate(_ item: StorageCleanupCandidate, context: StorageContext) async throws {
        try await BlockingIO.run {
            guard item.kind == .runtimeVersion,
                try scan(context).candidates.contains(where: { $0.kind == item.kind && $0.targets == item.targets && $0.stamps == item.stamps }) else {
                throw LauncherError.busy("Runtime cleanup candidate changed")
            }
        }
    }

    private func scan(_ context: StorageContext, heldGame: String? = nil) throws -> StorageSnapshot {
        try Task.checkCancellation()
        let fs = try ContainedFileSystem(root: paths.root)
        let prefixes = try children(fs, "Prefixes")
        guard prefixes.count <= 4096 else { throw LauncherError.io("Storage prefix limit exceeded") }
        var candidates: [StorageCleanupCandidate] = [], editions: [EditionStorage] = []
        var installationRecords: [GameRecord] = [], recordsKnown = true
        let journalsClear = (try? LaunchMutationBarrier.requireNoJournals(paths: paths)) != nil
        var blockedGames: Set<String> = []
        for game in GameDefinition.all where game.id != heldGame {
            if try prefixes.contains(where: { prefixGame($0) == game.id }) || !oldLogs(game.id, fs: fs).isEmpty {
                do { let lock = try SessionLock.acquire(paths: paths, game: game.id); withExtendedLifetime(lock) {} }
                catch { if Task.isCancelled { throw error }; blockedGames.insert(game.id) }
            }
        }
        for game in GameDefinition.all {
            try Task.checkCancellation()
            var gameSize: StorageSize = .available(0), preDownload: StorageSize = .available(0)
            let record: GameRecord?
            do { record = try loadRecord(game.id, fs: fs) }
            catch {
                if Task.isCancelled { throw error }
                recordsKnown = false
                editions.append(.init(id: game.id, game: .unavailable, prefixes: .unavailable, preDownload: .unavailable))
                continue
            }
            if let record {
                installationRecords.append(record)
                do {
                    try locationProbe.requireAvailable(at: record.installPath)
                    let install = try ContainedFileSystem(root: record.installPath, expectedRootIdentity: record.installIdentity)
                    guard let pinned = try install.pinRootIfPresent() else { throw LauncherError.installVolumeUnavailable }
                    gameSize = try measure(pinned, excluding: [SafeRelativePath(".macgacha-predownload")])
                    preDownload = try measure(pinned, at: SafeRelativePath(".macgacha-predownload"))
                } catch {
                    if Task.isCancelled { throw error }
                    gameSize = .unavailable; preDownload = .unavailable
                }
            }
            let editionPrefixes = prefixes.filter { prefixGame($0) == game.id }
            let prefixSize: StorageSize
            do { prefixSize = .available(try fs.allocatedBytes(at: editionPrefixes)) }
            catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                prefixSize = .unavailable
            }
            for prefix in editionPrefixes {
                let suffix = String(prefix.components.last!.dropFirst(game.id.count + 1))
                let selected = context.selectedRuntimeIDs.contains(suffix) || ["d3dmetal", "dxmt"].contains(suffix)
                if journalsClear, !blockedGames.contains(game.id), record?.pending == nil, record?.uninstalling != true,
                    (record?.installed == nil || (context.prefixSelectionKnown && !selected)), !context.pinnedRuntimeIDs.contains(suffix),
                    try fs.itemType(at: prefix, allowingLeafSymlink: true) == .directory,
                    let bytes = try sum(fs, [prefix]), let candidate = try candidate(.orphanedPrefix, targets: [prefix], bytes: bytes,
                        fs: fs, game: game.id) { candidates.append(candidate) }
            }
            if journalsClear, !blockedGames.contains(game.id) {
                for log in try oldLogs(game.id, fs: fs) {
                    let targets = [try SafeRelativePath("Logs/\(log)"), try SafeRelativePath("Logs/\(log).macgacha-owner.json")]
                    if let bytes = try sum(fs, targets), let candidate = try candidate(.oldSessionLog,
                        targets: targets, bytes: bytes, fs: fs, game: game.id) { candidates.append(candidate) }
                }
            }
            editions.append(.init(id: game.id, game: gameSize,
                prefixes: prefixSize, preDownload: preDownload))
        }
        if journalsClear, let manifest = context.manifest {
            var protected = context.selectedRuntimeIDs.union(context.pinnedRuntimeIDs)
            // Legacy bundles run directly from their component directory. Their
            // selections and rollback pins protect components even without an
            // assembled tree, including during fresh removal validation.
            protected.formUnion(manifest.bundles.filter { protected.contains($0.id.rawValue) }
                .flatMap { $0.components.map(\.rawValue) })
            let store = RuntimeStore(paths: paths)
            let installed = try store.installed()
            // Bundle metadata is inspected by the caller's normal runtime scan.
            // Enumerate their contained directories without contacting a catalog.
            var bundleComponents: Set<SafeIdentifier> = []
            for bundle in manifest.bundles {
                let target = try SafeRelativePath("Runtimes/bundles/\(bundle.id)")
                guard try fs.itemType(at: target, allowingLeafSymlink: true) == .directory else { continue }
                bundleComponents.formUnion(bundle.components)
                guard !protected.contains(bundle.id.rawValue),
                    bundle.components.allSatisfy({ !protected.contains($0.rawValue) }),
                    removableComponents(bundle.components.map(\.rawValue)) else { continue }
                let shared = Set(manifest.bundles.filter { $0.id != bundle.id }.flatMap(\.components))
                let removed = manifest.components.filter { bundle.components.contains($0.id) && !shared.contains($0.id) }
                var targets = [target] + (try removed.map { try SafeRelativePath("Runtimes/\($0.kind.rawValue)/\($0.version)") })
                let helper = try SafeRelativePath("Runtimes/GameMode/\(bundle.id)")
                if try fs.itemType(at: helper, allowingLeafSymlink: true) != nil { targets.append(helper) }
                if let bytes = try sum(fs, targets), let item = try candidate(.runtimeVersion,
                    targets: targets, bytes: bytes, fs: fs, runtime: bundle.id.rawValue) { candidates.append(item) }
            }
            for component in installed {
                let id = "\(component.kind.idPrefix)-\(component.version)"
                guard !protected.contains(id), !bundleComponents.contains(try SafeIdentifier(id)), removableComponents([id]) else { continue }
                let target = try SafeRelativePath("Runtimes/\(component.kind.rawValue)/\(component.version)")
                if let bytes = try sum(fs, [target]), let item = try candidate(.runtimeVersion,
                    targets: [target], bytes: bytes, fs: fs, runtime: id) { candidates.append(item) }
            }
        }
        var art: StorageSize = .available(0), events: StorageSize = .available(0)
        if let root = context.cacheDirectory {
            let cacheFS = try ContainedFileSystem(root: root)
            art = try measure(cacheFS, at: SafeRelativePath("GameArt"))
            events = try measure(cacheFS, at: SafeRelativePath("GameEvents"))
            let inactive: Region = context.region == .global ? .mainlandChina : .global
            let targets = try inactiveCacheTargets(cacheFS, region: inactive)
            if let bytes = try sum(cacheFS, targets), bytes > 0,
                let item = try candidate(.inactiveRegionCache, targets: targets, bytes: bytes,
                    fs: cacheFS, region: inactive, cache: true) { candidates.append(item) }
        }
        try Task.checkCancellation()
        // Game locations are user-selected. Even a cache-named directory must
        // be retained if it overlaps a saved installation. Unknown records fail
        // closed rather than treating an unreadable installation as orphaned.
        candidates = recordsKnown ? try candidates.filter { item in
            let root = item.cache ? context.cacheDirectory : paths.root
            guard let root else { return false }
            do {
                for target in item.targets {
                    try GameRecordRules.requireStorageDisjoint(target.resolved(against: root), records: installationRecords)
                }
                return true
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                return false
            }
        } : []
        return .init(editions: editions, runtimes: try measure(fs, at: SafeRelativePath("Runtimes")),
            logs: try measure(fs, at: SafeRelativePath("Logs")), artCache: art, eventsCache: events, candidates: candidates)
    }

    public func cleanUp(_ item: StorageCleanupCandidate, context: StorageContext) async throws {
        try await BlockingIO.run {
            try Task.checkCancellation()
            guard item.kind != .runtimeVersion else { throw LauncherError.busy("Use the runtime removal service") }
            let root = item.cache ? context.cacheDirectory : paths.root
            guard let root else { throw LauncherError.busy("Storage target unavailable") }
            let fs = try ContainedFileSystem(root: root)
            let session = try item.gameID.map { try SessionLock.acquire(paths: paths, game: $0) }
            defer { withExtendedLifetime(session) {} }
            let lease = try await GameRecordStore(directory: paths.games).acquireOperationLease()
            defer { withExtendedLifetime(lease) {} }
            try LaunchMutationBarrier.requireNoJournals(paths: paths)
            // A fresh scan rechecks records, selection, newest-log retention and region.
            let current = try scan(context, heldGame: item.gameID)
            guard current.candidates.contains(where: { $0.kind == item.kind && $0.targets == item.targets && $0.stamps == item.stamps }) else {
                throw LauncherError.busy("Storage cleanup candidate changed")
            }
            try verify(item, fs: fs)
            switch item.kind {
            case .orphanedPrefix:
                let target = item.targets[0]
                let lock = try InstallLock(fs: fs, path: SafeRelativePath("Prefixes/.macgacha-prefix-\(target.components.last!).lock"))
                defer { withExtendedLifetime(lock) {} }
                try verify(item, fs: fs)
                try PrefixManager(paths: paths, runner: SystemProcessRunner()).removeStoragePrefix(at: target)
            case .oldSessionLog:
                guard let game = item.gameID, let logFS = try fs.pinDirectoryIfPresent(at: SafeRelativePath("Logs")) else {
                    throw LauncherError.busy("Session logs changed")
                }
                try SessionLog.removeOldStorageLog(fs: logFS, game: game, path: SafeRelativePath(item.targets[0].components.last!))
            case .inactiveRegionCache:
                guard item.region != context.region else { throw LauncherError.busy("Cache is active") }
                for target in item.targets { try Task.checkCancellation(); try fs.removeItem(at: target) }
            case .runtimeVersion: break
            }
        }
    }

    private func removableComponents(_ ids: [String]) -> Bool {
        do {
            let locks = try RuntimeStore.componentLocks(paths: paths, componentIDs: ids, mode: .exclusive)
            defer { withExtendedLifetime(locks) {} }
            try LaunchMutationBarrier.requireNoJournals(paths: paths)
            return true
        } catch { return false }
    }

    private func loadRecord(_ game: String, fs: ContainedFileSystem) throws -> GameRecord? {
        let path = try SafeRelativePath("Games/\(game)/record.json")
        guard try fs.itemType(at: path) != nil else { return nil }
        return try JSONDecoder().decode(GameRecord.self, from: fs.readFile(at: path, maxBytes: GameRecordStore.maximumRecordBytes))
    }
    private func prefixGame(_ path: SafeRelativePath) -> String? {
        GameDefinition.all.sorted { $0.id.count > $1.id.count }.first { path.components.last!.hasPrefix($0.id + "-") }?.id
    }
    private func children(_ fs: ContainedFileSystem, _ path: String) throws -> [SafeRelativePath] {
        let relative = try SafeRelativePath(path)
        guard try fs.itemType(at: relative) != nil else { return [] }
        return try fs.contentsOfDirectory(at: relative)
    }
    private func oldLogs(_ game: String, fs: ContainedFileSystem) throws -> [SafeRelativePath] {
        guard let logs = try fs.pinDirectoryIfPresent(at: SafeRelativePath("Logs")) else { return [] }
        return Array(try SessionLog.matchingLogs(fs: logs, game: game).dropFirst())
    }
    private func measure(_ fs: ContainedFileSystem, at path: SafeRelativePath? = nil,
        excluding: Set<SafeRelativePath> = []) throws -> StorageSize {
        do { return .available(try fs.allocatedBytes(at: path, excluding: excluding)) }
        catch { if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }; return .unavailable }
    }
    private func sum(_ fs: ContainedFileSystem, _ targets: [SafeRelativePath]) throws -> Int64? {
        do { return try fs.reclaimableAllocatedBytes(at: targets) }
        catch { if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }; return nil }
    }

    private func candidate(_ kind: StorageCleanupCandidate.Kind, targets: [SafeRelativePath], bytes: Int64,
        fs: ContainedFileSystem, game: String? = nil, runtime: String? = nil, region: Region? = nil,
        cache: Bool = false) throws -> StorageCleanupCandidate? {
        let stamps = try targets.compactMap { try fs.entryStamp(at: $0) }
        guard !targets.isEmpty, stamps.count == targets.count else { return nil }
        return .init(id: UUID(), kind: kind, bytes: bytes, gameID: game, runtimeID: runtime,
            prefixIdentity: kind == .orphanedPrefix ? targets.first?.components.last.map { String($0.dropFirst((game?.count ?? 0) + 1)) } : nil,
            region: region, targets: targets, stamps: stamps, cache: cache)
    }
    private func verify(_ item: StorageCleanupCandidate, fs: ContainedFileSystem) throws {
        for (path, stamp) in zip(item.targets, item.stamps) {
            guard try fs.entryStamp(at: path) == stamp else { throw LauncherError.busy("Storage target changed") }
        }
    }
    private func inactiveCacheTargets(_ fs: ContainedFileSystem, region: Region) throws -> [SafeRelativePath] {
        if region == .mainlandChina {
            return try [SafeRelativePath("GameArt/cn"), SafeRelativePath("GameEvents/cn")].filter { try fs.itemType(at: $0) == .directory }
        }
        let art = try children(fs, "GameArt").filter { $0.components.last != "cn" }
        let events = try children(fs, "GameEvents").filter { $0.components.last != "cn" }
        return art + events
    }
}
