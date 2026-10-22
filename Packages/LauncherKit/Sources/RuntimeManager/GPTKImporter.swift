// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

public struct GPTKCandidate: Sendable, Equatable {
    /// The framework's parent folder; this entire folder is copied during import.
    public let root: URL
    public let d3dmetalFramework: URL
    public let version: String?

    public init(root: URL, d3dmetalFramework: URL, version: String?) {
        self.root = root.isFileURL ? URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true) : root
        self.d3dmetalFramework = d3dmetalFramework.isFileURL
            ? URL(fileURLWithPath: d3dmetalFramework.standardizedFileURL.path, isDirectory: true) : d3dmetalFramework
        self.version = version
    }
}

public struct GPTKImporter: Sendable {
    /// Shared across all search roots in one locate call. Exhaustion returns partial results.
    public static let searchEntryLimit = 100_000
    public static let importByteLimit: Int64 = 64 << 30
    private let searchRoots: [URL]
    private let maxDepth: Int
    private let maxEntries: Int
    private let readDirectoryEntry: @Sendable (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    public init(searchRoots: [URL] = [URL(fileURLWithPath: "/Volumes")], maxDepth: Int = 5,
        maxEntries: Int = GPTKImporter.searchEntryLimit) {
        self.init(searchRoots: searchRoots, maxDepth: maxDepth, maxEntries: maxEntries,
            readDirectoryEntry: { readdir($0) })
    }

    // Package tests can count actual reads without time-sensitive assertions.
    init(searchRoots: [URL], maxDepth: Int, maxEntries: Int,
        readDirectoryEntry: @escaping @Sendable (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?) {
        self.searchRoots = searchRoots; self.maxDepth = maxDepth; self.maxEntries = maxEntries
        self.readDirectoryEntry = readDirectoryEntry
    }

    /// Best-effort discovery: unreadable/missing directories and symlinks are skipped.
    /// The root has depth zero. A shared entry budget bounds even very wide trees.
    public func locate() throws -> [GPTKCandidate] {
        guard maxDepth >= 0, maxDepth < 128, maxEntries > 0, maxEntries <= Self.searchEntryLimit else {
            throw LauncherError.io("Invalid GPTK search limits")
        }
        var remaining = maxEntries
        var candidates: [GPTKCandidate] = []
        var seen: Set<String> = []
        func visit(_ fd: Int32, url: URL, searchRoot: URL, depth: Int, remaining: inout Int) throws {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            if url.lastPathComponent == "D3DMetal.framework", seen.insert(url.path).inserted {
                candidates.append(GPTKCandidate(root: url.deletingLastPathComponent(), d3dmetalFramework: url,
                    version: try nearestVersion(framework: url, descriptor: fd, searchRoot: searchRoot, remaining: &remaining)))
            }
            guard depth < maxDepth, remaining > 0 else { return }
            try forEachDirectoryEntry(fd, remaining: &remaining) { name, remaining in
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
                let child = openat(fd, name, Self.directoryFlags)
                guard child >= 0 else { return }
                defer { close(child) }
                try visit(child, url: url.appendingPathComponent(name, isDirectory: true), searchRoot: searchRoot,
                    depth: depth + 1, remaining: &remaining)
            }
        }
        for root in searchRoots {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard remaining > 0 else { break }
            remaining -= 1
            guard root.isFileURL, !root.path.utf8.contains(0) else { throw LauncherError.unsafePath(root.absoluteString) }
            let url = root.standardizedFileURL
            let fd = open(url.path, Self.directoryFlags)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            try visit(fd, url: url, searchRoot: url, depth: 0, remaining: &remaining)
        }
        return candidates.sorted { $0.d3dmetalFramework.path < $1.d3dmetalFramework.path }
    }

    /// Charges each raw entry before decoding, inspecting or retaining it. The same
    /// budget is passed through recursive discovery and framework version lookup.
    private func forEachDirectoryEntry(_ fd: Int32, remaining: inout Int,
        visit: (String, inout Int) throws -> Void) throws {
        guard remaining > 0 else { return }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { return }
        guard let stream = fdopendir(duplicate) else { close(duplicate); return }
        defer { closedir(stream) }
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let item = readDirectoryEntry(stream) else { break } // Unreadable directories are best-effort.
            let raw = withUnsafeBytes(of: item.pointee.d_name) { Array($0.prefix { $0 != 0 }) }
            if raw == [46] || raw == [46, 46] { continue }
            remaining -= 1
            guard let name = String(bytes: raw, encoding: .utf8) else { continue }
            try visit(name, &remaining)
        }
    }

    /// Uses the manifest's current terms revision; a version alone cannot authorize consent.
    public func importCandidate(_ candidate: GPTKCandidate, component: RuntimeComponent,
        into store: RuntimeStore, consent: ConsentStore) async throws -> InstalledComponent {
        let installer = ComponentInstaller(store: store, consent: consent, disk: SystemDiskSpaceProbe())
        for try await _ in installer.install(component, from: candidate) { }
        guard let installed = try await BlockingIO.run({ try store.installed().first(where: { $0.kind == component.kind && $0.version == component.version.rawValue }) }) else {
            throw LauncherError.io("Imported runtime marker is missing")
        }
        return installed
    }

    private func nearestVersion(framework: URL, descriptor: Int32, searchRoot: URL, remaining: inout Int) throws -> String? {
        let fs = try ContainedFileSystem(root: searchRoot)
        func readVersion(_ url: URL) throws -> String? {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let path = try RuntimeJSONFile.relativePath(url, root: searchRoot)
            do {
                let data = try fs.readFile(at: path, maxBytes: 1 << 20)
                if let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    let version = dictionary["CFBundleShortVersionString"] as? String,
                    !version.isEmpty, version.utf8.count <= 1024 { return version }
            } catch LauncherError.cancelled { throw LauncherError.cancelled }
              catch { } // Unreadable/malformed/symlinked plists do not prevent discovery.
            return nil
        }
        for name in ["Info.plist", "Resources/Info.plist"] {
            if let version = try readVersion(framework.appendingPathComponent(name)) { return version }
        }
        // Real frameworks often keep Resources behind Versions/Current symlinks.
        // Inspect actual version directories instead of following those aliases.
        let versionsURL = framework.appendingPathComponent("Versions")
        if remaining > 0 {
            let versionsFD = openat(descriptor, "Versions", Self.directoryFlags)
            if versionsFD >= 0 {
                defer { close(versionsFD) }
                do {
                    var versions: [String] = []
                    try forEachDirectoryEntry(versionsFD, remaining: &remaining) { name, _ in versions.append(name) }
                    // Only the bounded set already read and charged is sorted/inspected.
                    for name in versions.sorted() {
                        var info = stat()
                        guard fstatat(versionsFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                            info.st_mode & S_IFMT == S_IFDIR else { continue }
                        let versionURL = versionsURL.appendingPathComponent(name, isDirectory: true)
                        for plist in ["Info.plist", "Resources/Info.plist"] {
                            if let version = try readVersion(versionURL.appendingPathComponent(plist)) { return version }
                        }
                    }
                } catch LauncherError.cancelled { throw LauncherError.cancelled }
                  catch { }
            }
        }
        var current = framework
        while current.path != searchRoot.path {
            current.deleteLastPathComponent()
            if let version = try readVersion(current.appendingPathComponent("Info.plist")) { return version }
        }
        return nil
    }

}

/// An immutable pre-scan; no source links are followed, and all links are validated
/// together before staging is created. Source mutations are detected while copying.
struct GPTKImportSource: Sendable {
    private let fs: ContainedFileSystem
    private let path: SafeRelativePath
    private let entries: [ContainedFileSystem.TreeEntry]
    private let sizes: [SafeRelativePath: Int64]
    let size: Int64

    init(candidate: GPTKCandidate, maxBytes: Int64) throws {
        guard candidate.root.isFileURL, candidate.d3dmetalFramework.isFileURL,
            candidate.d3dmetalFramework.lastPathComponent == "D3DMetal.framework",
            candidate.d3dmetalFramework.deletingLastPathComponent().standardizedFileURL == candidate.root.standardizedFileURL else {
            throw LauncherError.unsafePath(candidate.root.absoluteString)
        }
        let fs = try ContainedFileSystem(root: candidate.root.deletingLastPathComponent())
        let path = try SafeRelativePath(candidate.root.lastPathComponent)
        let framework = try SafeRelativePath("\(path)/D3DMetal.framework")
        guard try fs.itemType(at: framework) == .directory else { throw LauncherError.unsafePath(framework.description) }
        let entries = try fs.inspectTree(at: path)
        try ArchivePolicy.validate(entries.map { item in
            ArchiveEntry(path: item.path.description,
                kind: item.linkTarget.map { .symlink($0) } ?? (item.type == .directory ? .directory : .file))
        })
        var sizes: [SafeRelativePath: Int64] = [:]
        var size: Int64 = 0
        for item in entries where item.type == .regularFile {
            let file = try SafeRelativePath("\(path)/\(item.path)")
            guard let count = try fs.size(at: file), count >= 0 else { throw LauncherError.io("Import source disappeared") }
            // Hardlinks are copied independently, so count the actual destination bytes.
            guard count <= maxBytes - size else { throw LauncherError.io("Runtime import size limit exceeded") }
            size += count; sizes[item.path] = count
        }
        self.fs = fs; self.path = path; self.entries = entries; self.sizes = sizes; self.size = size
    }

    func copy(into target: SafeRelativePath, fs destination: ContainedFileSystem) throws {
        try destination.createDirectory(at: target)
        var copied: Int64 = 0
        for item in entries {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let output = try SafeRelativePath("\(target)/\(item.path)")
            if item.type == .directory {
                try destination.createDirectory(at: output)
            } else if let link = item.linkTarget {
                try destination.createSymbolicLink(at: output, target: link)
            } else {
                let input = try SafeRelativePath("\(path)/\(item.path)")
                let count = try fs.copyRegularFile(at: input, to: output, in: destination, maxBytes: size - copied)
                guard count == sizes[item.path] else { throw LauncherError.io("Import source changed during copy") }
                copied += count
            }
        }
        let actual = try destination.inspectTree(at: target)
        try ArchivePolicy.validate(actual.map { item in
            ArchiveEntry(path: item.path.description,
                kind: item.linkTarget.map { .symlink($0) } ?? (item.type == .directory ? .directory : .file))
        })
    }
}
