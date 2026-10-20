// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import Testing
import LauncherCore
import DownloadEngine

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
func planRejectsOrphanObject() throws {
    try rejectsInvalidPlan(makePlan(objects: ["object": planObject(), "orphan": planObject(id: "orphan")],
        files: [planFile(extents: [planExtent()])]))
}

@Test
func planDigestIsStableAcrossKeyOrder() throws {
    let first = planObject(id: "first")
    let second = planObject(id: "second")
    let files = try [planFile(path: "a", extents: [planExtent(id: "first")]), planFile(path: "b", extents: [planExtent(id: "second")])]
    var forward: [String: ChunkObject] = [:]
    forward["first"] = first; forward["second"] = second
    var reverse: [String: ChunkObject] = [:]
    reverse["second"] = second; reverse["first"] = first
    let a = try makePlan(objects: forward, files: files)
    let b = try makePlan(objects: reverse, files: files)
    #expect(a.planDigest == b.planDigest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(a.planDigest == planDigest(try encoder.encode(a), algorithm: .sha256))
    let roundTrip = try JSONDecoder().decode(InstallPlan.self, from: encoder.encode(a))
    #expect(roundTrip.planDigest == a.planDigest)
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
    for name in [".macgacha-staging/a", ".MACGACHA-STATE.JSON"] {
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
