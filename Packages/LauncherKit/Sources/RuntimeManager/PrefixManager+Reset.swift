// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

extension PrefixManager {
    private static let retiredPrefixName = ".macgacha-retired-"

    /// Caller retains session exclusion, component pins and the durable journal barrier.
    /// Inspect and lock the complete set before removing anything, including legacy prefixes.
    package func resetPrefixes(game: String, fileOps: any FileOps = SystemFileOps()) throws -> Int {
        _ = try SafeIdentifier(game)
        guard GameDefinition.find(game) != nil else { throw LauncherError.io("Unknown game edition") }
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        guard try fs.itemType(at: SafeRelativePath("Prefixes")) != nil else { return 0 }
        let candidates = try Set(fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).compactMap { path -> SafeRelativePath? in
            let entry = path.components.last!
            let name = entry.hasPrefix(Self.retiredPrefixName) ? String(entry.dropFirst(Self.retiredPrefixName.count)) : entry
            // Longest registered edition wins, so genshin never owns genshin-cn's prefixes.
            guard GameDefinition.all.sorted(by: { $0.id.count > $1.id.count }).first(where: { name.hasPrefix($0.id + "-") })?.id == game else { return nil }
            return try SafeRelativePath("Prefixes/\(name)")
        }).sorted { $0.description < $1.description }
        let locks = try candidates.map { path in
            try InstallLock(fs: fs, path: SafeRelativePath("Prefixes/.macgacha-prefix-\(path.components.last!).lock"))
        }
        defer { withExtendedLifetime(locks) {} }
        for path in candidates {
            try Task.checkCancellation()
            try requireResetIdle(at: path, active: path, fs: fs)
            try requireResetIdle(at: Self.retiredPath(for: path), active: path, fs: fs)
        }
        try Task.checkCancellation()
        for path in candidates {
            let retired = try Self.retiredPath(for: path)
            try Self.removeRetiredPrefix(at: retired, fs: fs)
            if try fs.itemType(at: path) != nil {
                // Non-replacing rename and parent sync must finish before any recursive unlink.
                // A failed deletion can never leave a ready marker at the active prefix path.
                try fs.moveItem(at: path, to: retired)
                try fs.removeItem(at: retired)
            }
        }
        return candidates.count
    }

    /// Caller holds the original prefix lock, session exclusion and component pins.
    /// Run before reading readiness, including when a previous reset quit mid-deletion.
    func sweepRetiredPrefix(for active: SafeRelativePath, fs: ContainedFileSystem) throws {
        let retired = try Self.retiredPath(for: active)
        try requireResetIdle(at: retired, active: active, fs: fs)
        try Self.removeRetiredPrefix(at: retired, fs: fs)
    }

    private static func retiredPath(for active: SafeRelativePath) throws -> SafeRelativePath {
        try SafeRelativePath("Prefixes/\(retiredPrefixName)\(active.components.last!)")
    }

    private static func removeRetiredPrefix(at path: SafeRelativePath, fs: ContainedFileSystem) throws {
        guard try fs.itemType(at: path) != nil else { return }
        // A previous rename may have succeeded but failed its parent sync. Heal
        // that barrier before unlinking, so a crash cannot resurrect an active marker.
        try fs.synchronizeParentDirectory(of: path)
        try fs.removeItem(at: path)
    }

    private func requireResetIdle(at path: SafeRelativePath, active: SafeRelativePath, fs: ContainedFileSystem) throws {
        guard let prefix = try fs.pinDirectoryIfPresent(at: path) else { return }
        // Check the original WINEPREFIX as well as the retired path. Wine's server
        // namespace is checked against the same pinned inode after the rename.
        for processPath in active == path ? [active] : [active, path] {
            try PrefixShellFolders.requireIdle(prefix: processPath.resolved(against: paths.root), prefixFS: prefix,
                wineBinary: paths.runtimes.appendingPathComponent("bin/wine"), runtimeRoot: paths.runtimes,
                inspector: inspector, serverProbe: serverProbe)
        }
    }
}
