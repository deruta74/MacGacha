// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import Sophon

@Suite struct PatchPlannerTests {
    @Test func preservesDeltaFallbackAndSourceScopedDeletions() throws {
        let target = [plannedPatchFull([patchPlannerFile("keep", "keep"), patchPlannerFile("patched", "new"),
            patchPlannerFile("copy", "cpy"), patchPlannerFile("no-instruction", "old")])]
        let installed = InstalledSnapshot(categories: [plannedPatchFull([patchPlannerFile("keep", "keep", id: "old-keep"),
            patchPlannerFile("old", "old", id: "old-id")])])
        let metadata = try patchPlannerMetadata(files: [patchPlannerTarget("patched", "new", instructions: ["1.0": patchPlannerInstruction()]),
            patchPlannerTarget("copy", "cpy", instructions: ["1.0": patchPlannerInstruction(original: nil)])],
            deletions: ["1.0": [SophonDeletedFile(path: SafeRelativePath("stale"), size: 3, md5: md5(Data("old".utf8)))],
                "0.9": [SophonDeletedFile(path: SafeRelativePath("keep"), size: 4, md5: md5(Data("keep".utf8)))]])
        let plan = try SophonPlanner.patchPlan(id: SafeIdentifier("patch-planner"), target: target, patch: [metadata], installed: installed, sourceTag: "1.0")
        #expect(!plan.files.contains { $0.path.description == "keep" })
        let patched = try #require(plan.files.first { $0.path.description == "patched" })
        guard case .patch(let source, let size, let digest, _, _, _) = patched.recipe else { Issue.record("Expected patch recipe"); return }
        #expect(source.description == "old" && size == 3 && digest == md5(Data("old".utf8)))
        let copied = try #require(plan.files.first { $0.path.description == "copy" })
        guard case .copy = copied.recipe else { Issue.record("Expected copy recipe"); return }
        let fallback = try #require(plan.files.first { $0.path.description == "no-instruction" })
        #expect(fallback.recipe == nil)
        #expect(fallback.extents[0].source == .local(path: try SafeRelativePath("old"), offset: 0))
        #expect(fallback.extents[0].fallbackChunkID == "no-instruction")
        #expect(Set(plan.deletions.map(\.description)) == ["old", "stale"])
        let copyRecipe = try #require(copied.recipe)
        let raw = try #require(plan.objects[copyRecipe.containerID])
        #expect(raw.codec == .identity && raw.transferDigest == raw.decodedDigest)
        #expect(patched.extents.count == 1 && copied.extents.count == 1)
        try plan.validate()
    }

    @Test func unsupportedSourceUsesSavedChunkRoute() throws {
        let full = [plannedPatchFull([patchPlannerFile("file", "new")])]
        let patch = try patchPlannerMetadata(files: [patchPlannerTarget("file", "new", instructions: ["1.0": patchPlannerInstruction()])])
        let result = try SophonPlanner.patchPlan(id: SafeIdentifier("no-source"), target: full, patch: [patch],
            installed: InstalledSnapshot(categories: []), sourceTag: "unavailable")
        #expect(result.files.allSatisfy { $0.recipe == nil })
        #expect(result.objects.count == 1)
    }

    @Test func deletionCannotHitUnchangedTargetUnion() throws {
        let file = patchPlannerFile("keep", "same"), full = [plannedPatchFull([file])]
        let metadata = try patchPlannerMetadata(files: [], deletions: ["1.0": [SophonDeletedFile(path: file.path, size: file.size, md5: file.md5)]])
        #expect(throws: (any Error).self) {
            try SophonPlanner.patchPlan(id: SafeIdentifier("deletion-conflict"), target: full, patch: [metadata],
                installed: InstalledSnapshot(categories: full), sourceTag: "1.0")
        }
    }

    @Test func containerIdentityDependsOnIDAndMD5RatherThanBuild() throws {
        let full = [plannedPatchFull([patchPlannerFile("file", "new")])]
        func planned(_ build: String, _ hash: String) throws -> InstallPlan {
            let metadata = try patchPlannerMetadata(files: [patchPlannerTarget("file", "new", instructions: ["1.0": patchPlannerInstruction(hash: hash)])], build: build)
            return try SophonPlanner.patchPlan(id: SafeIdentifier("identity"), target: full, patch: [metadata], installed: InstalledSnapshot(categories: []), sourceTag: "1.0")
        }
        let a = try planned("a", String(repeating: "0", count: 32)), b = try planned("b", String(repeating: "0", count: 32))
        #expect(a.files.first?.recipe?.containerID == b.files.first?.recipe?.containerID)
        let changed = try planned("a", String(repeating: "1", count: 32))
        #expect(a.files.first?.recipe?.containerID != changed.files.first?.recipe?.containerID)
    }

    @Test func rejectsPatchTargetMetadataMismatch() throws {
        let full = [plannedPatchFull([patchPlannerFile("file", "new")])]
        let metadata = try patchPlannerMetadata(files: [patchPlannerTarget("file", "wrong", instructions: [:])])
        #expect(throws: (any Error).self) {
            try SophonPlanner.patchPlan(id: SafeIdentifier("target-conflict"), target: full, patch: [metadata], installed: nil, sourceTag: "1.0")
        }
    }
}

private func patchPlannerFile(_ path: String, _ content: String, id: String? = nil) -> SophonFile {
    let digest = md5(Data(content.utf8)), size = Int64(content.utf8.count)
    return SophonFile(path: try! SafeRelativePath(path), size: size, md5: digest,
        chunks: [SophonChunkRef(id: id ?? path, decodedMD5: digest, fileOffset: 0, compressedSize: 1, decodedSize: size, compressedMD5: nil)])
}
private func plannedPatchFull(_ files: [SophonFile]) -> PlannedCategory { PlannedCategory(category: testCategory(), manifest: SophonManifest(files: files)) }
private func patchPlannerTarget(_ path: String, _ content: String, instructions: [String: SophonPatchInstruction]) -> SophonPatchFile {
    SophonPatchFile(path: try! SafeRelativePath(path), size: Int64(content.utf8.count), md5: md5(Data(content.utf8)), patches: instructions)
}
private func patchPlannerInstruction(original: String? = "old", hash: String = String(repeating: "0", count: 32)) -> SophonPatchInstruction {
    SophonPatchInstruction(containerID: "raw-container", containerSize: 16, containerMD5: try! Digest(algorithm: .md5, hex: hash),
        buildID: "source-build", offset: 1, length: 3, originalPath: original.map { try! SafeRelativePath($0) }, originalSize: original == nil ? 0 : 3,
        originalMD5: original == nil ? nil : md5(Data("old".utf8)))
}
private func patchPlannerMetadata(files: [SophonPatchFile], deletions: [String: [SophonDeletedFile]] = [:], build: String = "a") throws -> PlannedPatchCategory {
    let category = PatchBuildCategory(region: .global, id: testCategory().id, matchingField: "game", manifest: manifestRef(),
        manifestPrefix: URL(string: "https://cdn.hoyoverse.com/manifests/\(build)")!, manifestSuffix: "",
        diffPrefix: URL(string: "https://cdn.yuanshen.com/diffs/\(build)")!, diffSuffix: "", diffCodec: .identity, stats: [:])
    return PlannedPatchCategory(category: category, manifest: SophonPatchManifest(files: files, deletedFiles: deletions))
}
