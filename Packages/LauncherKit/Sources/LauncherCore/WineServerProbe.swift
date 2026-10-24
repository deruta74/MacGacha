// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Wine keys its server by prefix device/inode, independently of WINEPREFIX's
/// spelling. A stale server directory is harmless; uncertainty never proves idle.
package struct WineServerProbe: Sendable {
    private let root: URL
    package init(root: URL? = nil) {
        self.root = root ?? URL(fileURLWithPath: "/private/tmp/.wine-\(geteuid())", isDirectory: true)
    }

    package static func directoryName(for prefix: ContainedFileSystem) throws -> SafeRelativePath {
        try prefix.withRootDirectoryDescriptor { fd in
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw LauncherError.io("Cannot inspect Wine prefix identity") }
            return try SafeRelativePath("server-\(String(UInt64(truncatingIfNeeded: info.st_dev), radix: 16))-\(String(info.st_ino, radix: 16))")
        }
    }

    package func isIdle(prefix: ContainedFileSystem) throws -> Bool {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let name = try Self.directoryName(for: prefix)
        guard let base = try ContainedFileSystem(root: root).pinRootIfPresent() else { return true }
        try base.withRootDirectoryDescriptor { try Self.requirePrivateDirectory($0) }
        guard let server = try base.pinDirectoryIfPresent(at: name) else { return true }
        return try server.withRootDirectoryDescriptor { directory in
            try Self.requirePrivateDirectory(directory)
            if let expected = try Self.entry("lock", in: directory) {
                guard expected.st_mode & S_IFMT == S_IFREG, expected.st_uid == geteuid() else { throw Self.uncertain }
                let fd = openat(directory, "lock", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else {
                    if errno == ENOENT { return try Self.socketIsIdle(in: directory) }
                    throw Self.uncertain
                }
                defer { close(fd) }
                var actual = stat(), record = flock()
                guard fstat(fd, &actual) == 0, actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
                    actual.st_mode & S_IFMT == S_IFREG, actual.st_uid == geteuid() else { throw Self.uncertain }
                record.l_type = Int16(F_WRLCK); record.l_whence = Int16(SEEK_SET)
                guard fcntl(fd, F_GETLK, &record) == 0 else { throw Self.uncertain }
                if record.l_type != Int16(F_UNLCK) { return false }
                // Do not accept an unlocked replacement for a lock we inspected.
                if let current = try Self.entry("lock", in: directory) {
                    guard current.st_dev == actual.st_dev, current.st_ino == actual.st_ino else { throw Self.uncertain }
                }
            }
            return try Self.socketIsIdle(in: directory)
        }
    }

    private static var uncertain: LauncherError { .io("Cannot inspect Wine server ownership") }
    private static func requirePrivateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw uncertain }
    }

    private static func entry(_ name: String, in directory: Int32) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw uncertain
    }

    private static func socketIsIdle(in directory: Int32) throws -> Bool {
        guard let info = try entry("socket", in: directory) else { return true }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw uncertain }
        // Darwin has no connectat. Use the pinned directory's kernel path after
        // no-follow inspection; the private namespace admits only our Wine server.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard path.withUnsafeMutableBufferPointer({ fcntl(directory, F_GETPATH, $0.baseAddress!) }) == 0 else { throw uncertain }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) } + Array("/socket".utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw uncertain }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw uncertain }
        defer { close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw uncertain }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return false }
        // A stale socket has no listener. All other failures (including a full
        // backlog or an in-progress connection) remain conservatively busy.
        if errno == ENOENT || errno == ECONNREFUSED { return true }
        throw uncertain
    }
}
