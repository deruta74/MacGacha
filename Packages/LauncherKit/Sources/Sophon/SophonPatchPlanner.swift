// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct PlannedPatchCategory: Sendable {
    public let category: PatchBuildCategory
    public let manifest: SophonPatchManifest
    public init(category: PatchBuildCategory, manifest: SophonPatchManifest) { self.category = category; self.manifest = manifest }
}

extension SophonPlanner {
    public static func patchPlan(id: SafeIdentifier, target: [PlannedCategory], patch: [PlannedPatchCategory],
        installed: InstalledSnapshot?, sourceTag: String) throws -> InstallPlan {
        let delta = try plan(id: id, target: target, installed: installed)
        let full = try fullPlan(id: id, target: target)
        let targets = Dictionary(uniqueKeysWithValues: full.files.map { ($0.path, $0) })
        let categories = Dictionary(target.map { ($0.category.id, $0.category) }, uniquingKeysWith: { first, _ in first })
        guard Set(patch.map(\.category.id)) == Set(categories.keys), patch.count == categories.count else {
            throw LauncherError.io("missing patch category")
        }
        var patchFiles: [SafeRelativePath: SophonPatchFile] = [:]
        var descriptors: [SafeRelativePath: PatchBuildCategory] = [:]
        var deletions = Dictionary(delta.deletions.map { (patchPathKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        for planned in patch.sorted(by: { $0.category.id.utf8.lexicographicallyPrecedes($1.category.id.utf8) }) {
            try planned.category.validate()
            guard let category = categories[planned.category.id], category.region == planned.category.region,
                  category.matchingField == planned.category.matchingField, planned.category.diffCodec == .identity else {
                throw LauncherError.io("conflicting patch category")
            }
            for file in planned.manifest.files {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                guard let target = targets[file.path], target.size == file.size, target.digest == file.md5 else {
                    throw LauncherError.io("patch target metadata mismatch")
                }
                if let prior = patchFiles[file.path] {
                    guard prior == file else { throw LauncherError.io("conflicting patch file") }
                } else {
                    patchFiles[file.path] = file; descriptors[file.path] = planned.category
                }
            }
            for file in planned.manifest.deletedFiles[sourceTag] ?? [] {
                if deletions[patchPathKey(file.path)] == nil { deletions[patchPathKey(file.path)] = file.path }
            }
        }
        var objects = full.objects
        var recipes: [SafeRelativePath: FileRecipe] = [:]
        for (path, file) in patchFiles {
            guard let instruction = file.patches[sourceTag], let category = descriptors[path] else { continue }
            let key = patchContainerIdentity(id: instruction.containerID, digest: instruction.containerMD5)
            let url = try category.diffURL(id: instruction.containerID)
            if let prior = objects[key] {
                guard prior.codec == .identity, prior.decodedSize == instruction.containerSize,
                      prior.decodedDigest == instruction.containerMD5, prior.transferDigest == instruction.containerMD5 else {
                    throw LauncherError.io("conflicting patch container")
                }
                let urls = Array(Set(prior.urls + [url])).sorted { $0.absoluteString.utf8.lexicographicallyPrecedes($1.absoluteString.utf8) }
                objects[key] = ChunkObject(id: key, urls: Array(urls.prefix(InstallPlan.maximumURLsPerObject)),
                    transferSize: instruction.containerSize, transferDigest: instruction.containerMD5,
                    decodedSize: instruction.containerSize, decodedDigest: instruction.containerMD5)
            } else {
                guard objects.count < InstallPlan.maximumObjects else { throw LauncherError.io("sophon object limit") }
                objects[key] = ChunkObject(id: key, urls: [url], transferSize: instruction.containerSize, transferDigest: instruction.containerMD5,
                    decodedSize: instruction.containerSize, decodedDigest: instruction.containerMD5)
            }
            if let original = instruction.originalPath {
                guard let digest = instruction.originalMD5 else { throw LauncherError.io("missing patch source digest") }
                recipes[path] = .patch(source: original, sourceSize: instruction.originalSize, sourceDigest: digest,
                    container: key, offset: instruction.offset, length: instruction.length)
            } else {
                recipes[path] = .copy(container: key, offset: instruction.offset, length: instruction.length)
            }
        }
        let deleted = deletions.values.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }
        // Validate against every target, including unchanged files omitted by the
        // delta plan. Invalid metadata must not hide behind installed reuse.
        let augmented = full.files.map { FileTask(path: $0.path, size: $0.size, digest: $0.digest, extents: $0.extents, recipe: recipes[$0.path]) }
        try InstallPlan(id: id, objects: objects, files: augmented, deletions: deleted).validate()
        let files = delta.files.map { FileTask(path: $0.path, size: $0.size, digest: $0.digest, extents: $0.extents, recipe: recipes[$0.path]) }
        var used = Set<String>()
        for file in files {
            if let recipe = file.recipe { used.insert(recipe.containerID) }
            for extent in file.extents {
                if case .chunk(let id) = extent.source { used.insert(id) }
                if let fallback = extent.fallbackChunkID { used.insert(fallback) }
            }
        }
        let result = InstallPlan(id: id, objects: objects.filter { used.contains($0.key) }, files: files, deletions: deleted)
        try result.validate()
        return result
    }

    // Namespace containers separately from chunks. Content identity deliberately
    // excludes build/patch IDs and descriptor URLs, which can change at promotion.
    package static func patchContainerIdentity(id: String, digest: Digest) -> String {
        var hash = StreamingHasher(.sha256)
        hash.update(Data(id.utf8)); hash.update(Data([0])); hash.update(Data(digest.hex.utf8))
        return "ldiff-" + hash.finalize().hex
    }
}

private func patchPathKey(_ path: SafeRelativePath) -> String {
    path.description.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}
