// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

public struct ManifestFile: Codable, Sendable {
    public let path: SafeRelativePath
    public let size: Int64
    public let digest: Digest

    /// Programmatically constructed entries are validated by verify before any file is read.
    public init(path: SafeRelativePath, size: Int64, digest: Digest) {
        self.path = path; self.size = size; self.digest = digest
    }

    public init(_ task: FileTask) { self.init(path: task.path, size: task.size, digest: task.digest) }

    private enum CodingKeys: String, CodingKey { case path, size, digest }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try values.decode(SafeRelativePath.self, forKey: .path),
            size: try values.decode(Int64.self, forKey: .size), digest: try values.decode(Digest.self, forKey: .digest))
        guard size >= 0 else { throw LauncherError.io("invalid manifest file size") }
    }
}

public enum FileProblem: Sendable, Equatable {
    case missing
    case sizeMismatch(actual: Int64)
    case digestMismatch(actual: Digest)
    case notRegularFile
}

public struct VerifyReport: Sendable {
    public let problems: [SafeRelativePath: FileProblem]
    /// Non-excluded entries inspected, including missing or non-regular files.
    public let checkedFiles: Int
    /// Bytes actually hashed. Quick verification and initial size mismatches contribute zero.
    public let checkedBytes: Int64
    public var isClean: Bool { problems.isEmpty }

    public init(problems: [SafeRelativePath: FileProblem], checkedFiles: Int, checkedBytes: Int64) {
        self.problems = problems; self.checkedFiles = checkedFiles; self.checkedBytes = checkedBytes
    }
}

public struct Verifier: Sendable {
    public enum Mode: Sendable, Equatable { case quick, full }
    public init() {}

    /// Reads regular files through fs, with at most maxConcurrent workers and 64 KiB per read.
    /// Progress receives hashed-byte deltas on worker tasks and may be called concurrently.
    public func verify(fs: ContainedFileSystem, files: [ManifestFile], excluding: Set<SafeRelativePath> = [],
        mode: Mode = .full, maxConcurrent: Int = 4,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> VerifyReport {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard maxConcurrent > 0 else { throw LauncherError.io("maxConcurrent must be positive") }
        var seen = Set<String>(), active: [ManifestFile] = []
        var total: Int64 = 0
        for file in files {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard file.size >= 0 else { throw LauncherError.io("invalid manifest file size") }
            let key = file.path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { throw LauncherError.io("duplicate manifest path: \(file.path)") }
            if excluding.contains(file.path) { continue }
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw LauncherError.io("verification byte count overflow") }
            total = sum; active.append(file)
        }
        try InstallStateMarker.requireIdle(fs: fs)
        do {
            let report = try await withThrowingTaskGroup(of: FileResult.self) { group in
                var cursor = 0, checked = 0
                var bytes: Int64 = 0
                var problems: [SafeRelativePath: FileProblem] = [:]
                func submit(_ file: ManifestFile) {
                    group.addTask { try await Self.inspect(file, fs: fs, mode: mode, progress: progress) }
                }
                while cursor < min(maxConcurrent, active.count) { submit(active[cursor]); cursor += 1 }
                while let result = try await group.next() {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    checked += 1
                    let (sum, overflow) = bytes.addingReportingOverflow(result.bytes)
                    guard !overflow else { throw LauncherError.io("verification byte count overflow") }
                    bytes = sum
                    if let problem = result.problem { problems[result.path] = problem }
                    if cursor < active.count { submit(active[cursor]); cursor += 1 }
                }
                return VerifyReport(problems: problems, checkedFiles: checked, checkedBytes: bytes)
            }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            try InstallStateMarker.requireIdle(fs: fs)
            return report
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private struct FileResult: Sendable {
        let path: SafeRelativePath
        let problem: FileProblem?
        var bytes: Int64 = 0
    }

    @concurrent
    private static func inspect(_ file: ManifestFile, fs: ContainedFileSystem, mode: Mode,
        progress: @Sendable (Int64) -> Void) async throws -> FileResult {
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard let type = try fs.itemType(at: file.path, allowingLeafSymlink: true) else {
                return FileResult(path: file.path, problem: .missing)
            }
            guard type == .regularFile else { return FileResult(path: file.path, problem: .notRegularFile) }
            let handle = try fs.openForReading(at: file.path)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect file: \(file.path)") }
            guard info.st_size == file.size else {
                return FileResult(path: file.path, problem: .sizeMismatch(actual: info.st_size))
            }
            if mode == .quick { return FileResult(path: file.path, problem: nil) }
            // The size from this opened descriptor bounds the read even if the file grows.
            var hasher = StreamingHasher(file.digest.algorithm)
            var checked: Int64 = 0
            while checked < file.size {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let data = try autoreleasepool { try handle.read(upToCount: Int(min(65_536, file.size - checked))) ?? Data() }
                if data.isEmpty {
                    return FileResult(path: file.path, problem: .sizeMismatch(actual: checked), bytes: checked)
                }
                hasher.update(data); checked += Int64(data.count)
                progress(Int64(data.count))
            }
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw LauncherError.io("Cannot inspect file: \(file.path)") }
            if info.st_size != file.size {
                return FileResult(path: file.path, problem: .sizeMismatch(actual: info.st_size), bytes: checked)
            }
            let actual = hasher.finalize()
            return FileResult(path: file.path, problem: actual == file.digest ? nil : .digestMismatch(actual: actual), bytes: checked)
        } catch LauncherError.unsafePath {
            return FileResult(path: file.path, problem: .notRegularFile)
        } catch let error as LauncherError { throw error }
        catch { throw LauncherError.io("Cannot verify file: \(file.path)") }
    }
}

/// Rebuild broken files using remote objects exclusively, keeping the original file order.
/// Unknown report paths and local extents without fallbacks are rejected before execution.
public func repairPlan(from report: VerifyReport, plan: InstallPlan, id: SafeIdentifier) throws -> InstallPlan {
    guard !Task.isCancelled else { throw LauncherError.cancelled }
    try plan.validate()
    let known = Set(plan.files.map(\.path))
    let unknown = Set(report.problems.keys).subtracting(known)
    guard unknown.isEmpty else {
        throw LauncherError.io("repair report contains unknown paths: " + unknown.map(\.description).sorted().joined(separator: ", "))
    }
    var files: [FileTask] = [], unrepairable: [String] = []
    var references = Set<String>()
    for file in plan.files where report.problems[file.path] != nil {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        var extents: [Extent] = []
        var canRepair = true
        for extent in file.extents {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            switch extent.source {
            case .chunk(let object):
                references.insert(object); extents.append(extent)
            case .local:
                guard let fallback = extent.fallbackChunkID else { canRepair = false; continue }
                references.insert(fallback)
                extents.append(Extent(source: .chunk(id: fallback), fileOffset: extent.fileOffset,
                    length: extent.length, digest: extent.digest))
            }
        }
        if !canRepair { unrepairable.append(file.path.description) }
        files.append(FileTask(path: file.path, size: file.size, digest: file.digest, extents: extents))
    }
    guard unrepairable.isEmpty else { throw LauncherError.io("unrepairable: " + unrepairable.sorted().joined(separator: ", ")) }
    let repair = InstallPlan(id: id, objects: plan.objects.filter { references.contains($0.key) }, files: files)
    try repair.validate()
    return repair
}
