// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import os

/// Wine's host-folder links can cause TCC prompts attributed to the launcher.
/// Existing directories prevent shell32 from recreating those links on wineboot -u.
enum PrefixShellFolders {
    static let names = ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos"]
    static let registryValues = [
        ("Desktop", "Desktop"), ("Personal", "Documents"),
        ("{374DE290-123F-4565-9164-39C4925E467B}", "Downloads"),
        ("My Music", "Music"), ("My Pictures", "Pictures"), ("My Video", "Videos")
    ]
    static func validate(in fs: ContainedFileSystem) throws {
        _ = try profiles(in: fs)
    }

    private static func profiles(in fs: ContainedFileSystem) throws -> [ContainedFileSystem] {
        for ancestor in ["drive_c", "drive_c/users"] {
            guard try fs.itemType(at: SafeRelativePath(ancestor), allowingLeafSymlink: true) == .directory else {
                throw LauncherError.io("Prefix shell-folder ancestors must be real directories")
            }
        }
        // Validate every profile before modifying any folder. Pin each profile
        // so all leaf operations use its descriptor, never a link to a host home.
        return try fs.contentsOfDirectory(at: SafeRelativePath("drive_c/users")).map { path in
            guard try fs.itemType(at: path, allowingLeafSymlink: true) == .directory,
                  let profile = try fs.pinDirectoryIfPresent(at: path) else {
                throw LauncherError.io("Prefix user profiles must be real directories")
            }
            return profile
        }
    }

    static func isIdle(prefix: URL, prefixFS: ContainedFileSystem, wineBinary: URL, runtimeRoot: URL, inspector: any ProcessInspector, serverProbe: WineServerProbe) throws -> Bool {
        do {
            let noProcesses = try inspector.processes(environmentContains: "WINEPREFIX", value: prefix.path,
                scope: ProcessInspectionScope(executableRoots: [runtimeRoot, prefix,
                    wineBinary.deletingLastPathComponent().deletingLastPathComponent()])).isEmpty
            return try noProcesses && serverProbe.isIdle(prefix: prefixFS)
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw LauncherError.busy("Cannot verify that this Wine prefix is idle")
        }
    }

    static func requireIdle(prefix: URL, prefixFS: ContainedFileSystem, wineBinary: URL, runtimeRoot: URL, inspector: any ProcessInspector, serverProbe: WineServerProbe) throws {
        guard try isIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: wineBinary, runtimeRoot: runtimeRoot, inspector: inspector, serverProbe: serverProbe) else {
            throw LauncherError.busy("Wine is using this prefix")
        }
    }

    /// Caller holds prefix/session exclusion and has checked that Wine is absent.
    static func repair(in fs: ContainedFileSystem,
        log: @Sendable (String) -> Void = { Logger(subsystem: "com.lo7ted.macgacha", category: "Prefix").notice("\($0, privacy: .public)") }) throws {
        for profile in try profiles(in: fs) {
            for name in names {
                switch try profile.replaceDirectoryLink(at: SafeRelativePath(name)) {
                case .directory: break
                case .replaced: log("isolated \(name)")
                case .unexpected: log("skip \(name) (unexpected entry)")
                }
            }
        }
    }
}
