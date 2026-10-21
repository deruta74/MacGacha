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
    package let fileOps: any FileOps
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private static let entryLimit = 100_000

    public init(root: URL, fileOps: any FileOps = SystemFileOps()) throws {
        guard root.isFileURL, !root.path.isEmpty, !root.path.utf8.contains(0) else {
            throw LauncherError.unsafePath(root.absoluteString)
        }
        self.root = root
        self.fileOps = fileOps
    }

    // Filesystem identity is its trusted root; fault policy does not change path identity.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.root == rhs.root }
    public func hash(into hasher: inout Hasher) { hasher.combine(root) }

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

    /// Persists creation of this trusted root and any missing ancestors. Ancestors
    /// above the root may be symlinks; the root leaf itself must be a directory.
    /// Also syncs an existing leaf's parent, healing an earlier failed creation sync.
    package func createRootDurably() throws {
        let fd = try durableRootDirectory(root, remainingDepth: 128, trustedAncestor: false)
        close(fd)
    }

    private func durableRootDirectory(_ path: URL, remainingDepth: Int, trustedAncestor: Bool) throws -> Int32 {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard remainingDepth > 0 else { throw LauncherError.io("Directory depth exceeds limit") }
        let flags = trustedAncestor ? Self.directoryFlags & ~O_NOFOLLOW : Self.directoryFlags
        let fd = open(path.path, flags)
        if fd >= 0 {
            do {
                if path.path != "/" {
                    let parent = open(path.deletingLastPathComponent().path, Self.directoryFlags & ~O_NOFOLLOW)
                    guard parent >= 0 else { throw accessError(path.path) }
                    defer { close(parent) }
                    try synchronize(parent)
                }
                return fd
            } catch { close(fd); throw error }
        }
        guard errno == ENOENT, path.path != "/" else { throw accessError(path.path) }
        let parent = try durableRootDirectory(path.deletingLastPathComponent(), remainingDepth: remainingDepth - 1, trustedAncestor: true)
        defer { close(parent) }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if mkdirat(parent, path.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw LauncherError.io("Cannot create store directory")
        }
        // Sync even if another caller created the directory, before reporting success.
        try synchronize(parent)
        let child = openat(parent, path.lastPathComponent, Self.directoryFlags)
        guard child >= 0 else { throw accessError(path.path) }
        return child
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
        guard let info = try entry(sourceName, parent: parent) else {
            throw LauncherError.io("Rename source is missing")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw LauncherError.unsafePath(display(source.components))
        }
        guard let target = try directory(Array(destination.components.dropLast()), create: true) else {
            throw LauncherError.io("Rename destination is missing")
        }
        defer { close(target) }
        let targetName = destination.components.last!
        try checkRegularDestination(targetName, parent: target, display: display(destination.components))
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try fileOps.rename(from: sourceName, in: parent, to: targetName, in: target, exclusive: false)
        try synchronize(parent)
        try synchronize(target)
    }

    /// The descriptor is borrowed for this call only. Durable synchronization requests
    /// F_FULLFSYNC rather than fsync. Injection must preserve that synchronization contract.
    public typealias FileSynchronizer = @Sendable (_ descriptor: Int32, _ durable: Bool) throws -> Void

    public static func synchronizeFileDescriptor(_ descriptor: Int32, durable: Bool) throws {
        while true {
            let result = durable ? fcntl(descriptor, F_FULLFSYNC) : fsync(descriptor)
            if result == 0 { return }
            guard errno == EINTR else { throw LauncherError.io("Cannot synchronize file") }
        }
    }

    /// Checks cancellation before opening, then finishes the record and syncs after open.
    /// In particular, cancellation during creation cannot skip the new file's durability.
    /// A thrown error means the record is possibly written. didWrite reports successful syscall
    /// bytes so single writers can distinguish pre-write failures from uncertain on-disk state.
    /// The parent is synced only when the file is created; creation always uses F_FULLFSYNC.
    public func append(_ data: Data, to path: SafeRelativePath, durable: Bool = false,
        synchronize: FileSynchronizer? = nil, didWrite: (Int) -> Void = { _ in }) throws {
        let opened = try openRegularDescriptors(at: path, writing: true, create: true, appending: true)
        defer { close(opened.file); close(opened.parent) }
        try fileOps.writeAll(data, to: opened.file, checkingCancellation: false, didWrite: didWrite)
        let fullSync = durable || opened.created
        if let synchronize { try synchronize(opened.file, fullSync) }
        else { try fileOps.synchronize(opened.file, durable: fullSync) }
        if opened.created { try self.synchronize(opened.parent) }
    }

    /// Heals a directory entry left by an earlier failed file-creation sync.
    package func synchronizeParentDirectory(of path: SafeRelativePath) throws {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else {
            throw LauncherError.io("File parent is missing")
        }
        defer { close(parent) }
        try synchronize(parent)
    }

    /// Shrinks an existing regular file without extending it, then fsyncs it.
    public func truncateFile(at path: SafeRelativePath, toByteCount count: Int64,
        synchronize: FileSynchronizer? = nil) throws {
        guard count >= 0 else { throw LauncherError.io("Invalid truncation length") }
        try withRegularDescriptor(at: path, writing: true, create: false) { fd, _, info in
            guard count <= info.st_size else { throw LauncherError.io("Invalid truncation length") }
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                if ftruncate(fd, count) == 0 { break }
                guard errno == EINTR else { throw LauncherError.io("Cannot truncate contained file") }
            }
            if let synchronize { try synchronize(fd, false) }
            else { try fileOps.synchronize(fd, durable: false) }
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
        guard let info = try entry(name, parent: parent) else { try synchronize(parent); return }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display(path.components)) }
        try fileOps.unlink(name, in: parent, isDirectory: false)
        try synchronize(parent)
    }

    /// Flushes a regular file to stable storage using Darwin F_FULLFSYNC.
    public func fullSync(at path: SafeRelativePath) throws {
        let opened = try openRegularDescriptors(at: path, writing: true, create: false, appending: false)
        defer { close(opened.file); close(opened.parent) }
        try fileOps.synchronize(opened.file, durable: true)
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
        appending: Bool) throws -> (file: Int32, parent: Int32, info: stat, created: Bool) {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: create) else {
            throw LauncherError.io("File is missing")
        }
        do {
            let name = path.components.last!
            let location = display(path.components)
            let existing = try entry(name, parent: parent)
            if let info = existing {
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
                return (fd, parent, info, existing == nil)
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
        try synchronize(parent)
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
        try fileOps.rename(from: name, in: parent, to: targetName, in: target, exclusive: true)
        try synchronize(parent)
        try synchronize(target)
    }

    /// Publishes a directory atomically. Returns true if a prior destination was swapped
    /// into source (the caller then removes it). Missing destinations use an exclusive rename.
    /// Both leaves must be directories; symlinks at either leaf or in ancestors are refused.
    @discardableResult
    public func publishDirectory(at source: SafeRelativePath, to destination: SafeRelativePath) throws -> Bool {
        guard caseFoldedPathKey(for: source) != caseFoldedPathKey(for: destination) else { throw LauncherError.unsafePath(source.description) }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Publish parent is missing")
        }
        defer { close(parent) }
        guard let target = try directory(Array(destination.components.dropLast()), create: false) else {
            throw LauncherError.io("Publish parent is missing")
        }
        defer { close(target) }
        let name = source.components.last!
        let targetName = destination.components.last!
        guard let info = try entry(name, parent: parent), info.st_mode & S_IFMT == S_IFDIR else {
            throw LauncherError.unsafePath(display(source.components))
        }
        let existing = try entry(targetName, parent: target)
        if let existing, existing.st_mode & S_IFMT != S_IFDIR {
            throw LauncherError.unsafePath(display(destination.components))
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if existing != nil {
            try fileOps.swap(from: name, in: parent, to: targetName, in: target)
        } else {
            try fileOps.rename(from: name, in: parent, to: targetName, in: target, exclusive: true)
        }
        do {
            try synchronize(parent)
            try synchronize(target)
        } catch {
            // A failed publication barrier must not discard the prior install. Restore
            // the original names, keeping both trees if even rollback itself fails.
            if existing != nil {
                try fileOps.swap(from: name, in: parent, to: targetName, in: target)
            } else {
                try fileOps.rename(from: targetName, in: target, to: name, in: parent, exclusive: true)
            }
            try? synchronize(parent)
            try? synchronize(target)
            throw error
        }
        return existing != nil
    }

    /// Checked pathname for a process boundary. Processes run only after archive validation;
    /// concurrent hostile ancestor renames are outside the filesystem threat model.
    package func directoryURL(at path: SafeRelativePath) throws -> URL {
        guard let fd = try directory(path.components, create: false) else { throw LauncherError.io("Directory is missing") }
        close(fd)
        return path.resolved(against: root)
    }

    package struct TreeEntry: Sendable {
        package let path: SafeRelativePath
        package let type: ItemType
        package let linkTarget: String?
        package let size: Int64
    }

    /// Snapshot of an extracted tree, never following a symbolic link. Special files and
    /// hard links with names outside this tree are refused. Bounded like other tree operations.
    package func inspectTree(at path: SafeRelativePath) throws -> [TreeEntry] {
        guard let fd = try directory(path.components, create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(fd) }
        var budget = Self.entryLimit
        var result: [TreeEntry] = []
        var hardlinks: [String: (count: Int, expected: Int)] = [:]
        try walkTree(fd, prefix: [], depth: 0, budget: &budget) { parent, name, components, info in
            let relative = try SafeRelativePath(components.joined(separator: "/"))
            let type = info.st_mode & S_IFMT
            var target: String?
            var uniqueSize: Int64 = 0
            if type == S_IFLNK {
                var bytes = [UInt8](repeating: 0, count: 4097)
                let count = bytes.withUnsafeMutableBytes { readlinkat(parent, name, $0.baseAddress, $0.count) }
                guard count > 0, count < bytes.count, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {
                    throw LauncherError.unsafePath(relative.description)
                }
                target = text
            } else if type == S_IFREG {
                let key = "\(info.st_dev):\(info.st_ino)"
                let old = hardlinks[key]?.count ?? 0
                hardlinks[key] = (old + 1, Int(info.st_nlink))
                uniqueSize = old == 0 ? info.st_size : 0
            } else if type != S_IFDIR { throw LauncherError.unsafePath(relative.description) }
            result.append(TreeEntry(path: relative, type: type == S_IFDIR ? .directory : type == S_IFREG ? .regularFile : .other,
                linkTarget: target, size: uniqueSize))
        }
        guard hardlinks.values.allSatisfy({ $0.count == $0.expected }) else { throw LauncherError.unsafePath(path.description) }
        return result
    }

    /// Copies one regular file in bounded chunks, retaining executable permission bits.
    /// Both files are opened through descriptor-relative, no-follow traversal.
    package func copyRegularFile(at source: SafeRelativePath, to destination: SafeRelativePath,
        in destinationFS: ContainedFileSystem, maxBytes: Int64) throws -> Int64 {
        guard maxBytes >= 0 else { throw LauncherError.io("Runtime import size limit exceeded") }
        let input = try openForReading(at: source)
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect import file") }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw LauncherError.io("Runtime import size limit exceeded") }
        let output = try destinationFS.openForWriting(at: destination, truncate: true)
        defer { try? output.close() }
        var count: Int64 = 0
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let data = try autoreleasepool { try input.read(upToCount: 65_536) ?? Data() }
            if data.isEmpty { break }
            guard Int64(data.count) <= maxBytes - count else { throw LauncherError.io("Runtime import size limit exceeded") }
            try destinationFS.fileOps.writeAll(data, to: output.fileDescriptor)
            count += Int64(data.count)
        }
        guard count == info.st_size else { throw LauncherError.io("Import source changed during copy") }
        guard fchmod(output.fileDescriptor, info.st_mode & 0o777) == 0 else { throw LauncherError.io("Cannot preserve import permissions") }
        return count
    }

    /// The caller validates the relative target against its whole tree before creating links.
    package func createSymbolicLink(at path: SafeRelativePath, target: String) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard !target.utf8.contains(0), !target.isEmpty, target.utf8.count <= 4096 else { throw LauncherError.unsafePath(path.description) }
        guard let parent = try directory(Array(path.components.dropLast()), create: true), let name = path.components.last else {
            throw LauncherError.io("Cannot create import link")
        }
        defer { close(parent) }
        guard try entry(name, parent: parent) == nil else { throw LauncherError.unsafePath(path.description) }
        guard symlinkat(target, parent, name) == 0 else { throw LauncherError.io("Cannot create import link") }
        try synchronize(parent)
    }

    /// Flushes regular files and then directories bottom-up, never following links.
    /// Directory sync persists symlink entries; no symlink target is opened or flushed.
    package func synchronizeTree(at path: SafeRelativePath) throws {
        guard let fd = try directory(path.components, create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(fd) }
        var budget = Self.entryLimit
        func flush(_ parent: Int32, depth: Int) throws {
            guard depth < 128 else { throw LauncherError.io("Directory depth exceeds limit") }
            for name in try names(in: parent, budget: &budget) {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                guard let info = try entry(name, parent: parent) else { throw LauncherError.io("Tree entry disappeared") }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = openat(parent, name, Self.directoryFlags)
                    guard child >= 0 else { throw accessError(name) }
                    defer { close(child) }
                    try flush(child, depth: depth + 1)
                case S_IFREG:
                    let child = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { throw accessError(name) }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(name) }
                    try fileOps.synchronize(child, durable: false)
                case S_IFLNK: break
                default: throw LauncherError.unsafePath(name)
                }
            }
            try fileOps.synchronize(parent, durable: false)
        }
        try flush(fd, depth: 0)
    }

    /// Removes quarantine from every file, directory and symlink without following links.
    /// Other xattrs are preserved. Missing quarantine is normal; other errors propagate.
    package func removeQuarantineRecursively(at path: SafeRelativePath) throws {
        guard let fd = try directory(path.components, create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(fd) }
        func strip(_ descriptor: Int32) throws {
            guard fremovexattr(descriptor, "com.apple.quarantine", 0) == 0 || errno == ENOATTR else {
                throw LauncherError.io("Cannot remove runtime quarantine")
            }
        }
        try strip(fd)
        var budget = Self.entryLimit
        try walkTree(fd, prefix: [], depth: 0, budget: &budget) { parent, name, _, info in
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG || type == S_IFLNK else { throw LauncherError.unsafePath(name) }
            let flags = type == S_IFLNK ? O_SYMLINK : O_NOFOLLOW
            let child = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | flags)
            guard child >= 0 else { throw accessError(name) }
            defer { close(child) }
            try strip(child)
        }
    }

    private func walkTree(_ fd: Int32, prefix: [String], depth: Int, budget: inout Int,
        visit: (Int32, String, [String], stat) throws -> Void) throws {
        guard depth < 128 else { throw LauncherError.io("Directory depth exceeds limit") }
        for name in try names(in: fd, budget: &budget) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let info = try entry(name, parent: fd) else { throw LauncherError.io("Tree entry disappeared") }
            let components = prefix + [name]
            try visit(fd, name, components, info)
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, Self.directoryFlags)
                guard child >= 0 else { throw accessError(name) }
                defer { close(child) }
                try walkTree(child, prefix: components, depth: depth + 1, budget: &budget, visit: visit)
            }
        }
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
        defer { close(fd); try? fileOps.unlink(temporary, in: parent, isDirectory: false) }
        try fileOps.writeAll(data, to: fd)
        try synchronize(fd)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try checkRegularDestination(name, parent: parent, display: display(path.components))
        try fileOps.rename(from: temporary, in: parent, to: name, in: parent, exclusive: false)
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
        var transferred = false
        defer { if !transferred { close(fd) } }
        for (index, component) in components.enumerated() {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            var info = try entry(component, parent: fd)
            if info == nil {
                if !create { return nil }
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
        transferred = true
        return fd
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
            try fileOps.unlink(name, in: parent, isDirectory: true)
        } else {
            guard insideTree || info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(display) }
            try fileOps.unlink(name, in: parent, isDirectory: false)
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
        try fileOps.synchronize(fd, durable: false)
    }

    private func display(_ components: [String]) -> String {
        components.reduce(root) { $0.appendingPathComponent($1) }.path
    }

    private func accessError(_ path: String) -> LauncherError {
        errno == ELOOP || errno == ENOTDIR ? .unsafePath(path) : .io("Cannot access contained path")
    }
}
