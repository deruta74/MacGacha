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
    private var pinnedRoot: RootDescriptor?
    private let expectedRootIdentity: FileSystemIdentity?
    private let identityProvider: any FileSystemIdentityProvider
    package private(set) var fileOps: any FileOps

    /// Preserve the root pin and expected identity when layering I/O policy.
    package func replacingFileOps(_ value: any FileOps) -> Self { var copy = self; copy.fileOps = SpaceAwareFileOps(base: value); return copy }
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private static let entryLimit = 100_000

    public init(root: URL, fileOps: any FileOps = SystemFileOps(), expectedRootIdentity: FileSystemIdentity? = nil,
        identityProvider: any FileSystemIdentityProvider = SystemFileSystemIdentityProvider()) throws {
        guard root.isFileURL, !root.path.isEmpty, !root.path.utf8.contains(0) else {
            throw LauncherError.unsafePath(root.absoluteString)
        }
        self.root = root
        self.fileOps = SpaceAwareFileOps(base: fileOps)
        self.expectedRootIdentity = expectedRootIdentity
        self.identityProvider = identityProvider
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

    /// Descriptor-relative metadata only; a symlink is never followed or aged
    /// as a regular temporary file. Missing/non-regular leaves return nil.
    package func modificationDate(at path: SafeRelativePath) throws -> Date? {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return nil }
        defer { close(parent) }
        guard let info = try entry(path.components.last!, parent: parent), info.st_mode & S_IFMT == S_IFREG else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    /// Creates missing parent directories as well as the requested directory.
    public func createDirectory(at path: SafeRelativePath) throws {
        guard let fd = try directory(path.components, create: true) else { throw LauncherError.io("Cannot create directory") }
        close(fd)
    }

    /// A bounded listing stops without visiting the rest of a large directory.
    package func contentsOfRootDirectory(maximumEntries: Int? = nil) throws -> [SafeRelativePath] {
        guard let fd = try directory([], create: false) else { return [] }
        defer { close(fd) }
        var budget = Self.entryLimit
        let maximum = maximumEntries.map { min(Self.entryLimit, max(1, $0)) }
        return try names(in: fd, budget: &budget, maximumEntries: maximum).map { try SafeRelativePath($0) }
    }

    /// Removes directories only. Foreign files, symlinks and special entries are
    /// left untouched, and symlinks are never traversed.
    package func pruneEmptyDirectories() throws {
        guard let fd = try directory([], create: false) else { return }
        defer { close(fd) }
        var budget = Self.entryLimit
        _ = try pruneEmpty(fd, depth: 0, budget: &budget)
    }

    private func pruneEmpty(_ fd: Int32, depth: Int, budget: inout Int) throws -> Bool {
        guard depth <= 128 else { throw LauncherError.io("Directory depth exceeds limit") }
        var empty = true
        for name in try names(in: fd, budget: &budget) {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let info = try entry(name, parent: fd) else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, Self.directoryFlags)
                guard child >= 0 else { throw accessError(name) }
                let childEmpty: Bool
                do { childEmpty = try pruneEmpty(child, depth: depth + 1, budget: &budget); close(child) }
                catch { close(child); throw error }
                if childEmpty {
                    try fileOps.unlink(name, in: fd, isDirectory: true)
                    try synchronize(fd)
                } else { empty = false }
            } else { empty = false }
        }
        return empty
    }

    package func removeEmptyDirectory(at path: SafeRelativePath) throws {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return }
        defer { close(parent) }
        let name = path.components.last!
        guard let info = try entry(name, parent: parent) else { return }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.unsafePath(path.description) }
        let child = openat(parent, name, Self.directoryFlags)
        guard child >= 0 else { throw accessError(path.description) }
        defer { close(child) }
        var budget = Self.entryLimit
        guard try names(in: child, budget: &budget).isEmpty else { return }
        try fileOps.unlink(name, in: parent, isDirectory: true)
        try synchronize(parent)
    }

    /// Persists creation of this trusted root and any missing ancestors. Ancestors
    /// above the root may be symlinks; the root leaf itself must be a directory.
    /// Also syncs an existing leaf's parent, healing an earlier failed creation sync.
    package func createRootDurably() throws {
        let fd = try durableRootDirectory(root, remainingDepth: 128, trustedAncestor: false)
        close(fd)
    }

    /// Process-local reservations use the actual directory identity, including
    /// when trusted ancestors reach it through symlink or firmlink aliases.
    package func rootIdentity() throws -> FileSystemIdentity {
        guard let fd = try directory([], create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(fd) }
        return try identityProvider.identity(of: fd)
    }

    /// Retains the checked root. Subsequent operations duplicate this descriptor
    /// instead of reopening a pathname that may now name an unrelated directory.
    package func pinRoot() throws -> Self {
        guard let pinned = try pinRootIfPresent() else { throw LauncherError.io("Directory is missing") }
        return pinned
    }

    package func pinRootIfPresent() throws -> Self? {
        guard let fd = try directory([], create: false) else { return nil }
        var pinned = self
        pinned.pinnedRoot = RootDescriptor(fd)
        return pinned
    }

    /// Pins a descendant reached through the contained root. Neither traversal nor
    /// later operations can be redirected by replacing the descendant's pathname.
    package func pinDirectoryIfPresent(at path: SafeRelativePath) throws -> Self? {
        var child = try Self(root: path.resolved(against: root), fileOps: fileOps, identityProvider: identityProvider)
        guard let fd = try directory(path.components, create: false) else { return nil }
        child.pinnedRoot = RootDescriptor(fd)
        return child
    }

    /// Removes the pinned tree and unlinks its leaf only while it still names
    /// that directory. An exchanged pathname never redirects recursive deletion.
    package func removePinnedRoot(onlyIfEmpty: Bool) throws {
        guard let pinnedRoot else { throw LauncherError.io("Root is not pinned") }
        let parent = open(root.deletingLastPathComponent().path, Self.directoryFlags & ~O_NOFOLLOW)
        guard parent >= 0 else { throw accessError("install location") }
        defer { close(parent) }
        func requireIdentity() throws {
            var expected = stat()
            guard fstat(pinnedRoot.fd, &expected) == 0,
                let actual = try entry(root.lastPathComponent, parent: parent),
                actual.st_mode & S_IFMT == S_IFDIR,
                actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
                throw LauncherError.io("install folder was replaced")
            }
        }
        try requireIdentity()
        guard let target = try directory([], create: false) else { throw LauncherError.io("Directory is missing") }
        defer { close(target) }
        var budget = Self.entryLimit
        let children = try names(in: target, budget: &budget)
        if onlyIfEmpty && !children.isEmpty { return }
        for child in children {
            try removeEntry(child, parent: target, display: child, insideTree: true, depth: 0, budget: &budget)
        }
        try synchronize(target)
        try requireIdentity()
        try fileOps.unlink(root.lastPathComponent, in: parent, isDirectory: true)
        try synchronize(parent)
    }

    private func durableRootDirectory(_ path: URL, remainingDepth: Int, trustedAncestor: Bool) throws -> Int32 {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard remainingDepth > 0 else { throw LauncherError.io("Directory depth exceeds limit") }
        let flags = trustedAncestor ? Self.directoryFlags & ~O_NOFOLLOW : Self.directoryFlags
        let fd = open(path.path, flags)
        if fd >= 0 {
            do {
                if !trustedAncestor, let expectedRootIdentity,
                    try identityProvider.identity(of: fd) != expectedRootIdentity {
                    throw LauncherError.io("install folder was replaced")
                }
                if path.path != "/" {
                    let parent = open(path.deletingLastPathComponent().path, Self.directoryFlags & ~O_NOFOLLOW)
                    guard parent >= 0 else { throw accessError(path.path) }
                    defer { close(parent) }
                    try synchronize(parent)
                }
                return fd
            } catch { close(fd); throw error }
        }
        if !trustedAncestor, expectedRootIdentity != nil,
            errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
            throw LauncherError.io("install folder was replaced")
        }
        guard errno == ENOENT, path.path != "/" else { throw accessError(path.path) }
        let parent = try durableRootDirectory(path.deletingLastPathComponent(), remainingDepth: remainingDepth - 1, trustedAncestor: true)
        defer { close(parent) }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if mkdirat(parent, path.lastPathComponent, 0o700) != 0, errno != EEXIST {
            throw LauncherError.fileSystemFailure("Cannot create store directory")
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
            guard errno == EINTR else { throw LauncherError.fileSystemFailure("Cannot synchronize file") }
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
                guard errno == EINTR else { throw LauncherError.fileSystemFailure("Cannot truncate contained file") }
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
        let barrier = fileOps as? any AllocationFileOps
        barrier?.beginAllocation(); defer { barrier?.endAllocation() }
        let fd = try openRegularFile(at: path, writing: true, create: true)
        do {
            if truncate {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                guard ftruncate(fd, 0) == 0 else { throw LauncherError.fileSystemFailure("Cannot truncate contained file") }
            }
            try barrier?.openedForWriting(fd)
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
        try synchronizeFile(at: path, durable: true)
    }

    /// fsync for verified staging data; commit boundaries perform F_FULLFSYNC.
    package func synchronizeFile(at path: SafeRelativePath, durable: Bool) throws {
        let opened = try openRegularDescriptors(at: path, writing: true, create: false, appending: false)
        defer { close(opened.file); close(opened.parent) }
        try fileOps.synchronize(opened.file, durable: durable)
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

    /// Moves a regular file between contained roots without replacing anything.
    /// Both roots/ancestors are checked, and both parents are durably synchronized.
    /// EXDEV propagates; callers must not emulate this with copy-and-delete.
    package func moveRegularFile(at source: SafeRelativePath, to destination: SafeRelativePath,
        in destinationFileSystem: ContainedFileSystem) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Move source is missing")
        }
        defer { close(parent) }
        let name = source.components.last!
        guard let info = try entry(name, parent: parent), info.st_mode & S_IFMT == S_IFREG else {
            throw LauncherError.unsafePath(display(source.components))
        }
        let destinationParents = Array(destination.components.dropLast())
        if !destinationParents.isEmpty {
            try destinationFileSystem.createDirectoryDurably(at: SafeRelativePath(destinationParents.joined(separator: "/")))
        }
        guard let target = try destinationFileSystem.directory(destinationParents, create: false) else {
            throw LauncherError.io("Move destination is missing")
        }
        defer { close(target) }
        guard try destinationFileSystem.entry(destination.components.last!, parent: target) == nil else {
            throw LauncherError.io("Move destination already exists")
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        try fileOps.rename(from: name, in: parent, to: destination.components.last!, in: target, exclusive: true)
        try synchronize(parent)
        try destinationFileSystem.synchronize(target)
    }

    /// Launch metadata/recovery uses an explicit durable directory chain rather
    /// than making every hot-path traversal repeat ancestor synchronization.
    package func createDirectoryDurably(at path: SafeRelativePath) throws {
        try synchronizeDirectories(path.components, createMissing: true)
    }

    /// Heals both the leaf-parent barrier and interrupted ancestor creation.
    /// Never creates missing directories or follows links.
    package func synchronizeAncestors(of path: SafeRelativePath) throws {
        try synchronizeDirectories(Array(path.components.dropLast()), createMissing: false)
    }

    private func synchronizeDirectories(_ components: [String], createMissing: Bool) throws {
        guard components.count <= 128, let root = try directory([], create: false) else {
            throw LauncherError.io("Cannot synchronize missing directory chain")
        }
        var parent = root
        defer { close(parent) }
        for component in components {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            var info = try entry(component, parent: parent)
            if info == nil, createMissing {
                guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else { throw LauncherError.fileSystemFailure("Cannot create durable directory") }
                info = try entry(component, parent: parent)
            }
            guard let info, info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.unsafePath(component) }
            let child = openat(parent, component, Self.directoryFlags)
            guard child >= 0 else { throw accessError(component) }
            // Repeat this even for an existing child: a previous mkdir may
            // have succeeded immediately before this barrier failed.
            do { try synchronize(parent) }
            catch { close(child); throw error }
            close(parent); parent = child
        }
        try synchronize(parent)
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
        in destinationFS: ContainedFileSystem, maxBytes: Int64, preferClone: Bool = false) throws -> Int64 {
        guard maxBytes >= 0 else { throw LauncherError.io("Runtime import size limit exceeded") }
        let input = try openForReading(at: source)
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect import file") }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw LauncherError.io("Runtime import size limit exceeded") }
        if preferClone {
            guard let parent = try destinationFS.directory(Array(destination.components.dropLast()), create: true),
                let name = destination.components.last else { throw LauncherError.io("Cannot clone runtime file") }
            defer { close(parent) }
            guard try destinationFS.entry(name, parent: parent) == nil else { throw LauncherError.unsafePath(destination.description) }
            if fclonefileat(input.fileDescriptor, parent, name, 0) == 0 { return info.st_size }
            guard [ENOTSUP, EXDEV, EINVAL].contains(errno) else { throw LauncherError.fileSystemFailure("Cannot clone runtime file") }
        }
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
        guard fchmod(output.fileDescriptor, info.st_mode & 0o777) == 0 else { throw LauncherError.fileSystemFailure("Cannot preserve import permissions") }
        return count
    }

    /// The caller validates the relative target against its whole tree before creating links.
    package func createSymbolicLink(at path: SafeRelativePath, target: String) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard !target.utf8.contains(0), !target.isEmpty, target.utf8.count <= 4096 else { throw LauncherError.unsafePath(path.description) }
        guard let parent = try directory(Array(path.components.dropLast()), create: true), let name = path.components.last else {
            throw LauncherError.fileSystemFailure("Cannot create import link")
        }
        defer { close(parent) }
        guard try entry(name, parent: parent) == nil else { throw LauncherError.unsafePath(path.description) }
        guard symlinkat(target, parent, name) == 0 else { throw LauncherError.fileSystemFailure("Cannot create import link") }
        try synchronize(parent)
    }

    /// Creates a literal hardlink between checked parents. Only a regular file
    /// can be the source; neither ancestor traversal nor the leaf follows links.
    package func createHardLink(at path: SafeRelativePath, to source: SafeRelativePath) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Hardlink source is missing")
        }
        defer { close(parent) }
        let name = source.components.last!
        guard let info = try entry(name, parent: parent), info.st_mode & S_IFMT == S_IFREG else {
            throw LauncherError.unsafePath(source.description)
        }
        guard let destination = try directory(Array(path.components.dropLast()), create: true) else {
            throw LauncherError.io("Hardlink destination is missing")
        }
        defer { close(destination) }
        guard linkat(parent, name, destination, path.components.last!, 0) == 0 else {
            throw LauncherError.fileSystemFailure("Cannot create runtime hardlink")
        }
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
            if fgetxattr(descriptor, "com.apple.quarantine", nil, 0, 0, 0) < 0 {
                if errno == ENOATTR { return }
                throw LauncherError.fileSystemFailure("Cannot inspect runtime quarantine")
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw LauncherError.fileSystemFailure("Cannot inspect runtime permissions") }
            // Signed frameworks contain read-only resources. Remove quarantine only
            // when present, temporarily granting owner write on this pinned inode.
            let needsWrite = info.st_mode & S_IFMT != S_IFLNK && info.st_mode & S_IWUSR == 0
            if needsWrite, fchmod(descriptor, (info.st_mode & 0o777) | S_IWUSR) != 0 {
                throw LauncherError.fileSystemFailure("Cannot prepare runtime quarantine removal")
            }
            let result = fremovexattr(descriptor, "com.apple.quarantine", 0)
            let removalError = errno
            if needsWrite, fchmod(descriptor, info.st_mode & 0o777) != 0 {
                throw LauncherError.fileSystemFailure("Cannot restore runtime permissions")
            }
            guard result == 0 || removalError == ENOATTR else {
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
        try writeAtomically(data, to: path, temporaryPrefix: ".macgacha-write-")
    }

    /// Lease-free cache writers never share operation-owned temporary names.
    /// Operation sweeps may run while this temporary is waiting for its rename.
    package func writeCacheAtomically(_ data: Data, to path: SafeRelativePath) throws {
        try writeAtomically(data, to: path, temporaryPrefix: ".macgacha-cache-write-")
    }

    /// Per-game session ownership permits concurrent writes with an unrelated
    /// download. Operation sweeps must never treat these as operation-owned.
    package func writeLaunchAtomically(_ data: Data, to path: SafeRelativePath) throws {
        try writeAtomically(data, to: path, temporaryPrefix: ".macgacha-launch-write-")
    }

    private func writeAtomically(_ data: Data, to path: SafeRelativePath, temporaryPrefix: String) throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard let parent = try directory(Array(path.components.dropLast()), create: true) else {
            throw LauncherError.io("Cannot open destination directory")
        }
        defer { close(parent) }
        let name = path.components.last!
        try checkRegularDestination(name, parent: parent, display: display(path.components))
        let temporary = "\(temporaryPrefix)\(UUID().uuidString)"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LauncherError.fileSystemFailure("Cannot create temporary file") }
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
        var fd = pinnedRoot.map { openat($0.fd, ".", Self.directoryFlags) } ?? open(root.path, Self.directoryFlags)
        if expectedRootIdentity == nil && pinnedRoot == nil && fd < 0 && errno == ENOENT && create {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw LauncherError.normalizingFileSystemError(error) }
            fd = open(root.path, Self.directoryFlags)
        }
        guard fd >= 0 else {
            if expectedRootIdentity != nil && (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) {
                throw LauncherError.io("install folder was replaced")
            }
            if errno == ENOENT && !create { return nil }
            throw accessError(root.path)
        }
        var transferred = false
        defer { if !transferred { close(fd) } }
        if let expectedRootIdentity, try identityProvider.identity(of: fd) != expectedRootIdentity {
            throw LauncherError.io("install folder was replaced")
        }
        for (index, component) in components.enumerated() {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            var info = try entry(component, parent: fd)
            if info == nil {
                if !create { return nil }
                if mkdirat(fd, component, 0o700) == 0 { try synchronize(fd) }
                else if errno != EEXIST { throw LauncherError.fileSystemFailure("Cannot create contained directory") }
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

    private func names(in fd: Int32, budget: inout Int, maximumEntries: Int? = nil) throws -> [String] {
        try rawNames(in: fd, budget: &budget, maximumEntries: maximumEntries).map {
            guard let name = String(bytes: $0, encoding: .utf8) else {
                throw LauncherError.unsafePath("Invalid UTF-8 directory entry")
            }
            return name
        }
    }

    private func rawNames(in fd: Int32, budget: inout Int, maximumEntries: Int? = nil) throws -> [[UInt8]] {
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
            if let maximumEntries, result.count >= maximumEntries { break }
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
        errno == ELOOP || errno == ENOTDIR ? .unsafePath(path) : .fileSystemFailure("Cannot access contained path")
    }
}

extension ContainedFileSystem {
    /// A scoped, borrowed claim. The descriptor remains open through the caller's
    /// move and post-check; the noncopyable borrow cannot escape this scope.
    package func withClaimedFile<T>(at source: SafeRelativePath, permitHardLinks: Bool = false, maximumBytes: Int64 = .max,
        _ body: (borrowing RegularFileClaim) throws -> T) throws -> T {
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else {
            throw LauncherError.io("Claim source is missing")
        }
        defer { close(parent) }
        // NONBLOCK also makes a substituted FIFO fail its type check without
        // blocking. It has no effect on reads from the required regular file.
        let fd = openat(parent, source.components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw accessError(source.description) }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_size <= maximumBytes else { throw LauncherError.io("Claim exceeds read limit") }
        let verified = try Self.hashClaimDescriptor(fd)
        guard let named = try entry(source.components.last!, parent: parent), ClaimStamp(named) == verified.stamp else {
            throw LauncherError.io("Claim name changed during verification")
        }
        guard permitHardLinks || verified.stamp.links == 1 else { throw LauncherError.io("Claim source is hard-linked") }
        let claim = RegularFileClaim(fileSystem: self, parent: parent, descriptor: fd, source: source,
            stamp: verified.stamp, sha256: verified.sha256)
        return try body(claim)
    }

    package struct ClaimStamp: Codable, Equatable, Sendable {
        package let device: Int64
        package let inode: UInt64
        package let size: Int64
        package let mtimeSeconds: Int64
        package let mtimeNanos: Int64
        package let ctimeSeconds: Int64
        package let ctimeNanos: Int64
        package let links: UInt64
        package let kind: UInt32
        fileprivate init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
            mtimeSeconds = Int64(value.st_mtimespec.tv_sec); mtimeNanos = Int64(value.st_mtimespec.tv_nsec)
            ctimeSeconds = Int64(value.st_ctimespec.tv_sec); ctimeNanos = Int64(value.st_ctimespec.tv_nsec)
            links = UInt64(value.st_nlink); kind = UInt32(value.st_mode & S_IFMT)
        }
        package func sameObject(as other: Self) -> Bool { device == other.device && inode == other.inode && kind == other.kind }
        package func sameContentMetadata(as other: Self) -> Bool {
            sameObject(as: other) && size == other.size && mtimeSeconds == other.mtimeSeconds && mtimeNanos == other.mtimeNanos
        }
    }

    package struct RegularFileClaim: ~Copyable {
        fileprivate let fileSystem: ContainedFileSystem
        fileprivate let parent: Int32
        fileprivate let descriptor: Int32
        package let source: SafeRelativePath
        package let stamp: ClaimStamp
        package let sha256: Digest

        /// Exclusive publication keeps the claim open until the destination and
        /// content have both been checked. A false result never resolves ownership:
        /// the caller must retain its durable intent and quarantine only an inode
        /// that still matches it; an unrelated replacement is left untouched.
        package func move(to destination: SafeRelativePath, in targetFS: ContainedFileSystem,
            afterRename: () -> Void = {}) throws -> Bool {
            let parents = Array(destination.components.dropLast())
            if !parents.isEmpty { try targetFS.createDirectoryDurably(at: SafeRelativePath(parents.joined(separator: "/"))) }
            guard let target = try targetFS.directory(parents, create: false) else { throw LauncherError.io("Move destination missing") }
            defer { close(target) }
            var current = stat()
            guard fstat(descriptor, &current) == 0, ClaimStamp(current) == stamp,
                let named = try fileSystem.entry(source.components.last!, parent: parent),
                ClaimStamp(named) == stamp else { throw LauncherError.io("Claim source changed before rename") }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            try fileSystem.fileOps.rename(from: source.components.last!, in: parent,
                to: destination.components.last!, in: target, exclusive: true)
            afterRename()
            let verified = try verifiesPublication(at: destination, in: targetFS)
            if !verified { return false }
            try fileSystem.synchronize(parent)
            try targetFS.synchronize(target)
            return verified
        }

        /// Rename may change ctime. Bind the destination to this inode, then
        /// rehash the still-open fd, checking stable size/mtime/nlink around it.
        package func verifiesPublication(at destination: SafeRelativePath, in targetFS: ContainedFileSystem) throws -> Bool {
            guard let target = try targetFS.directory(Array(destination.components.dropLast()), create: false) else { return false }
            defer { close(target) }
            guard let named = try targetFS.entry(destination.components.last!, parent: target),
                stamp.sameObject(as: ClaimStamp(named)) else { return false }
            var current = stat()
            guard fstat(descriptor, &current) == 0, stamp.sameContentMetadata(as: ClaimStamp(current)),
                current.st_nlink == 1 else { return false }
            let verified: (stamp: ClaimStamp, sha256: Digest)
            do { verified = try reverify() }
            catch LauncherError.cancelled { throw LauncherError.cancelled }
            catch { return false }
            guard verified.sha256 == sha256, stamp.sameContentMetadata(as: verified.stamp), verified.stamp.links == 1,
                fstat(descriptor, &current) == 0, verified.stamp.sameContentMetadata(as: ClaimStamp(current)), current.st_nlink == 1,
                let finalName = try targetFS.entry(destination.components.last!, parent: target),
                stamp.sameObject(as: ClaimStamp(finalName)) else { return false }
            return true
        }

        /// Rehash the same descriptor, with before/after metadata stability.
        package func reverify() throws -> (stamp: ClaimStamp, sha256: Digest) {
            try ContainedFileSystem.hashClaimDescriptor(descriptor)
        }
    }

    /// A non-following identity observation, never an ownership grant by itself.
    package func entryStamp(at path: SafeRelativePath) throws -> ClaimStamp? {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return nil }
        defer { close(parent) }
        return try entry(path.components.last!, parent: parent).map(ClaimStamp.init)
    }

    /// Move only the recorded inode. The caller durably records this intent
    /// before calling, and records the actual destination identity in didMove
    /// before any subsequent rename (including returning a raced-in user file).
    /// A false result leaves an unrelated source untouched. The post-rename
    /// identity can differ because RENAME_EXCL protects only the destination.
    package func quarantineEntry(at source: SafeRelativePath, to destination: SafeRelativePath,
        in targetFS: ContainedFileSystem, matching expected: ClaimStamp,
        afterRename: () -> Void = {}, didMove: (ClaimStamp) throws -> Void) throws -> Bool {
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else { return false }
        defer { close(parent) }
        let parents = Array(destination.components.dropLast())
        if !parents.isEmpty { try targetFS.createDirectoryDurably(at: SafeRelativePath(parents.joined(separator: "/"))) }
        guard let target = try targetFS.directory(parents, create: false) else { throw LauncherError.io("Quarantine destination missing") }
        defer { close(target) }
        guard let item = try entry(source.components.last!, parent: parent), item.st_mode & S_IFMT != S_IFDIR,
            expected.sameObject(as: ClaimStamp(item)) else { return false }
        try fileOps.rename(from: source.components.last!, in: parent, to: destination.components.last!, in: target, exclusive: true)
        afterRename()
        guard let moved = try targetFS.entry(destination.components.last!, parent: target) else {
            throw LauncherError.io("Quarantine destination changed after rename")
        }
        try didMove(ClaimStamp(moved))
        try synchronize(parent)
        try targetFS.synchronize(target)
        return true
    }

    private static func hashClaimDescriptor(_ fd: Int32) throws -> (stamp: ClaimStamp, sha256: Digest) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_nlink > 0 else {
            throw LauncherError.io("Claim source must be a linked regular file")
        }
        let before = ClaimStamp(info)
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw LauncherError.io("Cannot seek claimed file") }
        var remaining = before.size, bytes = [UInt8](repeating: 0, count: 65_536), hash = StreamingHasher(.sha256)
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Int(min(remaining, Int64($0.count)))) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LauncherError.io("Claimed file changed while reading") }
            bytes.withUnsafeBytes { hash.update(buffer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            remaining -= Int64(count)
        }
        guard fstat(fd, &info) == 0, ClaimStamp(info) == before else { throw LauncherError.io("Claimed file changed during verification") }
        return (before, hash.finalize())
    }
}

/// Immutable descriptor ownership shared by copies of a pinned filesystem.
private final class RootDescriptor: Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }
}

extension ContainedFileSystem {
    /// Birth time also excludes reuse of a formerly owned inode after its unlink.
    package struct OwnedFileIdentity: Codable, Equatable, Sendable {
        package let device: Int64, inode: UInt64, birthSeconds: Int64, birthNanos: Int64
        fileprivate init(_ info: stat) {
            device = Int64(info.st_dev); inode = UInt64(info.st_ino)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec); birthNanos = Int64(info.st_birthtimespec.tv_nsec)
        }
        fileprivate func matches(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && self == Self(info)
        }
    }

    package func createOwnedFile(at path: SafeRelativePath) throws -> OwnedRegularFile? {
        guard let parent = try directory(Array(path.components.dropLast()), create: true) else { throw LauncherError.io("Owned-file parent is missing") }
        let fd = openat(parent, path.components.last!, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno; close(parent)
            if code == EEXIST { return nil }
            throw LauncherError.fileSystemFailure("Cannot create owned file", code: code)
        }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else { throw LauncherError.io("Cannot inspect owned file") }
            try synchronize(parent)
            return OwnedRegularFile(fs: self, path: path, parent: parent, fd: fd, identity: OwnedFileIdentity(info))
        } catch { close(fd); close(parent); throw error }
    }

    package func openOwnedFile(at path: SafeRelativePath, matching identity: OwnedFileIdentity) throws -> OwnedRegularFile? {
        guard let parent = try directory(Array(path.components.dropLast()), create: false) else { return nil }
        let fd = openat(parent, path.components.last!, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { close(parent); return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, identity.matches(info) else { close(fd); close(parent); return nil }
        return OwnedRegularFile(fs: self, path: path, parent: parent, fd: fd, identity: identity)
    }

    /// Mutable descriptor operations are serialized by the caller. No mutation
    /// reopens the public name, including after that name is exchanged or unlinked.
    package final class OwnedRegularFile: Sendable {
        fileprivate let fs: ContainedFileSystem
        fileprivate let path: SafeRelativePath
        fileprivate let parent: Int32
        fileprivate let fd: Int32
        package let identity: OwnedFileIdentity
        fileprivate init(fs: ContainedFileSystem, path: SafeRelativePath, parent: Int32, fd: Int32, identity: OwnedFileIdentity) {
            self.fs = fs; self.path = path; self.parent = parent; self.fd = fd; self.identity = identity
        }
        deinit { close(fd); close(parent) }
        package func duplicateForSpawning() throws -> Int32 {
            _ = try size()
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 3)
            guard copy >= 0 else { throw LauncherError.io("Cannot duplicate owned output") }
            return copy
        }
        package func size() throws -> Int64 {
            var info = stat()
            guard fstat(fd, &info) == 0, identity.matches(info) else { throw LauncherError.io("Owned file identity changed") }
            return info.st_size
        }
        @discardableResult package func append(_ data: Data) throws -> Int64 {
            let count = try data.withUnsafeBytes { try fs.fileOps.write(fd, bytes: $0) }
            guard count == data.count else { throw LauncherError.io("Short owned-file append") }
            return try size()
        }
        package func fullSync() throws { try fs.fileOps.synchronize(fd, durable: true) }
        package func cap(bytes limit: Int64, marker: Data) throws {
            guard limit >= marker.count else { throw LauncherError.io("Log cap is too small") }
            guard try size() >= limit else { return }
            // Darwin pwrite honors its offset even with O_APPEND. Never toggle
            // that flag: the child may share this open description through dup2.
            // Shrink even if a full volume prevents the marker's COW write.
            guard ftruncate(fd, off_t(limit)) == 0 else { throw LauncherError.fileSystemFailure("Cannot shrink owned log") }
            let written = marker.withUnsafeBytes { bytes in
                var count: Int
                repeat { count = Darwin.pwrite(fd, bytes.baseAddress, bytes.count, off_t(limit - Int64(bytes.count))) } while count < 0 && errno == EINTR
                return count
            }
            let shrunk = ftruncate(fd, off_t(limit)) == 0
            guard written == marker.count, shrunk else { throw LauncherError.fileSystemFailure("Cannot cap owned log") }
        }
        package func withClaim<T>(_ body: (borrowing RegularFileClaim) throws -> T) throws -> T {
            let verified = try ContainedFileSystem.hashClaimDescriptor(fd)
            guard verified.stamp.links == 1, let named = try fs.entry(path.components.last!, parent: parent),
                identity.matches(named), ClaimStamp(named) == verified.stamp else { throw LauncherError.io("Owned copy changed before claim") }
            let claim = RegularFileClaim(fileSystem: fs, parent: parent, descriptor: fd, source: path, stamp: verified.stamp, sha256: verified.sha256)
            return try body(claim)
        }
        package func removeIfNamed() throws -> Bool { try fs.removeOwnedFile(at: path, matching: identity) }
    }

}

extension ContainedFileSystem.RegularFileClaim {
    package func copyBytes(to output: ContainedFileSystem.OwnedRegularFile) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw LauncherError.io("Cannot seek copy source") }
        var remaining = stamp.size, hash = StreamingHasher(.sha256)
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(remaining))) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LauncherError.io("Copy source changed") }
            let data = Data(bytes.prefix(count)); hash.update(data)
            try output.fs.fileOps.writeAll(data, to: output.fd)
            remaining -= Int64(count)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, ContainedFileSystem.ClaimStamp(info) == stamp, hash.finalize() == sha256 else {
            throw LauncherError.io("Copy source changed during read")
        }
    }
    package func readData(maxBytes: Int) throws -> Data {
        guard stamp.size <= maxBytes, lseek(descriptor, 0, SEEK_SET) == 0 else { throw LauncherError.io("Claim exceeds read limit") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        while data.count < stamp.size {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, Int(stamp.size) - data.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LauncherError.io("Claim changed during read") }
            data.append(contentsOf: bytes.prefix(count))
        }
        var hash = StreamingHasher(.sha256); hash.update(data)
        var info = stat()
        guard fstat(descriptor, &info) == 0, ContainedFileSystem.ClaimStamp(info) == stamp, hash.finalize() == sha256 else { throw LauncherError.io("Claim changed during read") }
        return data
    }
    package func fullSync() throws { try fileSystem.fileOps.synchronize(descriptor, durable: true) }
    package func ownedIdentity() throws -> ContainedFileSystem.OwnedFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect claimed inode") }
        return ContainedFileSystem.OwnedFileIdentity(info)
    }
}

extension ContainedFileSystem {
    /// Claim a known inode into a private, pinned namespace before unlinking it.
    /// A replacement raced into the public name is returned with RENAME_EXCL,
    /// or left durably identified in the private claim if the public name is busy.
    @discardableResult package func removeOwnedFile(at source: SafeRelativePath, matching expected: OwnedFileIdentity) throws -> Bool {
        guard let parent = try directory(Array(source.components.dropLast()), create: false) else { return false }
        defer { close(parent) }
        guard let info = try entry(source.components.last!, parent: parent), expected.matches(info) else { return false }
        let folder = try SafeRelativePath((Array(source.components.dropLast()) + [".macgacha-remove-\(UUID().uuidString)"]).joined(separator: "/"))
        try createDirectoryDurably(at: folder)
        let claimed = try SafeRelativePath(folder.description + "/file")
        let note = try SafeRelativePath(folder.description + "/ownership.json")
        struct Removal: Codable { let source: SafeRelativePath; let expected: OwnedFileIdentity; var moved: ClaimStamp? }
        var record = Removal(source: source, expected: expected)
        try writeAtomically(JSONEncoder().encode(record), to: note)
        var observed: ClaimStamp?
        guard try quarantineEntry(at: source, to: claimed, in: self, matching: ClaimStamp(info), didMove: { moved in
            observed = moved; record.moved = moved
            try writeAtomically(JSONEncoder().encode(record), to: note)
        }) else { return false }
        guard let observed, let privateFD = try directory(folder.components, create: false) else { return false }
        defer { close(privateFD) }
        guard let movedInfo = try entry("file", parent: privateFD) else { return false }
        if !expected.matches(movedInfo) {
            if try entryStamp(at: source) == nil {
                _ = try quarantineEntry(at: claimed, to: source, in: self, matching: observed, didMove: { moved in
                    record.moved = moved; try writeAtomically(JSONEncoder().encode(record), to: note)
                })
            }
            return false
        }
        // Only the claimed inode enters this private namespace. The directory fd
        // stays pinned; replacing its public name cannot redirect the final unlink.
        guard let item = try entry("file", parent: privateFD), expected.matches(item) else { return false }
        try fileOps.unlink("file", in: privateFD, isDirectory: false)
        try synchronize(privateFD)
        try removeFile(at: note)
        try removeEmptyDirectory(at: folder)
        return true
    }
}
