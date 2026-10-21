// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct PlannedCategory: Sendable {
    public let category: BuildCategory
    public let manifest: SophonManifest
    public init(category: BuildCategory, manifest: SophonManifest) {
        self.category = category; self.manifest = manifest
    }
}

public struct InstalledSnapshot: Sendable {
    public let categories: [PlannedCategory]
    public init(categories: [PlannedCategory]) { self.categories = categories }
}

public enum SophonPlanner {
    /// Pure: no disk, clock, randomness or mutable shared state. The returned plan
    /// has canonical byte ordering and can be saved for exact engine resume.
    public static func plan(id: SafeIdentifier, target: [PlannedCategory], installed: InstalledSnapshot?) throws -> InstallPlan {
        // Inspect every target reference before unchanged files or unused objects
        // are pruned. A conflict cannot be hidden by a particular update's reuse.
        var objects = try targetObjects(target)
        let targetFiles = try fileUnion(target)
        let oldFiles = try fileUnion(installed?.categories ?? [])
        let deletions = oldFiles.keys.filter { targetFiles[$0] == nil }.sorted { bytesLess($0.description, $1.description) }
        // Validate complete namespaces and layouts, including retained files that
        // will disappear from the emitted plan. Reuse the engine's path rules.
        if !oldFiles.isEmpty {
            _ = try completePlan(id: id, files: oldFiles, objects: [:], usingInstalledFiles: true)
        }
        if oldFiles.isEmpty {
            return try completePlan(id: id, files: targetFiles, objects: objects)
        }
        _ = try completePlan(id: id, files: targetFiles, objects: objects, deletions: deletions)
        let unchanged = Set(targetFiles.values.compactMap { file -> SafeRelativePath? in
            guard let old = oldFiles[file.path], old.size == file.size, old.md5 == file.md5 else { return nil }
            return file.path
        })
        var sources: [Content: Sources] = [:]
        for file in oldFiles.values {
            for chunk in file.chunks {
                sources[Content(chunk), default: Sources()].insert(path: file.path, offset: chunk.fileOffset,
                    unchanged: unchanged.contains(file.path))
            }
        }

        var files: [FileTask] = []
        var referenced = Set<String>()
        for file in targetFiles.values.sorted(by: { bytesLess($0.path.description, $1.path.description) }) {
            if unchanged.contains(file.path) { continue }
            let extents = file.chunks.map { chunk -> Extent in
                referenced.insert(chunk.id)
                let source: ExtentSource
                let fallback: String?
                if let local = sources[Content(chunk)]?.preferred(for: file.path) {
                    source = .local(path: local.path, offset: local.offset); fallback = chunk.id
                } else {
                    source = .chunk(id: chunk.id); fallback = nil
                }
                return Extent(source: source, fileOffset: chunk.fileOffset, length: chunk.decodedSize,
                    digest: chunk.decodedMD5, fallbackChunkID: fallback)
            }
            files.append(FileTask(path: file.path, size: file.size, digest: file.md5, extents: extents))
        }
        objects = objects.filter { referenced.contains($0.key) }
        let result = InstallPlan(id: id, objects: objects, files: files, deletions: deletions)
        try result.validate()
        return result
    }

    public static func fullPlan(id: SafeIdentifier, target: [PlannedCategory]) throws -> InstallPlan {
        try plan(id: id, target: target, installed: nil)
    }

    private static func completePlan(id: SafeIdentifier, files: [SafeRelativePath: SophonFile], objects: [String: ChunkObject],
        usingInstalledFiles: Bool = false, deletions: [SafeRelativePath] = []) throws -> InstallPlan {
        let tasks = files.values.sorted { bytesLess($0.path.description, $1.path.description) }.map { file in
            let extents = file.chunks.map { chunk in
                // Snapshot validation needs no old CDN descriptors: its extents
                // refer to their own installed file, solely for geometry checks.
                Extent(source: usingInstalledFiles ? .local(path: file.path, offset: chunk.fileOffset) : .chunk(id: chunk.id),
                    fileOffset: chunk.fileOffset, length: chunk.decodedSize, digest: chunk.decodedMD5)
            }
            return FileTask(path: file.path, size: file.size, digest: file.md5, extents: extents)
        }
        let result = InstallPlan(id: id, objects: objects, files: tasks, deletions: deletions)
        try result.validate()
        return result
    }

    public static func selectCategories(_ branch: GameBranch, build: SophonBuild, voices: Set<String>) throws -> [BuildCategory] {
        let knownVoices = Set(branch.categories.filter(\.isAudio).map(\.matchingField))
        guard voices.isSubset(of: knownVoices) else { throw LauncherError.io("unknown voice") }
        var available: [String: BuildCategory] = [:]
        for category in build.categories {
            if let prior = available[category.id], prior != category { throw LauncherError.io("conflicting build category") }
            available[category.id] = category
        }
        var selected: [String: BuildCategory] = [:]
        for category in branch.categories {
            guard let entry = available[category.id] else { throw LauncherError.io("missing build category") }
            guard entry.matchingField == category.matchingField else { throw LauncherError.io("category matching field mismatch") }
            if category.isAudio ? voices.contains(category.matchingField) : category.inFullScenario {
                selected[category.id] = entry
            }
        }
        return selected.values.sorted { bytesLess($0.id, $1.id) }
    }

    private static func targetObjects(_ target: [PlannedCategory]) throws -> [String: ChunkObject] {
        var objects: [String: ChunkObject] = [:]
        for planned in target {
            try planned.category.validate()
            for file in planned.manifest.files {
                for chunk in file.chunks {
                    let url = try planned.category.chunkURL(id: chunk.id)
                    if let prior = objects[chunk.id] {
                        guard prior.transferSize == chunk.compressedSize, prior.transferDigest == chunk.compressedMD5,
                              prior.decodedSize == chunk.decodedSize, prior.decodedDigest == chunk.decodedMD5 else {
                            throw LauncherError.io("conflicting chunk metadata")
                        }
                        if !prior.urls.contains(where: { $0.absoluteString == url.absoluteString }) {
                            // Mirrors are interchangeable. Keep a bounded, deterministic
                            // first sixteen even when more categories offer the object.
                            var urls = prior.urls + [url]
                            urls.sort { bytesLess($0.absoluteString, $1.absoluteString) }
                            objects[chunk.id] = ChunkObject(id: chunk.id, urls: Array(urls.prefix(InstallPlan.maximumURLsPerObject)),
                                transferSize: prior.transferSize, transferDigest: prior.transferDigest, decodedSize: prior.decodedSize,
                                decodedDigest: prior.decodedDigest, codec: .zstd)
                        }
                    } else {
                        guard objects.count < InstallPlan.maximumObjects else { throw LauncherError.io("sophon object limit") }
                        objects[chunk.id] = ChunkObject(id: chunk.id, urls: [url], transferSize: chunk.compressedSize,
                            transferDigest: chunk.compressedMD5, decodedSize: chunk.decodedSize, decodedDigest: chunk.decodedMD5, codec: .zstd)
                    }
                }
            }
        }
        return objects
    }

    private static func fileUnion(_ categories: [PlannedCategory]) throws -> [SafeRelativePath: SophonFile] {
        var files: [SafeRelativePath: SophonFile] = [:]
        var folded: [String: SafeRelativePath] = [:]
        var extentCount = 0
        for category in categories {
            for file in category.manifest.files {
                let key = file.path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                if let path = folded[key], !path.description.utf8.elementsEqual(file.path.description.utf8) {
                    throw LauncherError.io("conflicting file path")
                }
                let canonical = SophonFile(path: file.path, size: file.size, md5: file.md5,
                    chunks: file.chunks.sorted { $0.fileOffset < $1.fileOffset })
                if let prior = files[file.path] {
                    guard prior == canonical else { throw LauncherError.io("conflicting file path") }
                } else {
                    guard files.count < InstallPlan.maximumFiles,
                          file.chunks.count <= InstallPlan.maximumExtents - extentCount else { throw LauncherError.io("sophon file limit") }
                    extentCount += file.chunks.count
                    files[file.path] = canonical
                    folded[key] = file.path
                }
            }
        }
        return files
    }
}

private struct Content: Hashable {
    let digest: Digest
    let size: Int64
    init(_ chunk: SophonChunkRef) { digest = chunk.decodedMD5; size = chunk.decodedSize }
}

private struct LocalSource {
    let path: SafeRelativePath
    let offset: Int64
    func precedes(_ other: LocalSource) -> Bool {
        if path != other.path { return bytesLess(path.description, other.path.description) }
        return offset < other.offset
    }
}

/// Precompute the best sources once; choosing a local extent never scans the
/// installed files, even for a ubiquitous chunk repeated at many destinations.
private struct Sources {
    var byPath: [SafeRelativePath: Int64] = [:]
    var best: LocalSource?
    var bestUnchanged: LocalSource?
    mutating func insert(path: SafeRelativePath, offset: Int64, unchanged: Bool) {
        if let prior = byPath[path], prior <= offset { return }
        byPath[path] = offset
        let source = LocalSource(path: path, offset: offset)
        if best.map({ source.precedes($0) }) ?? true { best = source }
        if unchanged, bestUnchanged.map({ source.precedes($0) }) ?? true { bestUnchanged = source }
    }
    func preferred(for path: SafeRelativePath) -> LocalSource? {
        if let offset = byPath[path] { return LocalSource(path: path, offset: offset) }
        return bestUnchanged ?? best
    }
}

private func bytesLess(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
