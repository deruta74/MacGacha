// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import Testing
import LauncherCore
@testable import DownloadEngine

@Test(arguments: [Int64.min, -1])
func planRejectsNegativeSourceAndDestinationOffsets(offset: Int64) throws {
    let digest = planObject().decodedDigest
    for (localOffset, fileOffset) in [(offset, Int64(0)), (Int64(0), offset)] {
        let extent = Extent(source: .local(path: try SafeRelativePath("old"), offset: localOffset),
            fileOffset: fileOffset, length: 3, digest: digest)
        let plan = try makePlan(objects: [:], files: [planFile(extents: [extent])])
        try rejectsInvalidPlan(plan)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan))
        }
    }
}

@Test
func planRejectsGapOverlapAndShortCoverage() throws {
    let object = planObject()
    for (size, offsets) in [(Int64(4), [Int64(1)]), (6, [0, 2]), (4, [0])] {
        let extents = offsets.map { Extent(source: .chunk(id: "object"), fileOffset: $0, length: 3, digest: object.decodedDigest) }
        try rejectsInvalidPlan(makePlan(objects: ["object": object], files: [planFile(size: size, extents: extents)]))
    }
}

@Test
func planRejectsMissingOrMismatchedObject() throws {
    let object = planObject()
    let extent = planExtent()
    try rejectsInvalidPlan(makePlan(objects: [:], files: [planFile(extents: [extent])]))
    try rejectsInvalidPlan(makePlan(objects: ["wrong-key": object], files: [planFile(extents: [extent])]))
    let mismatch = Extent(source: .chunk(id: "object"), fileOffset: 0, length: 2, digest: object.decodedDigest)
    try rejectsInvalidPlan(makePlan(objects: ["object": object], files: [planFile(size: 2, extents: [mismatch])]))
    for fallback in ["missing", "object"] {
        let local = Extent(source: .local(path: try SafeRelativePath("old.bin"), offset: 0), fileOffset: 0,
            length: 2, digest: object.decodedDigest, fallbackChunkID: fallback)
        try rejectsInvalidPlan(makePlan(objects: ["object": object], files: [planFile(size: 2, extents: [local])]))
    }
}

@Test
func planRejectsInstallAndDeleteSamePath() throws {
    let file = try planFile(path: "Data/file.bin", extents: [planExtent()])
    let plan = try makePlan(objects: ["object": planObject()], files: [file], deletions: [SafeRelativePath("data/FILE.bin")])
    try rejectsInvalidPlan(plan)
    let unicodeFiles = try [planFile(path: "Straße/é.bin", extents: [planExtent()]),
        planFile(path: "STRASSE/e\u{301}.BIN", extents: [planExtent()])]
    try rejectsInvalidPlan(makePlan(objects: ["object": planObject()], files: unicodeFiles))
}

@Test
func planRejectsCaseInsensitiveDuplicates() throws {
    let files = try [planFile(path: "Data/a.bin", extents: [planExtent()]), planFile(path: "data/A.BIN", extents: [planExtent()])]
    let plan = try makePlan(objects: ["object": planObject()], files: files)
    try rejectsInvalidPlan(plan)
    let encoded = try JSONEncoder().encode(plan)
    do { _ = try JSONDecoder().decode(InstallPlan.self, from: encoded); Issue.record("Decoding must preserve plan invariants") }
    catch LauncherError.io(let message) { #expect(message.hasPrefix("invalid plan: ")) }
    try rejectsInvalidPlan(makePlan(objects: [:], files: [], deletions: [SafeRelativePath("old"), SafeRelativePath("OLD")]))
}

@Test
func planRejectsDeletionAncestorsDescendantsAndDuplicates() throws {
    let file = try planFile(path: "Data/file.bin", extents: [planExtent()])
    for deletion in ["data", "DATA/FILE.BIN/child"] {
        let plan = try makePlan(objects: ["object": planObject()], files: [file], deletions: [SafeRelativePath(deletion)])
        #expect(throws: LauncherError.io("invalid plan: deletion overlaps installed path")) { try plan.validate() }
        #expect(throws: LauncherError.io("invalid plan: deletion overlaps installed path")) {
            try JSONDecoder().decode(InstallPlan.self, from: JSONEncoder().encode(plan))
        }
    }
    for deletions in [["old", "old"], ["old", "OLD"], ["Straße/é", "STRASSE/e\u{301}"]] {
        let plan = try makePlan(objects: [:], files: [], deletions: deletions.map { try SafeRelativePath($0) })
        #expect(throws: LauncherError.io("invalid plan: duplicate deletion path")) { try plan.validate() }
    }
}

@Test
func planRejectsOrphanObject() throws {
    try rejectsInvalidPlan(makePlan(objects: ["object": planObject(), "orphan": planObject(id: "orphan")],
        files: [planFile(extents: [planExtent()])]))
}

@Test
func planDigestIsStableAcrossKeyOrder() throws {
    let ids = (0..<24).map { String(format: "object-%02d", $0) }
    let files = try ids.map { try planFile(path: $0, extents: [planExtent(id: $0)]) }
    var forward: [String: ChunkObject] = [:]
    for id in ids { forward[id] = planObject(id: id) }
    var reverse: [String: ChunkObject] = [:]
    for id in ids.reversed() { reverse[id] = planObject(id: id) }
    let a = try makePlan(objects: forward, files: files)
    let b = try makePlan(objects: reverse, files: files)
    #expect(a.planDigest == b.planDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(a)
    #expect(encoded == (try encoder.encode(b)))
    #expect(a.planDigest == planDigest(encoded, algorithm: .sha256))
    let json = String(decoding: encoded, as: UTF8.self)
    let keyPositions = try ids.map { id in try #require(json.range(of: "\"\(id)\":")).lowerBound }
    #expect(keyPositions == keyPositions.sorted())
    #expect(json.hasPrefix("{\"deletions\":[],\"files\":"))
    let roundTrip = try JSONDecoder().decode(InstallPlan.self, from: encoder.encode(a))
    #expect(roundTrip.planDigest == a.planDigest)
}

@Test
func planRejectsAncestorDestinations() throws {
    for paths in [["Data", "data/file.bin"], ["data/file.bin", "Data"], ["Straße", "STRASSE/file.bin"]] {
        let files = try paths.map { try planFile(path: $0, extents: [planExtent()]) }
        let plan = try makePlan(objects: ["object": planObject()], files: files)
        #expect(throws: LauncherError.io("invalid plan: file path is an ancestor of another destination")) { try plan.validate() }
    }
    try makePlan(objects: ["object": planObject()], files: [
        planFile(path: "Data", extents: [planExtent()]), planFile(path: "Data2/file.bin", extents: [planExtent()]),
    ]).validate()
}

@Test
func identityObjectsRequireMatchingTransferAndDecodedMetadata() throws {
    let reference = planObject()
    let sizeMismatch = ChunkObject(id: "object", urls: reference.urls, transferSize: 2,
        decodedSize: 3, decodedDigest: reference.decodedDigest)
    #expect(throws: LauncherError.io("invalid plan: identity object sizes differ")) { try sizeMismatch.validate() }
    for digest in [planDigest(Data("xyz".utf8)), planDigest(Data("abc".utf8), algorithm: .sha256)] {
        let mismatch = ChunkObject(id: "object", urls: reference.urls, transferSize: 3, transferDigest: digest,
            decodedSize: 3, decodedDigest: reference.decodedDigest)
        #expect(throws: LauncherError.io("invalid plan: identity object digests differ")) { try mismatch.validate() }
    }
    try ChunkObject(id: "object", urls: reference.urls, transferSize: 3,
        decodedSize: 3, decodedDigest: reference.decodedDigest).validate()
    try ChunkObject(id: "object", urls: reference.urls, transferSize: 2, transferDigest: planDigest(Data("zz".utf8)),
        decodedSize: 3, decodedDigest: reference.decodedDigest, codec: .zstd).validate()
}

@Test
func chunkObjectsRequirePositiveSizes() throws {
    for (transfer, decoded) in [(Int64(0), Int64(3)), (3, 0), (0, 0), (-1, 3), (3, -1)] {
        let object = ChunkObject(id: "object", urls: planObject().urls, transferSize: transfer,
            decodedSize: decoded, decodedDigest: planObject().decodedDigest, codec: .zstd)
        #expect(throws: LauncherError.io("invalid plan: object sizes must be positive")) { try object.validate() }
    }
}

@Test
func extentDigestsMustMatchReferencedObjects() throws {
    let object = planObject()
    for digest in [planDigest(Data("xyz".utf8)), planDigest(Data("abc".utf8), algorithm: .sha256)] {
        for source in [ExtentSource.chunk(id: "object"), .local(path: try SafeRelativePath("old"), offset: 0)] {
            let isLocal: Bool
            if case .local = source { isLocal = true } else { isLocal = false }
            let extent = Extent(source: source, fileOffset: 0, length: 3, digest: digest,
                fallbackChunkID: isLocal ? "object" : nil)
            let plan = try makePlan(objects: ["object": object], files: [planFile(extents: [extent])])
            #expect(throws: LauncherError.io("invalid plan: extent and object decoded digest mismatch")) { try plan.validate() }
        }
    }
    let fallbackOnChunk = Extent(source: .chunk(id: "object"), fileOffset: 0, length: 3,
        digest: object.decodedDigest, fallbackChunkID: "object")
    let plan = try makePlan(objects: ["object": object], files: [planFile(extents: [fallbackOnChunk])])
    #expect(throws: LauncherError.io("invalid plan: fallback is only allowed on local extents")) { try plan.validate() }
}

@Test
func sha256ObjectsAndExtentsValidate() throws {
    let digest = planDigest(Data("abc".utf8), algorithm: .sha256)
    let object = ChunkObject(id: "object", urls: planObject().urls, transferSize: 3,
        transferDigest: digest, decodedSize: 3, decodedDigest: digest)
    let chunk = Extent(source: .chunk(id: "object"), fileOffset: 0, length: 3, digest: digest)
    let local = Extent(source: .local(path: try SafeRelativePath("old"), offset: 0), fileOffset: 0,
        length: 3, digest: digest, fallbackChunkID: "object")
    try makePlan(objects: ["object": object], files: [planFile(path: "chunk", extents: [chunk]),
        planFile(path: "local", extents: [local])]).validate()
}

@Test
func sharedObjectAcrossTwoFilesValidates() throws {
    let files = try [planFile(path: "a", extents: [planExtent()]), planFile(path: "b", extents: [planExtent()])]
    let plan = try makePlan(objects: ["object": planObject()], files: files)
    try plan.validate()
    #expect(plan.objects.count == 1)
    let local = Extent(source: .local(path: try SafeRelativePath("old.bin"), offset: 10), fileOffset: 0,
        length: 3, digest: planDigest(Data("abc".utf8)), fallbackChunkID: "object")
    try makePlan(objects: ["object": planObject()], files: [planFile(extents: [local])]).validate()
    let empty = try planFile(path: "empty", size: 0, extents: [])
    try makePlan(objects: [:], files: [empty]).validate()
}

@Test
func planRejectsReservedPathsAndInvalidCounters() throws {
    for name in [".macgacha-staging/a", ".MACGACHA-STATE.JSON", ".macgacha-ſtaging/a", ".macgacha-ſtate.json"] {
        let file = try planFile(path: name, extents: [planExtent()])
        let plan = try makePlan(objects: ["object": planObject()], files: [file])
        #expect(throws: LauncherError.unsafePath(name)) { try plan.validate() }
        let deletion = try makePlan(objects: [:], files: [], deletions: [SafeRelativePath(name)])
        #expect(throws: LauncherError.unsafePath(name)) { try deletion.validate() }
        let local = Extent(source: .local(path: try SafeRelativePath(name), offset: 0), fileOffset: 0,
            length: 3, digest: planDigest(Data("abc".utf8)))
        let localPlan = try makePlan(objects: [:], files: [planFile(extents: [local])])
        #expect(throws: LauncherError.unsafePath(name)) { try localPlan.validate() }
    }
    let digest = planDigest(Data("abc".utf8))
    for (offset, length) in [(Int64(-1), Int64(3)), (0, 0), (Int64.max, 3)] {
        let extent = Extent(source: .local(path: try SafeRelativePath("old"), offset: offset), fileOffset: 0,
            length: length, digest: digest)
        try rejectsInvalidPlan(makePlan(objects: [:], files: [planFile(size: length, extents: [extent])]))
    }
    let negative = ChunkObject(id: "object", urls: [URL(string: "https://cdn.test/object")!], transferSize: -1,
        decodedSize: 3, decodedDigest: digest, codec: .identity)
    try rejectsInvalidPlan(makePlan(objects: ["object": negative], files: [planFile(extents: [planExtent()])]))
    let overflowing = [
        Extent(source: .local(path: try SafeRelativePath("old"), offset: 0), fileOffset: 0, length: Int64.max, digest: digest),
        Extent(source: .local(path: try SafeRelativePath("old"), offset: 0), fileOffset: Int64.max, length: 1, digest: digest),
    ]
    try rejectsInvalidPlan(makePlan(objects: [:], files: [planFile(size: Int64.max, extents: overflowing)]))
}

@Test
func objectPartNamesHashOpaqueIDs() {
    let object = planObject(id: "../opaque/name?token=private")
    #expect(object.partFileName == planDigest(Data(object.id.utf8), algorithm: .sha256).hex + ".part")
    #expect(!object.partFileName.contains("private"))
}

private func rejectsInvalidPlan(_ plan: InstallPlan) throws {
    do { try plan.validate(); Issue.record("Invalid plan must throw") }
    catch LauncherError.io(let reason) { #expect(reason.hasPrefix("invalid plan: ")) }
}

private func makePlan(objects: [String: ChunkObject], files: [FileTask], deletions: [SafeRelativePath] = []) throws -> InstallPlan {
    InstallPlan(id: try SafeIdentifier("build-1"), objects: objects, files: files, deletions: deletions)
}

private func planFile(path: String = "file.bin", size: Int64 = 3, extents: [Extent]) throws -> FileTask {
    FileTask(path: try SafeRelativePath(path), size: size, digest: planDigest(Data("abc".utf8)), extents: extents)
}

private func planExtent(id: String = "object") -> Extent {
    Extent(source: .chunk(id: id), fileOffset: 0, length: 3, digest: planDigest(Data("abc".utf8)))
}

private func planObject(id: String = "object") -> ChunkObject {
    ChunkObject(id: id, urls: [URL(string: "https://cdn.test/object")!], transferSize: 3,
        transferDigest: planDigest(Data("abc".utf8)), decodedSize: 3, decodedDigest: planDigest(Data("abc".utf8)), codec: .identity)
}

private func planDigest(_ bytes: Data, algorithm: DigestAlgorithm = .md5) -> Digest {
    var hasher = StreamingHasher(algorithm)
    hasher.update(bytes)
    return hasher.finalize()
}
