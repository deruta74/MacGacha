import Foundation
import LauncherCore

enum RuntimeJSONFile {
    // An explicitly selected manifest uses its parent as a read-only trust anchor.
    static func read(_ url: URL, limit: Int) throws -> Data? {
        try read(url, root: url.deletingLastPathComponent(), limit: limit)
    }

    static func read(_ url: URL, root: URL, limit: Int) throws -> Data? {
        let fs = try ContainedFileSystem(root: root)
        return try read(relativePath(url, root: root), in: fs, limit: limit)
    }

    static func read(_ path: SafeRelativePath, in fs: ContainedFileSystem, limit: Int) throws -> Data? {
        guard try fs.itemType(at: path) != nil else { return nil }
        return try fs.readFile(at: path, maxBytes: limit)
    }

    static func write<T: Encodable>(_ value: T, to url: URL, root: URL, limit: Int) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw LauncherError.io("Runtime JSON exceeds size limit") }
        let fs = try ContainedFileSystem(root: root)
        try fs.writeAtomically(data, to: relativePath(url, root: root))
    }

    private static func relativePath(_ url: URL, root: URL) throws -> SafeRelativePath {
        guard url.isFileURL, root.isFileURL else { throw LauncherError.io("Runtime JSON requires file URLs") }
        let base = root.path.split(separator: "/")
        let destination = url.path.split(separator: "/")
        guard destination.count > base.count, destination.starts(with: base) else {
            throw LauncherError.unsafePath(url.path)
        }
        return try SafeRelativePath(destination.dropFirst(base.count).joined(separator: "/"))
    }
}
