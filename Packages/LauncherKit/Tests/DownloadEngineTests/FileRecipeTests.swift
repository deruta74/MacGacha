// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import DownloadEngine

@Suite struct FileRecipeTests {
    @Test func legacyPlansKeepTheirEncodedBytesAndDigest() throws {
        let plan = try recipePlan(recipe: nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let legacyBytes = try encoder.encode(plan)
        #expect(!String(decoding: legacyBytes, as: UTF8.self).contains("\"recipe\":"))
        let restored = try JSONDecoder().decode(InstallPlan.self, from: legacyBytes)
        #expect(restored.files.first?.recipe == nil)
        #expect(restored.planDigest == plan.planDigest)
        #expect(try encoder.encode(restored) == legacyBytes)
    }

    @Test func recipesRoundTripAndParticipateInPlanDigest() throws {
        let copy = try recipePlan(recipe: .copy(container: "container", offset: 1, length: 3))
        let patch = try recipePlan(recipe: .patch(source: SafeRelativePath("old"), sourceSize: 3, sourceDigest: recipeMD5,
            container: "container", offset: 1, length: 3))
        try copy.validate(); try patch.validate()
        let restored = try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(patch))
        #expect(restored.files == patch.files)
        #expect(restored.planDigest == patch.planDigest)
        #expect(copy.planDigest != patch.planDigest)
        #expect(try recipePlan(recipe: .copy(container: "container", offset: 2, length: 3)).planDigest != copy.planDigest)
        #expect(SpaceBudget.references(patch.files[0]) == ["chunk", "container"])
    }

    @Test(arguments: [(Int64(-1), Int64(3)), (Int64.max, Int64(3)), (Int64(15), Int64(3)), (Int64(1), Int64(-1))])
    func sliceArithmeticIsBounded(offset: Int64, length: Int64) throws {
        let plan = try recipePlan(recipe: .copy(container: "container", offset: offset, length: length))
        #expect(throws: (any Error).self) { try plan.validate() }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan)) }
    }

    @Test func exactBoundaryAndCopyGeometry() throws {
        try recipePlan(recipe: .copy(container: "container", offset: 13, length: 3)).validate()
        #expect(throws: (any Error).self) { try recipePlan(recipe: .copy(container: "container", offset: 0, length: 2)).validate() }
    }

    @Test(arguments: [".macgacha-predownload/file", ".MACGACHA-PREDOWNLOAD", ".macgacha-staging/file"])
    func reservesTargetSourceAndDeletionNamespaces(path: String) throws {
        let safe = try SafeRelativePath(path)
        let recipe = FileRecipe.patch(source: safe, sourceSize: 3, sourceDigest: recipeMD5, container: "container", offset: 0, length: 3)
        #expect(throws: LauncherError.unsafePath(path)) { try recipePlan(recipe: recipe).validate() }
        #expect(throws: LauncherError.unsafePath(path)) { try recipePlan(recipe: nil, target: path).validate() }
        let empty = InstallPlan(id: try SafeIdentifier("reserved"), objects: [:], files: [], deletions: [safe])
        #expect(throws: LauncherError.unsafePath(path)) { try empty.validate() }
    }

    @Test func containersRequireRawTransferMD5AndActualReferences() throws {
        let recipe = FileRecipe.copy(container: "container", offset: 0, length: 3)
        let valid = try recipePlan(recipe: recipe)
        let object = try #require(valid.objects["container"])
        for codec in [ChunkCodec.zstd, .identity] {
            var objects = valid.objects
            objects[object.id] = ChunkObject(id: object.id, urls: object.urls, transferSize: object.transferSize,
                transferDigest: codec == .identity ? nil : recipeMD5, decodedSize: object.decodedSize,
                decodedDigest: recipeMD5, codec: codec)
            #expect(throws: (any Error).self) { try InstallPlan(id: valid.id, objects: objects, files: valid.files).validate() }
        }
        var objects = valid.objects; objects.removeValue(forKey: "container")
        #expect(throws: (any Error).self) { try InstallPlan(id: valid.id, objects: objects, files: valid.files).validate() }
        #expect(throws: LauncherError.io("invalid plan: orphan object")) {
            try InstallPlan(id: valid.id, objects: valid.objects, files: [FileTask(path: valid.files[0].path, size: 3,
                digest: recipeMD5, extents: valid.files[0].extents)]).validate()
        }
    }
}

private let recipeMD5 = try! Digest(algorithm: .md5, hex: String(repeating: "0", count: 32))
private func recipePlan(recipe: FileRecipe?, target: String = "file") throws -> InstallPlan {
    let chunk = ChunkObject(id: "chunk", urls: [URL(string: "https://cdn.test/chunk")!], transferSize: 3,
        transferDigest: recipeMD5, decodedSize: 3, decodedDigest: recipeMD5)
    let container = ChunkObject(id: "container", urls: [URL(string: "https://cdn.test/container")!], transferSize: 16,
        transferDigest: recipeMD5, decodedSize: 16, decodedDigest: recipeMD5)
    let file = FileTask(path: try SafeRelativePath(target), size: 3, digest: recipeMD5,
        extents: [Extent(source: .chunk(id: chunk.id), fileOffset: 0, length: 3, digest: recipeMD5)], recipe: recipe)
    return InstallPlan(id: try SafeIdentifier("file-recipes"), objects: recipe == nil ? [chunk.id: chunk] : [chunk.id: chunk, container.id: container], files: [file])
}
