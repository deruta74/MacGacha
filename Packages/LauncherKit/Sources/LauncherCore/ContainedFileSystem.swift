import Darwin
import Foundation

/// Operations below a trusted root. Ancestors above the root may be symlinks.
/// The root itself must be a directory, not a symlink. Traversal is limited to
/// 128 directories and listing/removal to 100,000 entries per operation.
public struct ContainedFileSystem: Sendable {
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

    /// Creates missing parent directories as well as the requested directory.
    public func createDirectory(at path: SafeRelativePath) throws {
        guard let fd = try directory(path.components, create: true) else { throw LauncherError.io("Cannot create directory") }
        close(fd)
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
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else {
                        throw LauncherError.io("Cannot create contained directory")
                    }
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
        while fsync(fd) != 0 {
            guard errno == EINTR else { throw LauncherError.io("Cannot synchronize file") }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
        }
    }

    private func display(_ components: [String]) -> String {
        components.reduce(root) { $0.appendingPathComponent($1) }.path
    }

    private func accessError(_ path: String) -> LauncherError {
        errno == ELOOP || errno == ENOTDIR ? .unsafePath(path) : .io("Cannot access contained path")
    }
}
