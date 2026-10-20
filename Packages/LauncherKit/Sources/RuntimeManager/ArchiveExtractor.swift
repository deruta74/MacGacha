// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import CArchive
import Darwin
import Foundation
import LauncherCore

public struct ArchiveExtractor: Sendable {
    private let runner: any ProcessRunner
    private let maxExpandedBytes: Int64
    private let maxEntries: Int

    /// Limits bound both the structured pre-scan and the extracted tree. No third-party
    /// library is bundled: structured metadata comes from macOS's system libarchive.
    public init(runner: any ProcessRunner, maxExpandedBytes: Int64 = 64 << 30, maxEntries: Int = 100_000) {
        self.runner = runner
        self.maxExpandedBytes = maxExpandedBytes
        self.maxEntries = maxEntries
    }

    /// Extracts only into an empty directory. Unsafe/failed extraction removes that staging
    /// directory; a pre-existing nonempty target is always preserved.
    public func extract(_ archive: URL, format: ArchiveFormat, into dir: URL) async throws {
        let archiveFS = try ContainedFileSystem(root: archive.deletingLastPathComponent())
        let archivePath = try SafeRelativePath(archive.lastPathComponent)
        let fs = try ContainedFileSystem(root: dir.deletingLastPathComponent())
        try await extract(archive: archivePath, archiveFS: archiveFS, archiveURL: archive,
            format: format, fs: fs, target: SafeRelativePath(dir.lastPathComponent), expandedLimit: maxExpandedBytes)
    }

    func extract(archive: SafeRelativePath, archiveFS: ContainedFileSystem, archiveURL: URL,
        format: ArchiveFormat, fs: ContainedFileSystem, target: SafeRelativePath, expandedLimit: Int64) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let limit = min(maxExpandedBytes, expandedLimit)
        guard limit >= 0, maxEntries > 0, maxEntries <= 100_000 else { throw LauncherError.io("Invalid archive limits") }
        let handle = try archiveFS.openForReading(at: archive)
        defer { try? handle.close() }
        let entries = try await Self.scan(handle, format: format, limit: limit, maxEntries: maxEntries)
        try ArchivePolicy.validate(entries)
        if let type = try fs.itemType(at: target) {
            guard type == .directory else { throw LauncherError.unsafePath(target.description) }
            guard try fs.contentsOfDirectory(at: target).isEmpty else { throw LauncherError.io("Extraction target must be empty") }
        }
        try fs.createDirectory(at: target)
        do {
            let targetURL = try fs.directoryURL(at: target)
            if format == .zip {
                try await run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, targetURL.path])
            } else {
                try await run("/usr/bin/tar", ["-xf", archiveURL.path, "-C", targetURL.path, "--no-same-owner", "--no-same-permissions"])
            }
            let actual = try fs.inspectTree(at: target)
            guard actual.count <= maxEntries else { throw LauncherError.io("Archive entry limit exceeded") }
            var bytes: Int64 = 0
            var inspected: [ArchiveEntry] = []
            for item in actual {
                bytes = try Self.addSize(bytes, item.size, limit: limit)
                inspected.append(ArchiveEntry(path: item.path.description,
                    kind: item.linkTarget.map { .symlink($0) } ?? (item.type == .directory ? .directory : .file)))
            }
            try ArchivePolicy.validate(inspected)
        } catch {
            // No recursive delete can follow a link left by a failed/malicious extraction.
            // Cancellation may leave hidden staging behind; the store startup sweep reclaims it.
            try? fs.removeItem(at: target)
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        let result = try await runner.run(URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["LC_ALL": "en_US.UTF-8", "COPYFILE_DISABLE": "1"], currentDirectory: nil)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard result.exitCode == 0 else {
            throw LauncherError.processFailed(executable: executable, exitCode: result.exitCode,
                stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
        }
    }

    @concurrent
    private static func scan(_ handle: FileHandle, format: ArchiveFormat, limit: Int64, maxEntries: Int) async throws -> [ArchiveEntry] {
        if format == .zip { try ZIPDirectory.validate(handle, maxEntries: maxEntries) }
        guard let reader = archive_read_new() else { throw LauncherError.io("Cannot initialize archive reader") }
        defer { archive_read_free(reader) }
        if format == .zip { archive_read_support_format_zip(reader) }
        else {
            archive_read_support_filter_gzip(reader)
            archive_read_support_filter_xz(reader)
            archive_read_support_format_tar(reader)
            // USTAR/GNU names are ASCII. PAX path/linkpath fields carry their own UTF-8
            // provenance and override this fallback charset, independent of process locale.
            guard archive_read_set_format_option(reader, "tar", "hdrcharset", "ASCII") == 0 else {
                throw LauncherError.io("Cannot configure tar filename encoding")
            }
        }
        guard archive_read_open_fd(reader, handle.fileDescriptor, 65_536) == 0 else { throw LauncherError.io("Cannot read archive") }
        var result: [ArchiveEntry] = []
        var total: Int64 = 0
        var metadata = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            guard let entry else { throw LauncherError.io("Invalid archive header") }
            guard result.count < maxEntries else { throw LauncherError.io("Archive entry limit exceeded") }
            guard let pointer = archive_entry_pathname_utf8(entry), let path = String(validatingCString: pointer) else {
                throw LauncherError.unsafePath("Invalid archive entry name")
            }
            // PAX may retain valid UTF-8 metadata despite ARCHIVE_WARN. Validate
            // every applicable accessor instead of depending on localized warnings.
            var hardlinkTarget: String?
            if archive_entry_hardlink(entry) != nil {
                guard let link = archive_entry_hardlink_utf8(entry), let target = String(validatingCString: link) else {
                    throw LauncherError.unsafePath(path)
                }
                hardlinkTarget = target
            }
            var symlinkTarget: String?
            if archive_entry_symlink(entry) != nil {
                guard let link = archive_entry_symlink_utf8(entry), let target = String(validatingCString: link) else {
                    throw LauncherError.unsafePath(path)
                }
                symlinkTarget = target
            }
            let pax = [0x30002, 0x30003].contains(archive_format(reader))
            guard status == 0 || (status == -20 && pax) else { throw LauncherError.unsafePath("Invalid archive entry name") }
            let size = archive_entry_size(entry)
            guard size >= 0, archive_entry_is_encrypted(entry) == 0 else { throw LauncherError.io("Invalid or encrypted archive entry") }
            let kind: ArchiveEntry.Kind
            if let hardlinkTarget {
                kind = .hardlink(hardlinkTarget)
            } else {
                switch archive_entry_filetype(entry) {
                case 0 where format == .zip: kind = path.utf8.last == 47 ? .directory : .file
                case S_IFREG: kind = .file
                case S_IFDIR: kind = .directory
                case S_IFLNK:
                    guard let symlinkTarget else { throw LauncherError.unsafePath(path) }
                    kind = .symlink(symlinkTarget)
                default: throw LauncherError.unsafePath(path)
                }
            }
            // A hardlink header does not carry new payload, regardless of its size field.
            if case .hardlink = kind { } else { total = try addSize(total, size, limit: limit) }
            metadata += path.utf8.count + (kind.link?.utf8.count ?? 0)
            guard metadata <= 16 << 20, path.utf8.count <= 4096, (kind.link?.utf8.count ?? 0) <= 4096 else {
                throw LauncherError.io("Archive metadata limit exceeded")
            }
            result.append(ArchiveEntry(path: path, kind: kind))
            // Drain in bounded pieces to validate data and observe cancellation even for one
            // huge compressed entry. The listing's declared size must agree with actual data.
            var read: Int64 = 0
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw LauncherError.io("Invalid archive data") }
                if count == 0 { break }
                read = try addSize(read, Int64(count), limit: min(size, limit))
            }
        }
        return result
    }

    private static func addSize(_ a: Int64, _ b: Int64, limit: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard b >= 0, !overflow, sum <= limit else {
            throw LauncherError.fileTooLarge(path: "archive", limit: Int(clamping: limit))
        }
        return sum
    }
}

struct ArchiveEntry: Sendable {
    enum Kind: Sendable {
        case file, directory, symlink(String), hardlink(String)
        var link: String? {
            switch self { case .symlink(let target), .hardlink(let target): return target; default: return nil }
        }
    }
    let path: String
    let kind: Kind
}

enum ArchivePolicy {
    private static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    // Shared by every link in this validation, not reset for each recursion or entry.
    private static let resolutionStepLimit = 4096

    static func validate(_ entries: [ArchiveEntry]) throws {
        var remainingSteps = resolutionStepLimit
        var byExactPath: [String: (kind: ArchiveEntry.Kind, index: Int)] = [:]
        var byPath: [String: ArchiveEntry.Kind] = [:]
        for (index, entry) in entries.enumerated() {
            let path = try normalized(entry.path, directory: { if case .directory = entry.kind { return true }; return false }())
            guard byPath.updateValue(entry.kind, forKey: key(path)) == nil else { throw LauncherError.unsafePath(entry.path) }
            byExactPath[path] = (entry.kind, index)
        }
        for (index, entry) in entries.enumerated() {
            let path = try normalized(entry.path, directory: { if case .directory = entry.kind { return true }; return false }())
            if path.isEmpty { continue } // A tar root directory entry (./).
            let parts = try SafeRelativePath(path).components
            for count in 1..<parts.count {
                if let kind = byPath[key(parts.prefix(count).joined(separator: "/"))] {
                    guard case .directory = kind else { throw LauncherError.unsafePath(entry.path) }
                }
            }
            switch entry.kind {
            case .symlink(let target):
                var visited: Set<String> = [key(path)]
                let resolved = try resolve(target, base: Array(parts.dropLast()), byPath: byPath,
                    visited: &visited, remainingSteps: &remainingSteps)
                guard resolved.count > parts.count || key(resolved.joined(separator: "/")) != key(parts.prefix(resolved.count).joined(separator: "/")) else {
                    throw LauncherError.unsafePath(entry.path)
                }
            case .hardlink(let target):
                let literal = try normalized(target, directory: false)
                guard let prior = byExactPath[literal], prior.index < index, case .file = prior.kind else {
                    throw LauncherError.unsafePath(entry.path)
                }
                let targetParts = try SafeRelativePath(literal).components
                for count in 1..<targetParts.count {
                    if let ancestor = byPath[key(targetParts.prefix(count).joined(separator: "/"))] {
                        guard case .directory = ancestor else { throw LauncherError.unsafePath(entry.path) }
                    }
                }
            default: break
            }
        }
    }

    private static func normalized(_ value: String, directory: Bool) throws -> String {
        guard value.utf8.first != 47, !value.utf8.contains(0), !value.utf8.contains(92),
            !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LauncherError.unsafePath(value) }
        let bytes = Array(value.utf8)
        var start = 0
        while start + 1 < bytes.count && bytes[start] == 46 && bytes[start + 1] == 47 { start += 2 }
        var path = String(decoding: bytes.dropFirst(start), as: UTF8.self)
        if directory && path.utf8.last == 47 { path.removeLast() }
        if directory && (path == "." || path.isEmpty) { return "" }
        let safe = try SafeRelativePath(path)
        guard safe.components.count <= 120 else { throw LauncherError.unsafePath(value) }
        return safe.description
    }

    private static func resolve(_ value: String, base: [String], byPath: [String: ArchiveEntry.Kind], visited: inout Set<String>, remainingSteps: inout Int) throws -> [String] {
        guard !value.isEmpty, value.utf8.first != 47, !value.utf8.contains(0), !value.utf8.contains(92), visited.count < 128 else {
            throw LauncherError.unsafePath(value)
        }
        var result = base
        // Byte splitting is essential: a slash followed by a combining mark is still a separator.
        for bytes in value.utf8.split(separator: 47, omittingEmptySubsequences: false) {
            guard remainingSteps > 0, !Task.isCancelled else {
                if Task.isCancelled { throw LauncherError.cancelled }
                throw LauncherError.unsafePath("Archive link resolution budget exceeded")
            }
            remainingSteps -= 1
            let part = String(decoding: bytes, as: UTF8.self)
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                guard !result.isEmpty else { throw LauncherError.unsafePath(value) }
                result.removeLast()
                continue
            }
            _ = try SafeRelativePath(part)
            result.append(part)
            guard result.count <= 120 else { throw LauncherError.unsafePath(value) }
            let path = key(result.joined(separator: "/"))
            if case .symlink(let target) = byPath[path] {
                guard visited.insert(path).inserted else { throw LauncherError.unsafePath(value) }
                result = try resolve(target, base: Array(result.dropLast()), byPath: byPath,
                    visited: &visited, remainingSteps: &remainingSteps)
            }
        }
        return result
    }
}
