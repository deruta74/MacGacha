// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
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
