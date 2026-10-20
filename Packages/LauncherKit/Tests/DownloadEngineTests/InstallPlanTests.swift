// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import Testing
import TestSupport
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
    for (size, offsets, reason) in [(Int64(4), [Int64(1)], "extent gap, overlap or invalid length"),
        (6, [0, 2], "extent gap, overlap or invalid length"), (4, [0], "short file coverage")] {
        let extents = offsets.map { Extent(source: .chunk(id: "object"), fileOffset: $0, length: 3, digest: object.decodedDigest) }
        let plan = try makePlan(objects: ["object": object], files: [planFile(size: size, extents: extents)])
        #expect(throws: LauncherError.io("invalid plan: " + reason)) { try plan.validate() }
    }
}

@Test
func planRejectsMissingOrMismatchedObject() throws {
    let object = planObject()
    let extent = planExtent()
    let missing = try makePlan(objects: [:], files: [planFile(extents: [extent])])
    #expect(throws: LauncherError.io("invalid plan: missing object")) { try missing.validate() }
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
    let plan = try makePlan(objects: ["object": planObject(), "orphan": planObject(id: "orphan")], files: [planFile(extents: [planExtent()])])
    #expect(throws: LauncherError.io("invalid plan: orphan object")) { try plan.validate() }
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
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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

@Test
func planDigestHasGoldenBytesAndHex() throws {
    let plan = try makePlan(objects: ["object": planObject()], files: [planFile(path: "Data/file.bin", extents: [planExtent()])])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let golden = #"{"deletions":[],"files":[{"digest":{"algorithm":"md5","hex":"900150983cd24fb0d6963f7d28e17f72"},"extents":[{"digest":{"algorithm":"md5","hex":"900150983cd24fb0d6963f7d28e17f72"},"fileOffset":0,"length":3,"source":{"chunk":{"id":"object"}}}],"path":"Data/file.bin","size":3}],"id":"build-1","objects":{"object":{"codec":"identity","decodedDigest":{"algorithm":"md5","hex":"900150983cd24fb0d6963f7d28e17f72"},"decodedSize":3,"id":"object","transferDigest":{"algorithm":"md5","hex":"900150983cd24fb0d6963f7d28e17f72"},"transferSize":3,"urls":["https://cdn.test/object"]}}}"#
    #expect(try encoder.encode(plan) == Data(golden.utf8))
    #expect(plan.planDigest.hex == "a8dea626787b5f9f03e44dc4e91ff29d50076ee079816be64f1bcf42d600ade0")
}

@Test
func plansRejectUnsupportedCodecsBeforeFetch() throws {
    let reference = planObject()
    let object = ChunkObject(id: "object", urls: reference.urls, transferSize: 3, decodedSize: 3,
        decodedDigest: reference.decodedDigest, codec: .zstd)
    let plan = try makePlan(objects: ["object": object], files: [planFile(extents: [planExtent()])])
    #expect(throws: LauncherError.io("codec unsupported: zstd")) { try plan.validate() }
    try plan.validate(supportedCodecs: [.identity, .zstd])
    #expect(throws: LauncherError.io("codec unsupported: identity")) {
        try makePlan(objects: ["object": reference], files: [planFile(extents: [planExtent()])]).validate(supportedCodecs: [])
    }
}

@Test
func planCapsBoundCollectionsAndOpaqueIDs() throws {
    let object = planObject()
    let manyURLs = ChunkObject(id: "object", urls: Array(repeating: object.urls[0], count: 17), transferSize: 3,
        decodedSize: 3, decodedDigest: object.decodedDigest)
    let urlsPlan = try makePlan(objects: ["object": manyURLs], files: [planFile(extents: [planExtent()])])
    #expect(throws: LauncherError.io("invalid plan: too many object URLs")) { try urlsPlan.validate() }
    for id in ["", String(repeating: "é", count: 2049)] {
        let invalid = planObject(id: id)
        let plan = try makePlan(objects: [id: invalid], files: [planFile(extents: [planExtent(id: id)])])
        #expect(throws: LauncherError.io(id.isEmpty ? "invalid plan: empty object id" : "invalid plan: object id too long")) { try plan.validate() }
    }
    do {
        let files = Array(repeating: try planFile(size: 0, extents: []), count: 1_000_001)
        let plan = try makePlan(objects: [:], files: files)
        #expect(throws: LauncherError.io("invalid plan: too many files")) { try plan.validate() }
    }
    do {
        let paths = Array(repeating: try SafeRelativePath("old"), count: 1_000_001)
        let plan = try makePlan(objects: [:], files: [], deletions: paths)
        #expect(throws: LauncherError.io("invalid plan: too many deletions")) { try plan.validate() }
    }
    do {
        let extents = Array(repeating: planExtent(), count: 1_000_001)
        let plan = try makePlan(objects: ["object": object], files: [planFile(path: "a", extents: extents), planFile(path: "b", extents: extents)])
        #expect(throws: LauncherError.io("invalid plan: too many extents")) { try plan.validate() }
    }
    // Null values prove the cap is enforced before constructing a million ChunkObjects.
    let objects = (0...1_000_000).map { "\"o\($0)\":null" }.joined(separator: ",")
    let bytes = Data("{\"id\":\"build\",\"objects\":{\(objects)},\"files\":[],\"deletions\":[]}".utf8)
    #expect(throws: LauncherError.io("invalid plan: too many objects")) { try JSONDecoder().decode(InstallPlan.self, from: bytes) }
}

@Test
func localSourceCanBeDeletedAfterStagingWithoutFallback() async throws {
    let temp = try TestSupport.TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let old = try SafeRelativePath("old")
    try fs.writeAtomically(Data("abc".utf8), to: old)
    let extent = Extent(source: .local(path: old, offset: 0), fileOffset: 0, length: 3, digest: planObject().decodedDigest)
    let plan = try makePlan(objects: [:], files: [planFile(extents: [extent])], deletions: [old])
    try plan.validate()
    let cdn = TestSupport.MockCDN()
    let operation = try InstallOperation(plan: plan, installRoot: temp.url,
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: TestSupport.InstantSleeper()),
        disk: TestSupport.FixedDiskSpace(bytes: Int64.max))
    for try await _ in operation.run() {}
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.itemType(at: old) == nil)
    #expect(try fs.readFile(at: SafeRelativePath("file.bin"), maxBytes: 3) == Data("abc".utf8))
}

@Test
func planDecodingBoundsArraysBeforeDecodingElements() throws {
    for key in ["files", "deletions"] {
        let nulls = String(repeating: "null,", count: 1_000_000) + "null"
        let bytes = Data(("{\"id\":\"build\",\"objects\":{},\"files\":[],\"deletions\":[]}")
            .replacingOccurrences(of: "\"\(key)\":[]", with: "\"\(key)\":[\(nulls)]").utf8)
        #expect(throws: LauncherError.io("invalid plan: too many " + key)) { try JSONDecoder().decode(InstallPlan.self, from: bytes) }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let object = String(decoding: try encoder.encode(planObject()), as: UTF8.self)
    let first = String(decoding: try encoder.encode(planFile(path: "a", extents: [planExtent()])), as: UTF8.self)
    let nulls = String(repeating: "null,", count: 1_999_999) + "null"
    let second = String(decoding: try encoder.encode(planFile(path: "b", extents: [])), as: UTF8.self)
        .replacingOccurrences(of: "\"extents\":[]", with: "\"extents\":[\(nulls)]")
    let bytes = Data("{\"id\":\"build\",\"objects\":{\"object\":\(object)},\"files\":[\(first),\(second)],\"deletions\":[]}".utf8)
    #expect(throws: LauncherError.io("invalid plan: too many extents")) { try JSONDecoder().decode(InstallPlan.self, from: bytes) }
}
