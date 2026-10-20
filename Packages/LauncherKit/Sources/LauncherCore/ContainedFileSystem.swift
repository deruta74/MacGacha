// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Operations below a trusted root. Ancestors above the root may be symlinks.
/// The root itself must be a directory, not a symlink. Traversal is limited to
/// 128 directories and listing/removal to 100,000 entries per operation.
public struct ContainedFileSystem: Sendable, Hashable {
    public enum ItemType: Sendable, Equatable {
        case regularFile, directory, other
    }

    private let root: URL
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private static let entryLimit = 100_000

    public init(root: URL) throws {
        guard root.isFileURL, !root.path.isEmpty, !root.path.utf8.contains(0) else {
            throw LauncherError.unsafePath(root.absoluteString)
        }
        self.root = root
    }

    /// A conservative in-process reservation key, including the standardized root.
    /// This folds case even on case-sensitive volumes; it is never used for file access.
    package func caseFoldedPathKey(for path: SafeRelativePath) -> String {
        path.resolved(against: root.standardizedFileURL).path
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    package func availableBytes(using probe: any DiskSpaceProbe) throws -> Int64 {
        try probe.availableBytes(at: root)
    }

    /// Creates missing parent directories as well as the requested directory.
    public func createDirectory(at path: SafeRelativePath) throws {
        guard let fd = try directory(path.components, create: true) else { throw LauncherError.io("Cannot create directory") }
        close(fd)
    }

    /// Atomically renames a regular file, optionally replacing another regular file.
    /// Both parents are traversed without following symlinks and fsynced after rename.
    public func rename(from source: SafeRelativePath, to destination: SafeRelativePath) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Rename source is missing")
        }
        defer { close(parent) }
        let sourceName = source.components.last!
        guard let info = try entry(sourceName, parent: parent), info.st_mode & S_IFMT == S_IFREG else {
            throw LauncherError.unsafePath(display(source.components))
        }
        guard let target = try directory(Array(destination.components.dropLast()), create: true) else {
            throw LauncherError.io("Rename destination is missing")
        }
        defer { close(target) }
        let targetName = destination.components.last!
        try checkRegularDestination(targetName, parent: target, display: display(destination.components))
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard renameat(parent, sourceName, target, targetName) == 0 else { throw accessError(display(destination.components)) }
        try synchronize(parent)
        try synchronize(target)
    }

    /// The descriptor is borrowed for this call only. Durable synchronization requests
    /// F_FULLFSYNC rather than fsync. Injection must preserve that synchronization contract.
    public typealias FileSynchronizer = @Sendable (_ descriptor: Int32, _ durable: Bool) throws -> Void

    public static func synchronizeFileDescriptor(_ descriptor: Int32, durable: Bool) throws {
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let result = durable ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)
            if result == 0 { return }
            guard errno == EINTR else { throw LauncherError.io("Cannot synchronize file") }
        }
    }

    /// Appends to a regular file (creating missing parents and the file), then synchronizes it.
    /// Refuses symlinks and hard-linked writable files. A failed write may leave a partial append;
    /// callers must repair it before writing again. The containing directory is also fsynced.
    public func append(_ data: Data, to path: SafeRelativePath, durable: Bool = false,
        synchronize: FileSynchronizer = ContainedFileSystem.synchronizeFileDescriptor) throws {
        try withRegularDescriptor(at: path, writing: true, create: true) { fd, parent, _ in
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    let count = Darwin.write(fd, base.advanced(by: written), min(65_536, bytes.count - written))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw LauncherError.io("Cannot append contained file") }
                    written += count
                }
            }
            try synchronize(fd, durable)
            try self.synchronize(parent)
        }
    }

    /// Shrinks an existing regular file without extending it, then fsyncs it.
    public func truncateFile(at path: SafeRelativePath, toByteCount count: Int64,
        synchronize: FileSynchronizer = ContainedFileSystem.synchronizeFileDescriptor) throws {
        guard count >= 0 else { throw LauncherError.io("Invalid truncation length") }
        try withRegularDescriptor(at: path, writing: true, create: false) { fd, _, info in
            guard count <= info.st_size else { throw LauncherError.io("Invalid truncation length") }
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if ftruncate(fd, count) == 0 { break }
                guard errno == EINTR else { throw LauncherError.io("Cannot truncate contained file") }
            }
            try synchronize(fd, false)
        }
    }

    /// Streams a snapshot of a regular file's initial size in chunks of at most 1 MiB.
    /// Does not wait for EOF on a file being appended to. The callback is synchronous.
    public func readFile(at path: SafeRelativePath, chunkSize: Int = 65_536,
        consume: (Data) throws -> Void) throws {
        guard (1...1_048_576).contains(chunkSize) else { throw LauncherError.io("Invalid read chunk size") }
        try withRegularDescriptor(at: path, writing: false, create: false) { fd, _, info in
            var remaining = info.st_size
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while remaining > 0 {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress, Int(min(Int64(chunkSize), remaining)))
                }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LauncherError.io("Cannot read contained file") }
                if count == 0 { break }
                try consume(Data(buffer.prefix(count)))
                remaining -= Int64(count)
            }
        }
    }

    /// Opens a regular file through checked ancestors, creating missing parents and the file.
    /// Refuses hard-linked files before truncating. With truncate false, existing bytes are preserved;
    /// callers seek to the desired offset on the returned handle.
    public func openForWriting(at path: SafeRelativePath, truncate: Bool) throws -> FileHandle {
        let fd = try openRegularFile(at: path, writing: true, create: true)
        do {
            if truncate {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                guard ftruncate(fd, 0) == 0 else { throw LauncherError.io("Cannot truncate contained file") }
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } catch {
            close(fd)
            throw error
        }
    }

    /// Opens an existing regular file without following symlinks at any level below the root.
    public func openForReading(at path: SafeRelativePath) throws -> FileHandle {
        let fd = try openRegularFile(at: path, writing: false, create: false)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Returns nil when missing; non-regular leaves and symlink ancestors are refused.
    public func size(at path: SafeRelativePath) throws -> Int64? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return nil }
        defer { close(parent) }
        guard let info = try entry(path.components.last!, parent: parent) else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display(path.components)) }
        guard info.st_size >= 0 else { throw LauncherError.io("Invalid file size") }
        return info.st_size
    }

    /// Removes only a regular-file leaf. Missing files are ignored; directories and symlinks are refused.
    public func removeFile(at path: SafeRelativePath) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return }
        defer { close(parent) }
        let name = path.components.last!
        guard let info = try entry(name, parent: parent) else { return }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display(path.components)) }
        guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw LauncherError.io("Cannot remove contained file") }
    }

    /// Flushes a regular file to stable storage using Darwin F_FULLFSYNC.
    public func fullSync(at path: SafeRelativePath) throws {
        let opened = try openRegularDescriptors(at: path, writing: true, create: false, appending: false)
        defer { close(opened.file); close(opened.parent) }
        try Self.synchronizeFileDescriptor(opened.file, durable: true)
        try synchronize(opened.parent)
    }

    private func withRegularDescriptor<T>(at path: SafeRelativePath, writing: Bool, create: Bool,
        _ body: (Int32, Int32, stat) throws -> T) throws -> T {
        let opened = try openRegularDescriptors(at: path, writing: writing, create: create, appending: writing)
        defer { close(opened.file); close(opened.parent) }
        return try body(opened.file, opened.parent, opened.info)
    }

    private func openRegularFile(at path: SafeRelativePath, writing: Bool, create: Bool) throws -> Int32 {
        let opened = try openRegularDescriptors(at: path, writing: writing, create: create, appending: false)
        close(opened.parent)
        return opened.file
    }

    /// Transfers ownership of both descriptors to the caller after validating the opened file.
    private func openRegularDescriptors(at path: SafeRelativePath, writing: Bool, create: Bool,
        appending: Bool) throws -> (file: Int32, parent: Int32, info: stat) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: create) else {
            throw LauncherError.io("File is missing")
        }
        do {
            let name = path.components.last!
            let location = display(path.components)
            if let info = try entry(name, parent: parent) {
                guard info.st_mode & S_IFMT == S_IFREG, !writing || info.st_nlink == 1 else {
                    throw LauncherError.unsafePath(location)
                }
            }
            let flags = (writing ? O_WRONLY : O_RDONLY) | (appending ? O_APPEND : 0) | (create ? O_CREAT : 0)
                | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            let fd = openat(parent, name, flags, 0o600)
            guard fd >= 0 else { throw accessError(location) }
            do {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !writing || info.st_nlink == 1 else {
                    throw LauncherError.unsafePath(location)
                }
                guard info.st_size >= 0 else { throw LauncherError.io("Invalid file size") }
                return (fd, parent, info)
            } catch {
                close(fd)
                throw error
            }
        } catch {
            close(parent)
            throw error
        }
    }

    /// Missing items are ignored. Symlinks inside a removed tree are unlinked.
    public func removeItem(at path: SafeRelativePath) throws {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return }
        defer { close(parent) }
        var budget = Self.entryLimit
        try removeEntry(path.components.last!, parent: parent, display: display(path.components),
            insideTree: false, depth: 0, budget: &budget)
    }

    /// Atomically moves a regular file or directory without replacing the destination.
    /// Creates missing destination parents and fsyncs both parents after the rename.
    /// Cleanup may explicitly move a non-regular source leaf itself; ancestors are always checked.
    public func moveItem(at source: SafeRelativePath, to destination: SafeRelativePath, allowingNonRegularSource: Bool = false) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Move source is missing")
        }
        defer { close(parent) }
        let name = source.components.last!
        guard let info = try entry(name, parent: parent) else { throw LauncherError.io("Move source is missing") }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG || allowingNonRegularSource else {
            throw LauncherError.unsafePath(display(source.components))
        }
        guard let target = try directory(Array(destination.components.dropLast()), create: true) else {
            throw LauncherError.io("Cannot open move destination")
        }
        defer { close(target) }
        let targetName = destination.components.last!
        if let existing = try entry(targetName, parent: target) {
            if existing.st_mode & S_IFMT == S_IFLNK { throw LauncherError.unsafePath(display(destination.components)) }
            throw LauncherError.io("Move destination already exists")
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard renameatx_np(parent, name, target, targetName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw LauncherError.io("Move destination already exists") }
            throw accessError(display(destination.components))
        }
        try synchronize(parent)
        try synchronize(target)
    }

    /// Creates missing parents, then fsyncs a sibling temporary file before atomic replacement.
    public func writeAtomically(_ data: Data, to path: SafeRelativePath) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: true) else {
            throw LauncherError.io("Cannot open destination directory")
        }
        defer { close(parent) }
        let name = path.components.last!
        try checkRegularDestination(name, parent: parent, display: display(path.components))
        let temporary = ".macgacha-write-\(UUID().uuidString)"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError.io("Cannot create temporary file") }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let count = Darwin.write(fd, base.advanced(by: written), min(65_536, bytes.count - written))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LauncherError.io("Cannot write temporary file") }
                written += count
            }
        }
        try synchronize(fd)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try checkRegularDestination(name, parent: parent, display: display(path.components))
        guard renameat(parent, temporary, parent, name) == 0 else { throw LauncherError.io("Cannot publish file") }
        try synchronize(parent)
    }

    /// Reads at most the bounded size observed when the regular file is opened.
    public func readFile(at path: SafeRelativePath, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else { throw LauncherError.io("Negative read limit") }
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else {
            throw LauncherError.io("File is missing")
        }
        defer { close(parent) }
        let name = path.components.last!
        guard let info = try entry(name, parent: parent) else { throw LauncherError.io("File is missing") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display(path.components)) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessError(display(path.components)) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
            throw LauncherError.unsafePath(display(path.components))
        }
        guard opened.st_size >= 0 else { throw LauncherError.io("Invalid file size") }
        guard opened.st_size <= maxBytes else {
            throw LauncherError.fileTooLarge(path: display(path.components), limit: maxBytes)
        }
        var remaining = Int(opened.st_size)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min(65_536, remaining)) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LauncherError.io("Cannot read file") }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            remaining -= count
        }
        return result
    }

    /// Returns immediate children as paths relative to this filesystem's root.
    public func contentsOfDirectory(at path: SafeRelativePath) throws -> [SafeRelativePath] {
        let result = try contentsOfDirectoryReportingInvalid(at: path)
        if let invalid = result.invalid.first { throw LauncherError.unsafePath(invalid) }
        return result.paths
    }

    /// Lists valid paths and reports invalid names separately, without accessing those names.
    /// Invalid UTF-8 names use replacement characters in the report only.
    public func contentsOfDirectoryReportingInvalid(at path: SafeRelativePath) throws -> (paths: [SafeRelativePath], invalid: [String]) {
        guard let fd = try directory(path.components, create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(fd) }
        var budget = Self.entryLimit
        var paths: [SafeRelativePath] = []
        var invalid: [String] = []
        for bytes in try rawNames(in: fd, budget: &budget).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let displayName = path.description + "/" + String(decoding: bytes, as: UTF8.self)
            guard let name = String(bytes: bytes, encoding: .utf8),
                  let child = try? SafeRelativePath(path.description + "/" + name) else {
                invalid.append(displayName)
                continue
            }
            paths.append(child)
        }
        return (paths, invalid)
    }

    /// Returns nil for a missing item. Cleanup may classify a leaf symlink as .other;
    /// symlink ancestors are always refused, and leaf symlinks are refused by default.
    public func itemType(at path: SafeRelativePath, allowingLeafSymlink: Bool = false) throws -> ItemType? {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return nil }
        defer { close(parent) }
        guard let info = try entry(path.components.last!, parent: parent) else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK:
            guard allowingLeafSymlink else { throw LauncherError.unsafePath(display(path.components)) }
            return .other
        default: return .other
        }
    }

    private func directory(_ components: [String], create: Bool) throws -> Int32? {
        guard components.count <= 128 else { throw LauncherError.io("Directory depth exceeds limit") }
        var fd = open(root.path, Self.directoryFlags)
        if fd < 0 && errno == ENOENT && create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fd = open(root.path, Self.directoryFlags)
        }
        guard fd >= 0 else {
            if errno == ENOENT && !create { return nil }
            throw accessError(root.path)
        }
        do {
            for (index, component) in components.enumerated() {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                var info = try entry(component, parent: fd)
                if info == nil {
                    if !create { close(fd); return nil }
                    if mkdirat(fd, component, 0o700) == 0 { try synchronize(fd) }
                    else if errno != EEXIST { throw LauncherError.io("Cannot create contained directory") }
                    info = try entry(component, parent: fd)
                }
                let location = display(Array(components.prefix(index + 1)))
                guard let info, info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.unsafePath(location) }
                let next = openat(fd, component, Self.directoryFlags)
                guard next >= 0 else { throw accessError(location) }
                close(fd)
                fd = next
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func entry(_ name: String, parent: Int32) throws -> stat? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw LauncherError.io("Cannot inspect contained item")
        }
        return info
    }

    private func checkRegularDestination(_ name: String, parent: Int32, display: String) throws {
        if let info = try entry(name, parent: parent), info.st_mode & S_IFMT != S_IFREG {
            throw LauncherError.unsafePath(display)
        }
    }

    private func removeEntry(_ name: String, parent: Int32, display: String, insideTree: Bool,
        depth: Int, budget: inout Int) throws {
        guard depth <= 128 else { throw LauncherError.io("Removal depth exceeds limit") }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let info = try entry(name, parent: parent) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, Self.directoryFlags)
            guard fd >= 0 else { throw accessError(display) }
            defer { close(fd) }
            for child in try names(in: fd, budget: &budget) {
                try removeEntry(child, parent: fd, display: display + "/" + child, insideTree: true,
                    depth: depth + 1, budget: &budget)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw LauncherError.io("Cannot remove directory") }
        } else {
            guard insideTree || info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display) }
            guard unlinkat(parent, name, 0) == 0 else { throw LauncherError.io("Cannot remove file") }
        }
    }

    private func names(in fd: Int32, budget: inout Int) throws -> [String] {
        try rawNames(in: fd, budget: &budget).map {
            guard let name = String(bytes: $0, encoding: .utf8) else {
                throw LauncherError.unsafePath("Invalid UTF-8 directory entry")
            }
            return name
        }
    }

    private func rawNames(in fd: Int32, budget: inout Int) throws -> [[UInt8]] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw LauncherError.io("Cannot duplicate directory descriptor") }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw LauncherError.io("Cannot open directory stream")
        }
        defer { closedir(stream) }
        var result: [[UInt8]] = []
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw LauncherError.io("Cannot list directory") }
                break
            }
            let name = withUnsafeBytes(of: item.pointee.d_name) { Array($0.prefix { $0 != 0 }) }
            if name == [0x2e] || name == [0x2e, 0x2e] { continue }
            guard budget > 0 else { throw LauncherError.io("Directory entry limit exceeded") }
            budget -= 1
            result.append(name)
        }
        return result
    }

    private func synchronize(_ fd: Int32) throws {
        try Self.synchronizeFileDescriptor(fd, durable: false)
    }

    private func display(_ components: [String]) -> String {
        components.reduce(root) { $0.appendingPathComponent($1) }.path
    }

    private func accessError(_ path: String) -> LauncherError {
        errno == ELOOP || errno == ENOTDIR ? .unsafePath(path) : .io("Cannot access contained path")
    }
}
