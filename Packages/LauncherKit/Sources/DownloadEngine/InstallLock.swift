// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// Hold one shared install-root lock path for the operation's lifetime. Closing the
/// descriptor releases the lock; the lock file is retained so its inode stays stable.
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

    deinit { try? handle.close() }
}
