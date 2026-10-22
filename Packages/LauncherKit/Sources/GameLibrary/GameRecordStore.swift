// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

/// Actor-isolated, bounded JSON persistence. All access below directory uses
/// descriptor-relative ContainedFileSystem operations, including cache creation.
public actor GameRecordStore {
    // Synchronous filesystem/cache work must not occupy a cooperative worker.
    nonisolated private let ioQueue = DispatchSerialQueue(label: "org.macgacha.game-store")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { ioQueue.asUnownedSerialExecutor() }

    public static let maximumRecordBytes = 4 << 20
    /// Shared by normal sweeping and orphan recovery. Younger cache siblings
    /// may belong to a lease-free writer, even while an operation owns the store.
    package static let cacheTemporarySafeAge: TimeInterval = 3600
    private static let cacheTemporaryPrefix = ".macgacha-cache-write-"
    private static let operationTemporaryPrefix = ".macgacha-write-"
    private let directory: URL
    private let fileOps: any FileOps
    public init(directory: URL, fileOps: any FileOps = SystemFileOps()) {
        self.directory = directory; self.fileOps = fileOps
    }

    /// The store directory's identity excludes other runners, including runners
    /// using another store instance or another pathname for the same directory.
    /// Retain the lease through record advancement and receipt acknowledgement.
    package func acquireOperationLease(waitForPipelineDrain: Bool = false) async throws -> GameOperationLease {
        let fs = try writableFilesystem()
        if waitForPipelineDrain { try await GameOperationLease.waitForPipelineDrain(fs: fs) }
        let lease = try GameOperationLease.acquire(fs: fs)
        do {
            for game in try gameDirectories() { try sweepInterruptedWrites(for: game, fs: fs) }
            return lease
        } catch { withExtendedLifetime(lease) {}; throw error }
    }

    public func load(_ game: String) throws -> GameRecord? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let path = try relative(game, "record.json")
        let fs = try filesystem()
        guard let type = try fs.itemType(at: path) else { return nil }
        guard type == .regularFile else { throw LauncherError.journalCorrupt("invalid game record") }
        let bytes: Data
        do { bytes = try fs.readFile(at: path, maxBytes: Self.maximumRecordBytes) }
        catch LauncherError.fileTooLarge { throw LauncherError.journalCorrupt("game record exceeds size limit") }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        do { return try JSONDecoder().decode(GameRecord.self, from: bytes) }
        catch { throw LauncherError.journalCorrupt("invalid game record") }
    }

    public func save(_ record: GameRecord, for game: String) throws {
        let path = try relative(game, "record.json")
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let bytes = try encoder().encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw LauncherError.io("game record exceeds size limit") }
        // Programmatic construction is allowed, but persistence enforces exactly
        // the same nested Codable invariants as a later load.
        do { _ = try JSONDecoder().decode(GameRecord.self, from: bytes) }
        catch { throw LauncherError.io("invalid game record") }
        try writableFilesystem().writeAtomically(bytes, to: path)
    }

    /// Removes only the record. Plans/cache remain available for reconciliation.
    public func delete(_ game: String) throws { try filesystem().removeFile(at: relative(game, "record.json")) }

    public func savePlan(_ plan: InstallPlan, for game: String) throws {
        let path = try relative(game, "pending-plan.json")
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try plan.validate()
        let data = try encoder().encode(plan)
        guard data.count <= InstallPlan.maximumEncodedBytes else {
            throw LauncherError.fileTooLarge(path: path.description, limit: InstallPlan.maximumEncodedBytes)
        }
        try writableFilesystem().writeAtomically(data, to: path)
    }

    public func loadPlan(for game: String) throws -> InstallPlan? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let path = try relative(game, "pending-plan.json")
        let fs = try filesystem()
        guard let type = try fs.itemType(at: path) else { return nil }
        guard type == .regularFile else { throw LauncherError.journalCorrupt("invalid pending plan") }
        // fstat and the byte limit precede allocation/JSON decoding.
        let data = try fs.readFile(at: path, maxBytes: InstallPlan.maximumEncodedBytes)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        do {
            let plan = try JSONDecoder().decode(InstallPlan.self, from: data)
            try plan.validate()
            return plan
        } catch { throw LauncherError.journalCorrupt("invalid pending plan") }
    }

    public func deletePlan(for game: String) throws { try filesystem().removeFile(at: relative(game, "pending-plan.json")) }

    /// Creates/checks the cache through the trusted games root before returning
    /// its URL. Throws for invalid identifiers or symlinked game/cache directories.
    public func manifestCache(for game: String) throws -> URL {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let path = try relative(game, "manifests")
        try writableFilesystem().createDirectory(at: path)
        return path.resolved(against: directory)
    }

    /// Includes directories with only an orphan plan, so startup reconciliation
    /// can finish an interrupted first record write.
    package func gameDirectories() throws -> [String] {
        let fs = try filesystem()
        var result: [String] = []
        for path in try fs.contentsOfRootDirectory() {
            let game = path.description
            guard !game.hasPrefix(".") else { continue }
            guard (try? SafeIdentifier(game)) != nil, try fs.itemType(at: path) == .directory else {
                throw LauncherError.journalCorrupt("invalid game directory")
            }
            result.append(game)
        }
        return result
    }
    package func records() throws -> [String: GameRecord] {
        var result: [String: GameRecord] = [:]
        for game in try gameDirectories() {
            if let record = try load(game) { result[game] = record }
        }
        return result
    }
    public static let maximumManagedPathBytes = 64 << 20
    private static let maximumManagedPaths = 400_000

    /// Save the complete target set before publishing pending. Entries are keyed
    /// by build so a crash between metadata and record writes cannot grant paths
    /// from a target which the record has not yet claimed.
    package func prepareManagedPaths(_ paths: Set<SafeRelativePath>, target: InstalledBuild,
        record: GameRecord, for game: String) throws {
        var entries = try loadManagedEntries(for: game) ?? []
        entries = entries.filter { $0.build == record.installed && $0.build != target }
        entries.append(ManagedPathEntry(build: target, paths: paths.sorted { $0.description < $1.description }))
        try saveManagedEntries(entries, for: game)
    }

    package func managedPaths(for game: String, record: GameRecord) throws -> Set<SafeRelativePath> {
        guard let entries = try loadManagedEntries(for: game) else { throw LauncherError.journalCorrupt("missing managed paths") }
        var paths = Set<SafeRelativePath>()
        for build in [record.installed, record.pending?.target].compactMap({ $0 }) {
            guard let entry = entries.first(where: { $0.build == build }) else { throw LauncherError.journalCorrupt("missing managed paths") }
            paths.formUnion(entry.paths)
        }
        return paths
    }

    package func completeManagedPaths(record: GameRecord, for game: String) throws {
        guard let installed = record.installed else { return }
        guard let entries = try loadManagedEntries(for: game),
            let entry = entries.first(where: { $0.build == installed }) else { throw LauncherError.journalCorrupt("missing managed paths") }
        try saveManagedEntries([entry], for: game)
    }

    package func deleteGameDirectory(_ game: String) throws {
        try filesystem().removeEmptyDirectory(at: SafeRelativePath(SafeIdentifier(game).rawValue))
    }

    /// No record means no operation owns the directory. Retire only bounded,
    /// recognized launcher metadata; never recursively remove an unknown entry.
    package func cleanupOrphanGameDirectory(_ game: String) throws {
        guard try load(game) == nil else { throw LauncherError.busy("game record changed") }
        let fs = try filesystem(), directory = try SafeRelativePath(SafeIdentifier(game).rawValue)
        guard try fs.itemType(at: directory) != nil else { return }
        let paths = try fs.contentsOfDirectory(at: directory)
        // Cache siblings have their own bounded directory-enumeration limit;
        // young recognized names must not prevent retiring other orphan state.
        guard paths.lazy.filter({ !Self.isTemporary($0, prefix: Self.cacheTemporaryPrefix) }).count <= 64 else {
            throw LauncherError.journalCorrupt("too many game metadata entries")
        }
        let cutoff = Date().addingTimeInterval(-Self.cacheTemporarySafeAge)
        let files: Set<String> = ["pending-plan.json", "branch.json", "managed-paths.json", "uninstall-cleaned.json"]
        var removable: [SafeRelativePath] = []
        for path in paths {
            if Self.isTemporary(path, prefix: Self.cacheTemporaryPrefix) {
                if try cacheTemporaryIsExpired(path, fs: fs, cutoff: cutoff) { removable.append(path) }
                continue
            }
            let name = path.components.last!, type = try fs.itemType(at: path)
            guard (name == "manifests" && type == .directory) ||
                ((files.contains(name) || Self.isTemporary(path, prefix: Self.operationTemporaryPrefix)) && type == .regularFile) else {
                throw LauncherError.journalCorrupt("unexpected game metadata")
            }
            removable.append(path)
        }
        for path in removable {
            if path.components.last == "manifests" {
                // Manifest cache writers use the same age policy. Keep their
                // young siblings and parent while retiring other cached entries.
                for child in try fs.contentsOfDirectory(at: path) {
                    if Self.isTemporary(child, prefix: Self.cacheTemporaryPrefix) {
                        if try cacheTemporaryIsExpired(child, fs: fs, cutoff: cutoff) { try fs.removeFile(at: child) }
                    } else { try fs.removeItem(at: child) }
                }
                try fs.removeEmptyDirectory(at: path)
            } else { try fs.removeFile(at: path) }
        }
        // A young cache sibling can deliberately keep this directory nonempty.
        try fs.removeEmptyDirectory(at: directory)
    }

    private func loadManagedEntries(for game: String) throws -> [ManagedPathEntry]? {
        let bytes: Data
        do {
            guard let data = try readState("managed-paths.json", for: game, maxBytes: Self.maximumManagedPathBytes) else { return nil }
            bytes = data
        } catch LauncherError.fileTooLarge { throw LauncherError.journalCorrupt("managed paths exceed size limit") }
        do {
            let entries = try JSONDecoder().decode([ManagedPathEntry].self, from: bytes)
            guard entries.count <= 2, entries.reduce(0, { $0 + $1.paths.count }) <= Self.maximumManagedPaths,
                entries.allSatisfy({ Set($0.paths).count == $0.paths.count }) else {
                throw LauncherError.journalCorrupt("invalid managed paths")
            }
            return entries
        } catch { throw LauncherError.journalCorrupt("invalid managed paths") }
    }
    private func saveManagedEntries(_ entries: [ManagedPathEntry], for game: String) throws {
        guard entries.count <= 2, entries.reduce(0, { $0 + $1.paths.count }) <= Self.maximumManagedPaths else {
            throw LauncherError.io("too many managed paths")
        }
        let bytes = try encoder().encode(entries)
        guard bytes.count <= Self.maximumManagedPathBytes else { throw LauncherError.fileTooLarge(path: "managed-paths.json", limit: Self.maximumManagedPathBytes) }
        try writableFilesystem().writeAtomically(bytes, to: relative(game, "managed-paths.json"))
    }

    package func readState(_ name: String, for game: String, maxBytes: Int) throws -> Data? {
        _ = try SafeIdentifier(name)
        let path = try relative(game, name); let fs = try filesystem()
        guard try fs.itemType(at: path) != nil else { return nil }
        return try fs.readFile(at: path, maxBytes: maxBytes)
    }
    package func writeState(_ data: Data, named name: String, for game: String) throws {
        _ = try SafeIdentifier(name)
        guard data.count <= InstallPlan.maximumEncodedBytes else { throw LauncherError.fileTooLarge(path: name, limit: InstallPlan.maximumEncodedBytes) }
        try writableFilesystem().writeAtomically(data, to: relative(game, name))
    }
    /// Status and estimate persist caches without the operation lease. Only
    /// siblings older than cacheTemporarySafeAge are eligible for reclamation.
    package func writeCacheState(_ data: Data, named name: String, for game: String) throws {
        _ = try SafeIdentifier(name)
        guard data.count <= InstallPlan.maximumEncodedBytes else { throw LauncherError.fileTooLarge(path: name, limit: InstallPlan.maximumEncodedBytes) }
        try writableFilesystem().writeCacheAtomically(data, to: relative(game, name))
    }
    package func deleteState(_ name: String, for game: String) throws {
        _ = try SafeIdentifier(name)
        try filesystem().removeFile(at: relative(game, name))
    }
    package func deleteManifestCache(for game: String) throws { try filesystem().removeItem(at: relative(game, "manifests")) }

    /// Called only with exclusive operation ownership. Never follow a temporary
    /// symlink or remove a similarly named foreign file.
    private func sweepInterruptedWrites(for game: String, fs: ContainedFileSystem) throws {
        let gamePath = try SafeRelativePath(SafeIdentifier(game).rawValue)
        let cachePath = try relative(game, "manifests")
        var directories = [gamePath]
        if try fs.itemType(at: cachePath, allowingLeafSymlink: true) == .directory { directories.append(cachePath) }
        let cutoff = Date().addingTimeInterval(-Self.cacheTemporarySafeAge)
        for directory in directories {
            for path in try fs.contentsOfDirectory(at: directory) {
                if Self.isTemporary(path, prefix: Self.cacheTemporaryPrefix) {
                    if try cacheTemporaryIsExpired(path, fs: fs, cutoff: cutoff) { try fs.removeFile(at: path) }
                } else if directory == gamePath, Self.isTemporary(path, prefix: Self.operationTemporaryPrefix),
                    try fs.itemType(at: path) == .regularFile {
                    try fs.removeFile(at: path)
                }
            }
        }
    }

    private static func isTemporary(_ path: SafeRelativePath, prefix: String) -> Bool {
        let name = path.components.last!
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix)?.uuidString.lowercased() == suffix.lowercased()
    }

    private func cacheTemporaryIsExpired(_ path: SafeRelativePath, fs: ContainedFileSystem, cutoff: Date) throws -> Bool {
        guard let date = try fs.modificationDate(at: path) else { return false }
        return date < cutoff
    }

    private func filesystem() throws -> ContainedFileSystem { try ContainedFileSystem(root: directory, fileOps: fileOps) }
    private func writableFilesystem() throws -> ContainedFileSystem {
        let fs = try filesystem()
        try fs.createRootDurably()
        return fs
    }
    private func relative(_ game: String, _ leaf: String) throws -> SafeRelativePath {
        let id = try SafeIdentifier(game)
        return try SafeRelativePath(id.rawValue + "/" + leaf)
    }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
}

/// Only active leases occupy the registry; filesystem work never holds its mutex.
package final class GameOperationLease: PipelineDrainOwner {
    private struct Registry {
        var active = Set<FileSystemIdentity>()
        var drains: [FileSystemIdentity: @Sendable () async throws -> Void] = [:]
    }
    private static let registry = Mutex(Registry())
    private let key: FileSystemIdentity
    private let lock: InstallLock
    private init(key: FileSystemIdentity, lock: InstallLock) { self.key = key; self.lock = lock }
    package func pipelineWillDrain(wait: @escaping @Sendable () async throws -> Void) {
        Self.registry.withLock { $0.drains[key] = wait }
    }
    fileprivate static func waitForPipelineDrain(fs: ContainedFileSystem) async throws {
        let key = try fs.rootIdentity()
        if let wait = registry.withLock({ $0.drains[key] }) { try await wait() }
    }
    fileprivate static func acquire(fs: ContainedFileSystem) throws -> GameOperationLease {
        let key = try fs.rootIdentity()
        guard registry.withLock({ $0.active.insert(key).inserted }) else {
            throw LauncherError.busy("another game operation is running")
        }
        do {
            let lock = try InstallLock(fs: fs, path: SafeRelativePath(".operation.lock"))
            return GameOperationLease(key: key, lock: lock)
        } catch {
            _ = registry.withLock { $0.active.remove(key) }
            if case LauncherError.busy = error { throw LauncherError.busy("another game operation is running") }
            throw error
        }
    }
    deinit {
        Self.registry.withLock { state in
            state.drains.removeValue(forKey: key); state.active.remove(key)
        }
    }
}

private struct ManagedPathEntry: Codable {
    let build: InstalledBuild
    let paths: [SafeRelativePath]
}
