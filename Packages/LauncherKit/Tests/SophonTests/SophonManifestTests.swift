// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import DownloadEngine
import LauncherCore
import TestSupport
import Testing
@testable import Sophon

@Suite struct SophonManifestTests {
    @Test func fixedVectorFileWithOneChunk() throws {
        let file = try #require(SophonManifest.decode(fixedManifest()).files.first)
        #expect(file.path.description == "a/b.dat")
        #expect(file.size == 300)
        #expect(file.md5.hex == String(repeating: "0", count: 32))
        let chunk = try #require(file.chunks.first)
        #expect(file.chunks.count == 1)
        #expect(chunk.id == "c")
        #expect(chunk.fileOffset == 0)
        #expect(chunk.compressedSize == 150)
        #expect(chunk.decodedSize == 300)
        #expect(chunk.decodedMD5.hex == String(repeating: "0", count: 32))
        #expect(chunk.compressedMD5 == nil)
    }

    @Test func fixedVectorFieldsOutOfOrder() throws {
        #expect(try SophonManifest.decode(fixedManifest(reverse: true)).files
            == SophonManifest.decode(fixedManifest()).files)
    }

    @Test func fixedVectorTenByteVarintIsRejectedAsSize() {
        // 0a 0e: manifest field 1, 14 bytes; 0a 01 78: file path "x".
        // 20 is file field 4/varint, followed by the ten-byte uint64.max.
        // The enclosing length is 0e (3 path bytes + 11 size bytes).
        let data = hexBytes("0a 0e 0a 01 78 20 ff ff ff ff ff ff ff ff ff 01")
        #expect(throws: LauncherError.io("integer overflow")) { try SophonManifest.decode(data) }
    }

    @Test func decodesFileWithTwoChunks() throws {
        // Synthetic wire data using the independently researched §3 reconstruction sizes/digests.
        let a = manifestChunk(id: "25af97cc80808a4b_687d4abbef7484fb3a06f496e03ca291",
            md5: "687d4abbef7484fb3a06f496e03ca291", offset: nil, compressed: 590_654, decoded: 1_189_831,
            compressedMD5: String(repeating: "1", count: 32))
        let b = manifestChunk(id: "87e8fbfd4174a21e_a0c268fbc5132099d07441f674bb88fd",
            md5: "a0c268fbc5132099d07441f674bb88fd", offset: 1_189_831, compressed: 594_595, decoded: 1_393_001,
            compressedMD5: String(repeating: "2", count: 32))
        let file = try #require(SophonManifest.decode(manifestData([manifestFile(path: "APMCrashReporter/APMLog.dll",
            size: 2_582_832, md5: "b9dc4f8496e9e6e0a37978f8865d447a", chunks: [b, a])])).files.first)
        #expect(file.size == 2_582_832)
        #expect(file.md5.hex == "b9dc4f8496e9e6e0a37978f8865d447a")
        #expect(file.chunks.map(\.fileOffset) == [0, 1_189_831])
        #expect(file.chunks.map(\.decodedSize) == [1_189_831, 1_393_001])
        #expect(file.chunks.map(\.compressedSize) == [590_654, 594_595])
        #expect(file.chunks.map(\.decodedMD5.hex) == ["687d4abbef7484fb3a06f496e03ca291", "a0c268fbc5132099d07441f674bb88fd"])
        #expect(file.chunks.map { $0.compressedMD5?.hex } == [String(repeating: "1", count: 32), String(repeating: "2", count: 32)])
    }

    @Test func omittedOffsetIsZero() throws {
        let files = try SophonManifest.decode(manifestData([manifestFile()])).files
        #expect(files.first?.chunks.first?.fileOffset == 0)
    }

    @Test(arguments: [1, 3, 4, 5])
    func rejectsDuplicateFileScalarField(number: Int) {
        var duplicate = ProtobufWriter()
        if number == 1 || number == 5 { duplicate.string(UInt32(number), number == 1 ? "file" : testMD5) }
        else { duplicate.varint(UInt32(number), number == 3 ? 0 : 300) }
        #expect(throws: LauncherError.io("duplicate field")) {
            try SophonManifest.decode(manifestData([manifestFile() + duplicate.data]))
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 7])
    func rejectsDuplicateChunkScalarField(number: Int) {
        var extra = ProtobufWriter()
        if [1, 2, 7].contains(number) { extra.string(UInt32(number), number == 1 ? "chunk" : testMD5) }
        else { extra.varint(UInt32(number), 0) }
        let chunk = manifestChunk(offset: 0, compressedMD5: testMD5) + extra.data
        #expect(throws: LauncherError.io("duplicate field")) {
            try SophonManifest.decode(manifestData([manifestFile(chunks: [chunk])]))
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func rejectsWrongWireTypeForKnownFileField(number: Int) {
        var file = ProtobufWriter()
        if [1, 2, 5].contains(number) { file.varint(UInt32(number), 0) }
        else { file.bytes(UInt32(number), Data()) }
        #expect(throws: LauncherError.io("wrong wire type")) { try SophonManifest.decode(manifestData([file.data])) }
    }

    @Test(arguments: [1, 2, 3, 4, 5, 7])
    func rejectsWrongWireTypeForKnownChunkField(number: Int) {
        var chunk = ProtobufWriter()
        if [1, 2, 7].contains(number) { chunk.varint(UInt32(number), 0) }
        else { chunk.bytes(UInt32(number), Data()) }
        #expect(throws: LauncherError.io("wrong wire type")) {
            try SophonManifest.decode(manifestData([manifestFile(chunks: [chunk.data])]))
        }
    }

    @Test func rejectsWrongWireTypeForManifestFile() {
        #expect(throws: LauncherError.io("wrong wire type")) { try SophonManifest.decode(hexBytes("08 00")) }
    }

    @Test func rejectsOffsetPlusSizeOverflow() {
        let chunk = manifestChunk(offset: UInt64(Int64.max), decoded: 1)
        #expect(throws: LauncherError.io("invalid chunk layout")) {
            try SophonManifest.decode(manifestData([manifestFile(size: UInt64(Int64.max), chunks: [chunk])]))
        }
    }

    @Test func directoryEntriesAreSkipped() throws {
        var directory = ProtobufWriter(); directory.string(1, "Data"); directory.varint(3, 64)
        let manifest = try SophonManifest.decode(manifestData([directory.data, manifestFile()]))
        #expect(manifest.files.map(\.path.description) == ["file"])
    }

    @Test func unknownEntryTypeRejected() {
        #expect(throws: LauncherError.io("unsupported entry type")) {
            try SophonManifest.decode(manifestData([manifestFile(type: 7)]))
        }
    }

    @Test(arguments: ["../x", "/abs", "a\\b", "a//b", ""])
    func rejectsUnsafePaths(path: String) {
        #expect(throws: LauncherError.unsafePath(path)) { try SophonManifest.decode(manifestData([manifestFile(path: path)])) }
    }

    @Test func rejectsCaseVariantDuplicates() {
        #expect(throws: LauncherError.io("duplicate path")) {
            try SophonManifest.decode(manifestData([manifestFile(path: "Data/a.dat"), manifestFile(path: "data/A.dat")]))
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func rejectsChunkLayoutGapsAndOverlaps(variant: Int) {
        let chunks: [Data]
        switch variant {
        case 0: chunks = [manifestChunk(offset: 1)]
        case 1: chunks = [manifestChunk(decoded: 299)]
        case 2: chunks = [manifestChunk(decoded: 151), manifestChunk(offset: 150, decoded: 150)]
        default: chunks = []
        }
        #expect(throws: LauncherError.io("invalid chunk layout")) {
            try SophonManifest.decode(manifestData([manifestFile(chunks: chunks)]))
        }
    }

    @Test(arguments: [1, 2, 4, 5])
    func rejectsMissingRequiredChunkFields(missing: Int) {
        let chunk = manifestChunk(id: missing == 1 ? nil : "chunk", md5: missing == 2 ? nil : testMD5,
            compressed: missing == 4 ? nil : 150, decoded: missing == 5 ? nil : 300)
        #expect(throws: LauncherError.io("missing required field")) {
            try SophonManifest.decode(manifestData([manifestFile(chunks: [chunk])]))
        }
    }

    @Test func rejectsMissingFileMD5() {
        #expect(throws: LauncherError.io("missing required field")) {
            try SophonManifest.decode(manifestData([manifestFile(md5: nil)]))
        }
    }

    @Test func emptyFileWithOmittedDefaultFields() throws {
        var file = ProtobufWriter(); file.string(1, "empty"); file.string(5, testMD5)
        let decoded = try #require(SophonManifest.decode(manifestData([file.data])).files.first)
        #expect(decoded.size == 0)
        #expect(decoded.chunks.isEmpty)
    }

    @Test func rejectsInvalidUTF8() {
        var file = ProtobufWriter(); file.bytes(1, hexBytes("ff"))
        #expect(throws: LauncherError.io("invalid UTF-8")) { try SophonManifest.decode(manifestData([file.data])) }
    }

    @Test func rejectsInvalidMD5() {
        #expect(throws: LauncherError.invalidDigest("bad")) {
            try SophonManifest.decode(manifestData([manifestFile(md5: "bad")]))
        }
    }

    @Test func unknownChunkFieldsAreSkipped() throws {
        // Field 6 and 99 repeated with every supported wire type, including invalid UTF-8 bytes.
        let unknown = hexBytes("30 01 31 00 00 00 00 00 00 00 00 32 01 ff 35 00 00 00 00 98 06 01")
        let ordinary = manifestFile(chunks: [manifestChunk()])
        let extended = manifestFile(chunks: [manifestChunk() + unknown])
        #expect(try SophonManifest.decode(manifestData([extended])).files == SophonManifest.decode(manifestData([ordinary])).files)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"] != nil,
        "Set MACGACHA_SPIKE_FIXTURES to read local-only real manifests"))
    func realManifestsDecode() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"]))
        let fm = FileManager.default
        var found = 0
        for game in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.path < $1.path }) {
            guard try game.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            for file in try fm.contentsOfDirectory(at: game, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
                where file.lastPathComponent.hasSuffix("-manifest.zst") {
                try autoreleasepool {
                    let summaryURL = file.deletingPathExtension().appendingPathExtension("json")
                    let summaryPath = summaryURL.path.replacingOccurrences(of: "-manifest.json", with: "-manifest-summary.json")
                    let summary = try JSONDecoder().decode(RealSummary.self, from: Data(contentsOf: URL(fileURLWithPath: summaryPath)))
                    let size = try #require(Int(summary.manifest.uncompressed_size))
                    let data = try Zstd.decode(Data(contentsOf: file), expectedSize: size)
                    let manifest = try SophonManifest.decode(data)
                    let chunks = manifest.files.reduce(0) { $0 + $1.chunks.count }
                    #expect(manifest.files.count == summary.assets)
                    #expect(chunks == summary.chunk_references)
                    print("REAL \(game.lastPathComponent)/\(file.lastPathComponent): files=\(manifest.files.count), chunks=\(chunks)")
                }
                found += 1
            }
        }
        #expect(found == 8)
    }
}

private struct RealSummary: Decodable {
    struct Manifest: Decodable { let uncompressed_size: String }
    let manifest: Manifest
    let assets: Int
    let chunk_references: Int
}

let testMD5 = String(repeating: "0", count: 32)
func manifestChunk(id: String? = "chunk", md5: String? = testMD5, offset: UInt64? = nil,
    compressed: UInt64? = 150, decoded: UInt64? = 300, compressedMD5: String? = nil) -> Data {
    var w = ProtobufWriter()
    if let id { w.string(1, id) }; if let md5 { w.string(2, md5) }
    if let offset { w.varint(3, offset) }; if let compressed { w.varint(4, compressed) }
    if let decoded { w.varint(5, decoded) }; if let compressedMD5 { w.string(7, compressedMD5) }
    return w.data
}
func manifestFile(path: String = "file", size: UInt64 = 300, md5: String? = testMD5, type: UInt64 = 0,
    chunks: [Data] = [manifestChunk()]) -> Data {
    var w = ProtobufWriter(); w.string(1, path)
    for chunk in chunks { w.bytes(2, chunk) }
    w.varint(3, type); w.varint(4, size); if let md5 { w.string(5, md5) }
    return w.data
}
func manifestData(_ files: [Data]) -> Data {
    var w = ProtobufWriter(); for file in files { w.bytes(1, file) }; return w.data
}

private func fixedManifest(reverse: Bool = false) -> Data {
    // All bytes below are handwritten from protobuf's (field << 3 | wire) keys.
    // 0a 5d: manifest field 1, length-delimited, 93-byte file message.
    let path = "0a 07 61 2f 62 2e 64 61 74" // File field 1, 7 UTF-8 bytes: a/b.dat.
    let chunk = """
        12 2b
        0a 01 63
        12 20 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30
        20 96 01
        28 ac 02
        """
    // 12 2b: file field 2, 43-byte chunk. 0a 01 63: chunk field 1, id "c".
    // 12 20 + 32 x 30: chunk field 2, 32 ASCII zeros (decoded MD5).
    // Offset (chunk field 3) absent. 20 96 01: field 4, compressed size 150.
    // 28 ac 02: field 5, decoded size 300. Chunk field 7 absent.
    let type = "18 00" // File field 3, varint type 0 (regular file).
    let size = "20 ac 02" // File field 4, varint 300 = 44 + (2 << 7).
    let md5 = "2a 20 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30 30"
    // 2a 20 + 32 x 30: file field 5, 32-byte ASCII MD5.
    let fields = reverse ? [md5, size, type, chunk, path] : [path, chunk, type, size, md5]
    return hexBytes((["0a 5d"] + fields).joined(separator: " "))
}
