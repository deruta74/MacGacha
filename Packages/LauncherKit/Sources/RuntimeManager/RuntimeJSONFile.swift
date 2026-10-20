import Darwin
import Foundation
import LauncherCore

enum RuntimeJSONFile {
    static func read(_ url: URL, limit: Int) throws -> Data? {
        guard url.isFileURL else { throw LauncherError.io("Runtime JSON requires a file URL") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LauncherError.unsafePath(url.path) }
            throw LauncherError.io("Cannot open runtime JSON")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= limit else { throw LauncherError.io("Runtime JSON is not a regular file or exceeds size limit") }
        var remaining = Int(info.st_size)
        var data = Data()
        while remaining > 0 {
            let piece = try autoreleasepool { try handle.read(upToCount: min(65_536, remaining)) ?? Data() }
            guard !piece.isEmpty else { break }
            data.append(piece)
            remaining -= piece.count
        }
        return data
    }

    static func write<T: Encodable>(_ value: T, to url: URL, limit: Int) throws {
        guard url.isFileURL else { throw LauncherError.io("Runtime JSON requires a file URL") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw LauncherError.io("Runtime JSON exceeds size limit") }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try directoryExists(parent)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw LauncherError.unsafePath(url.path) }
        } else if errno != ENOENT {
            throw LauncherError.io("Cannot inspect runtime JSON destination")
        }
        try data.write(to: url, options: .atomic)
    }

    static func directoryExists(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw LauncherError.io("Runtime directory requires a file URL") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw LauncherError.io("Cannot inspect runtime directory")
        }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw LauncherError.unsafePath(url.path) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LauncherError.io("Runtime path is not a directory") }
        return true
    }
}
