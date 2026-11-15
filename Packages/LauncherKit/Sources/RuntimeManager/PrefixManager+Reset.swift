// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

extension PrefixManager {
    /// Caller retains session exclusion, component pins and the durable journal barrier.
    /// Inspect and lock the complete set before removing anything, including legacy prefixes.
    package func resetPrefixes(game: String) throws -> Int {
        _ = try SafeIdentifier(game)
        guard GameDefinition.find(game) != nil else { throw LauncherError.io("Unknown game edition") }
        let fs = try ContainedFileSystem(root: paths.root)
        guard try fs.itemType(at: SafeRelativePath("Prefixes")) != nil else { return 0 }
        let candidates = try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).filter { path in
            let name = path.components.last!
            // Longest registered edition wins, so genshin never owns genshin-cn's prefixes.
            return GameDefinition.all.sorted { $0.id.count > $1.id.count }.first { name.hasPrefix($0.id + "-") }?.id == game
        }.sorted { $0.description < $1.description }
        let locks = try candidates.map { path in
            try InstallLock(fs: fs, path: SafeRelativePath("Prefixes/.macgacha-prefix-\(path.components.last!).lock"))
        }
        defer { withExtendedLifetime(locks) {} }
        for path in candidates {
            try Task.checkCancellation()
            guard let prefix = try fs.pinDirectoryIfPresent(at: path) else { throw LauncherError.io("Prefix is missing") }
            try PrefixShellFolders.requireIdle(prefix: path.resolved(against: paths.root), prefixFS: prefix,
                wineBinary: paths.runtimes.appendingPathComponent("bin/wine"), runtimeRoot: paths.runtimes,
                inspector: inspector, serverProbe: serverProbe)
        }
        try Task.checkCancellation()
        for path in candidates { try fs.removeItem(at: path) }
        return candidates.count
    }
}
