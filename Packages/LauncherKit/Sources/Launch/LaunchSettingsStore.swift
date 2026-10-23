// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary

/// Synchronous filesystem I/O: async callers must use BlockingIO.run.
public struct LaunchSettingsStore: Sendable {
    private static let maximumBytes = 65_536
    private let paths: AppPaths
    private let fileOps: any FileOps
    public init(paths: AppPaths) { self.init(paths: paths, fileOps: SystemFileOps()) }
    init(paths: AppPaths, fileOps: any FileOps) { self.paths = paths; self.fileOps = fileOps }
    public func load(_ game: String) throws -> LaunchSettings {
        let path = try relativePath(for: game)
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard try fs.itemType(at: path) != nil else { return .defaults(for: game) }
        let data = try fs.readFile(at: path, maxBytes: Self.maximumBytes)
        let decoder = JSONDecoder(); decoder.userInfo[LaunchSettings.gameKey] = game
        do { return try decoder.decode(LaunchSettings.self, from: data) }
        catch { throw LauncherError.io("Invalid launch settings for \(game)") }
    }

    public func save(_ settings: LaunchSettings, for game: String) throws {
        let path = try relativePath(for: game)
        try settings.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        try fs.createRootDurably()
        try fs.createDirectory(at: SafeRelativePath("Games"))
        // Operation recovery sweeps atomic-write siblings. Share its ownership
        // for this short write so it cannot unlink a live settings temporary.
        let games = try ContainedFileSystem(root: paths.games, fileOps: fileOps)
        let lease = try GameOperationLease.acquire(fs: games)
        defer { withExtendedLifetime(lease) {} }
        try fs.writeAtomically(data, to: path)
    }

    private func relativePath(for game: String) throws -> SafeRelativePath {
        _ = try SafeIdentifier(game)
        guard Recipes.recipe(for: game) != nil else { throw LauncherError.io("Unknown launch game: \(game)") }
        return try SafeRelativePath("Games/\(game)/launch-settings.json")
    }
}
