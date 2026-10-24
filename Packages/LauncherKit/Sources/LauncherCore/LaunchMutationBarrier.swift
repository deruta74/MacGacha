// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Presence, not successful decoding, establishes outstanding launch ownership.
/// Call under game session exclusion or exclusive runtime component pins.
public enum LaunchMutationBarrier {
    public static func requireNoJournal(paths: AppPaths, game: String) throws {
        do {
            let fs = try ContainedFileSystem(root: paths.root)
            let path = try SafeRelativePath("Games/\(SafeIdentifier(game).rawValue)/launch-session.json")
            guard try fs.itemType(at: path, allowingLeafSymlink: true) == nil else {
                throw LauncherError.busy("Launch recovery is required")
            }
        } catch { throw LauncherError.busy("Launch recovery is required") }
    }
    public static func requireNoJournals(paths: AppPaths) throws {
        do {
            let fs = try ContainedFileSystem(root: paths.root)
            guard try fs.itemType(at: SafeRelativePath("Games")) != nil else { return }
            for entry in try fs.contentsOfDirectory(at: SafeRelativePath("Games")) {
                guard try fs.itemType(at: entry, allowingLeafSymlink: true) == .directory else {
                    // Ordinary operation lock files are not game directories.
                    if try fs.itemType(at: entry, allowingLeafSymlink: true) == .regularFile { continue }
                    throw LauncherError.busy("Launch recovery is required")
                }
                try requireNoJournal(paths: paths, game: entry.components.last!)
            }
        } catch { throw LauncherError.busy("Launch recovery is required") }
    }
}
