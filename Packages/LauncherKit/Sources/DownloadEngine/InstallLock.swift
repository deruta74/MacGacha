// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import LauncherCore

/// Hold one shared install-root lock path for the operation's lifetime. Explicitly
/// unlock before closing: a concurrent spawn can temporarily retain the open-file
/// description even with CLOEXEC. Retain the lock file so its inode stays stable.
public final class InstallLock: Sendable {
    public enum Mode: Sendable { case exclusive, shared }
    private let handle: Mutex<FileHandle?>

    /// Attempts and pause for short-lived locks that are better waited for than refused,
    /// such as the runtime store lock: about 10 seconds in total.
    public static let shortWaitRetries = 200
    public static let shortWaitPause: @Sendable () -> Void = { usleep(50_000) }

    /// `retries` re-attempts a lock held elsewhere, calling `pause` between attempts.
    /// Only call with retries from a thread that may block (BlockingIO), never a cooperative one.
    public init(fs: ContainedFileSystem, path: SafeRelativePath, mode: Mode = .exclusive,
        retries: Int = 0, pause: () -> Void = InstallLock.shortWaitPause) throws {
        let opened = try fs.openForWriting(at: path, truncate: false)
        var remaining = retries
        do {
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if flock(opened.fileDescriptor, (mode == .exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { break }
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    guard remaining > 0 else { throw LauncherError.busy("install root in use") }
                    remaining -= 1; pause(); continue
                }
                guard errno == EINTR else { throw LauncherError.io("Cannot lock install root") }
            }
        } catch { try? opened.close(); throw error }
        handle = Mutex(opened)
    }

    /// Ownership barriers must unlock before publishing completion, even if
    /// references to this wrapper outlive the barrier. Repeated release is inert.
    package func release() {
        handle.withLock { value in
            guard let opened = value else { return }
            // flock belongs to the shared open-file description, not just this descriptor.
            // Closing alone can leave it held until a concurrent posix_spawn reaches exec.
            while flock(opened.fileDescriptor, LOCK_UN) != 0 {
                if errno != EINTR { break }
            }
            try? opened.close()
            value = nil
        }
    }

    deinit { release() }
}
