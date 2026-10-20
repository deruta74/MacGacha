// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// Hold one shared install-root lock path for the operation's lifetime. Explicitly
/// unlock before closing: a concurrent spawn can temporarily retain the open-file
/// description even with CLOEXEC. Retain the lock file so its inode stays stable.
public final class InstallLock: Sendable {
    private let handle: FileHandle

    public init(fs: ContainedFileSystem, path: SafeRelativePath) throws {
        let opened = try fs.openForWriting(at: path, truncate: false)
        do {
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if flock(opened.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { break }
                if errno == EWOULDBLOCK || errno == EAGAIN { throw LauncherError.busy("install root in use") }
                guard errno == EINTR else { throw LauncherError.io("Cannot lock install root") }
            }
        } catch { try? opened.close(); throw error }
        handle = opened
    }

    deinit {
        // flock belongs to the shared open-file description, not just this descriptor.
        // Closing alone can leave it held until a concurrent posix_spawn reaches exec.
        while flock(handle.fileDescriptor, LOCK_UN) != 0 {
            if errno != EINTR { break }
        }
        try? handle.close()
    }
}
