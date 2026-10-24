// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import DownloadEngine
import RuntimeManager

/// Cross-process ownership of one game's launch session. Retain through restore,
/// including recoveryPending. Acquire on BlockingIO; lock files are never unlinked.
public final class SessionLock: Sendable {
    private let lock: InstallLock
    private init(_ lock: InstallLock) { self.lock = lock }

    public static func acquire(paths: AppPaths, game: String) throws -> SessionLock {
        let id = try SafeIdentifier(game)
        let fs = try ContainedFileSystem(root: paths.root)
        return try SessionLock(InstallLock(fs: fs, path: SafeRelativePath("Games/\(id)/.session.lock")))
    }
}

/// Shared component pins keep removal excluded for the session's lifetime.
/// Acquire on BlockingIO. Deinit releases all pins; process death releases them
/// in the kernel. No lock pathname is removed, so every holder uses the same inode.
public final class RuntimePin: Sendable {
    private let locks: [InstallLock]
    private init(_ locks: [InstallLock]) { self.locks = locks }

    public static func pin(paths: AppPaths, componentIDs: [String]) throws -> RuntimePin {
        try RuntimePin(RuntimeStore.componentLocks(paths: paths, componentIDs: componentIDs, mode: .shared))
    }
}
