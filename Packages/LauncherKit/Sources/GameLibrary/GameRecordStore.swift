// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

/// Actor-isolated, bounded JSON persistence. All access below directory uses
/// descriptor-relative ContainedFileSystem operations, including cache creation.
public actor GameRecordStore {
    public static let maximumRecordBytes = 4 << 20
    private let directory: URL
    private let fileOps: any FileOps
    public init(directory: URL, fileOps: any FileOps = SystemFileOps()) {
        self.directory = directory; self.fileOps = fileOps
    }

    /// The store directory's identity excludes other runners, including runners
    /// using another store instance or another pathname for the same directory.
    /// Retain the lease through record advancement and receipt acknowledgement.
    package func acquireOperationLease() throws -> GameOperationLease {
        let fs = try writableFilesystem()
        return try GameOperationLease.acquire(key: fs.rootIdentity())
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
        guard paths.count <= 64 else { throw LauncherError.journalCorrupt("too many game metadata entries") }
        let files: Set<String> = ["pending-plan.json", "branch.json", "managed-paths.json", "uninstall-cleaned.json"]
        for path in paths {
            let name = path.components.last!
            let temporary = name.hasPrefix(".macgacha-write-") && UUID(uuidString: String(name.dropFirst(".macgacha-write-".count))) != nil
            let type = try fs.itemType(at: path)
            guard (name == "manifests" && type == .directory) || ((files.contains(name) || temporary) && type == .regularFile) else {
                throw LauncherError.journalCorrupt("unexpected game metadata")
            }
        }
        for path in paths { try fs.removeItem(at: path) }
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
    package func deleteState(_ name: String, for game: String) throws {
        _ = try SafeIdentifier(name)
        try filesystem().removeFile(at: relative(game, name))
    }
    package func deleteManifestCache(for game: String) throws { try filesystem().removeItem(at: relative(game, "manifests")) }

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
package final class GameOperationLease: Sendable {
    private static let active = Mutex<Set<FileSystemIdentity>>([])
    private let key: FileSystemIdentity
    private init(key: FileSystemIdentity) { self.key = key }
    fileprivate static func acquire(key: FileSystemIdentity) throws -> GameOperationLease {
        guard active.withLock({ $0.insert(key).inserted }) else {
            throw LauncherError.busy("another game operation is running")
        }
        return GameOperationLease(key: key)
    }
    deinit { _ = Self.active.withLock { $0.remove(key) } }
}

private struct ManagedPathEntry: Codable {
    let build: InstalledBuild
    let paths: [SafeRelativePath]
}
