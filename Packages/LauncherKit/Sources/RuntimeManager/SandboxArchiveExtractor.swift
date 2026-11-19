// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// The optional editor package owns only BeyondAssets and its configured root list.
/// Unlike runtime archives it must never materialize links or unrelated game files.
public struct SandboxArchiveExtractor: Sendable {
    private let maxExpandedBytes: Int64
    private let maxEntries: Int

    /// Smaller limits support callers with a tighter budget; the package caps remain fixed.
    public init(maxExpandedBytes: Int64 = 4 << 30, maxEntries: Int = 20_000) {
        self.maxExpandedBytes = maxExpandedBytes
        self.maxEntries = maxEntries
    }

    public func expandedSize(archive: SafeRelativePath, in fs: ContainedFileSystem,
        listPath: SafeRelativePath) async throws -> Int64 {
        do {
            return try await BlockingIO.run {
                let handle = try fs.openForReading(at: archive)
                defer { try? handle.close() }
                return try scan(handle, listPath: listPath).reduce(Int64(0)) { $0 + $1.size }
            }
        } catch is CancellationError { throw LauncherError.cancelled }
    }

    /// Extract into a new or empty contained staging directory. A failed extraction is
    /// removed after joining uncancelled cleanup; a nonempty existing target is preserved.
    public func extract(archive: SafeRelativePath, in fs: ContainedFileSystem,
        to target: SafeRelativePath, listPath: SafeRelativePath,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        do {
            try await BlockingIO.run {
                let handle = try fs.openForReading(at: archive)
                defer { try? handle.close() }
                let entries = try scan(handle, listPath: listPath)
                let total = entries.reduce(Int64(0)) { $0 + $1.size }
                if let type = try fs.itemType(at: target) {
                    guard type == .directory else { throw LauncherError.unsafePath(target.description) }
                    guard try fs.contentsOfDirectory(at: target).isEmpty else {
                        throw LauncherError.io("Extraction target must be empty")
                    }
                }
                try fs.createDirectory(at: target)
                do {
                    var done: Int64 = 0, index = 0
                    progress(0, total)
                    try handle.seek(toOffset: 0)
                    _ = try ArchiveExtractor.scan(handle, format: .zip, limit: maxExpandedBytes,
                        maxEntries: maxEntries, fileOps: fs.fileOps, requireExactSizes: true,
                        progress: { count in done += count; progress(done, total) }, output: { entry in
                        // The pinned descriptor is reused, and a changed member must agree
                        // with the complete policy-checked preflight before opening output.
                        guard index < entries.count, Self.matches(entry, entries[index]) else {
                            throw LauncherError.io("Archive changed during extraction")
                        }
                        index += 1
                        let directory: Bool = if case .directory = entry.kind { true } else { false }
                        let name = try ArchivePolicy.normalized(entry.path, directory: directory)
                        let path = try SafeRelativePath((target.components + SafeRelativePath(name).components).joined(separator: "/"))
                        switch entry.kind {
                        case .directory: try fs.createDirectory(at: path); return nil
                        case .file: return try fs.openForWriting(at: path, truncate: true)
                        case .symlink, .hardlink: throw LauncherError.unsafePath(entry.path)
                        }
                    })
                    guard index == entries.count, done == total else { throw LauncherError.io("Archive changed during extraction") }
                    let tree = try fs.inspectTree(at: target)
                    guard tree.count <= maxEntries else { throw LauncherError.io("Archive entry limit exceeded") }
                    let actual = tree.map { ArchiveEntry(path: $0.path.description,
                        kind: $0.linkTarget.map { .symlink($0) } ?? ($0.type == .directory ? .directory : .file), size: $0.size) }
                    try Self.validate(actual, listPath: listPath)
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    progress(total, total)
                } catch {
                    try? await BlockingIO.finish { try fs.removeItem(at: target) }
                    if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                    throw error
                }
            }
        } catch is CancellationError { throw LauncherError.cancelled }
    }

    private func scan(_ handle: FileHandle, listPath: SafeRelativePath) throws -> [ArchiveEntry] {
        guard (0...(4 << 30)).contains(maxExpandedBytes), (1...20_000).contains(maxEntries) else {
            throw LauncherError.io("Invalid sandbox archive limits")
        }
        var spellings: [String: String] = [:]
        let entries = try ArchiveExtractor.scan(handle, format: .zip, limit: maxExpandedBytes,
            maxEntries: maxEntries, requireExactSizes: true, validateZIPName: { name in
                // libarchive can normalize Unicode spelling on macOS. Check raw ZIP
                // records too so distinct implicit directories cannot merge unnoticed.
                let path = try ArchivePolicy.normalized(name, directory: name.utf8.last == 47)
                if !path.isEmpty { try Self.registerSpelling(path, in: &spellings) }
            })
        try Self.validate(entries, listPath: listPath)
        return entries
    }

    static func validate(_ entries: [ArchiveEntry], listPath: SafeRelativePath) throws {
        guard listPath.components.count == 1,
            listPath.description.caseInsensitiveCompare("BeyondAssets") != .orderedSame else {
            throw LauncherError.unsafePath("Invalid sandbox package list path")
        }
        try ArchivePolicy.validate(entries)
        var spellings: [String: String] = [:]
        var hasList = false, hasAssets = false
        for entry in entries {
            let directory: Bool
            switch entry.kind {
            case .file: directory = false
            case .directory:
                guard entry.size == 0 else { throw LauncherError.unsafePath(entry.path) }
                directory = true
            case .symlink, .hardlink: throw LauncherError.unsafePath(entry.path)
            }
            let name = try ArchivePolicy.normalized(entry.path, directory: directory)
            if name.utf8.elementsEqual(listPath.description.utf8) && !directory { hasList = true }
            else if name.hasPrefix("BeyondAssets/") || (name == "BeyondAssets" && directory) { hasAssets = true }
            else { throw LauncherError.unsafePath(entry.path) }
            try registerSpelling(name, in: &spellings)
        }
        guard hasList, hasAssets else { throw LauncherError.io("Sandbox archive package roots are missing") }
    }

    private static func registerSpelling(_ name: String, in spellings: inout [String: String]) throws {
        let parts = try SafeRelativePath(name).components
        // Include implicit directories: Dir/a and dir/b would otherwise merge
        // silently on a case-insensitive volume without duplicate leaf names.
        for count in 1...parts.count {
            let spelling = parts.prefix(count).joined(separator: "/")
            let key = spelling.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX"))
            if let prior = spellings[key], !prior.utf8.elementsEqual(spelling.utf8) {
                throw LauncherError.unsafePath(name)
            }
            spellings[key] = spelling
        }
    }

    private static func matches(_ lhs: ArchiveEntry, _ rhs: ArchiveEntry) -> Bool {
        guard lhs.path.utf8.elementsEqual(rhs.path.utf8), lhs.size == rhs.size else { return false }
        switch (lhs.kind, rhs.kind) {
        case (.file, .file), (.directory, .directory): return true
        default: return false
        }
    }
}
