// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore

@Test func borrowedDigestBuffersPreserveVectorsAndValueCopies() {
    let bytes = Data("abc".utf8)
    var hash = StreamingHasher(.md5)
    bytes.withUnsafeBytes { hash.update(buffer: $0) }
    #expect(hash.finalize().hex == "900150983cd24fb0d6963f7d28e17f72")
    let copy = hash
    Data("d".utf8).withUnsafeBytes { hash.update(buffer: $0) }
    #expect(copy.finalize().hex == "900150983cd24fb0d6963f7d28e17f72")
    #expect(hash.finalize().hex == "e2fc714c4727ee9395f324cd2e7f331f")
    var sha = StreamingHasher(.sha256)
    bytes.withUnsafeBytes { sha.update(buffer: $0) }
    #expect(sha.finalize().hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func digestByteParsingPreservesWhitespaceAndRejectsNonASCII() throws {
    let valid = "D41D8CD98F00B204E9800998ECF8427E"
    for raw in [valid, "\t\r\n" + valid + " ", "\u{00a0}" + valid + "\u{2003}"] {
        #expect(try Digest(algorithm: .md5, hex: raw).hex == valid.lowercased())
    }
    for raw in ["é" + String(repeating: "0", count: 30), "Ｆ" + String(repeating: "0", count: 31),
        "0 " + String(repeating: "0", count: 30), String(repeating: "G", count: 32)] {
        #expect(throws: LauncherError.invalidDigest(raw)) { try Digest(algorithm: .md5, hex: raw) }
    }
}

@Test
func digestNormalizesCaseAndWhitespace() throws {
    let digest = try Digest(algorithm: .md5, hex: "  D41D8CD98F00B204E9800998ECF8427E\n")
    #expect(digest.hex == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(digest.algorithm == .md5)
    #expect(DigestAlgorithm.md5.hexLength == 32)
    #expect(DigestAlgorithm.sha256.hexLength == 64)
    #expect(try JSONDecoder().decode(Digest.self, from: JSONEncoder().encode(digest)) == digest)
}

@Test
func digestRejectsWrongLength() throws {
    let cases: [(DigestAlgorithm, String)] = [
        (.md5, String(repeating: "a", count: 31)),
        (.md5, String(repeating: "z", count: 32)),
        (.sha256, String(repeating: "a", count: 32)),
        (.md5, String(repeating: "a", count: 33)),
        (.sha256, String(repeating: "a", count: 65)),
    ]
    for (algorithm, raw) in cases {
        #expect(throws: LauncherError.invalidDigest(raw)) {
            try Digest(algorithm: algorithm, hex: raw)
        }
        let json = try JSONEncoder().encode(["algorithm": algorithm.rawValue, "hex": raw])
        #expect(throws: LauncherError.invalidDigest(raw)) {
            try JSONDecoder().decode(Digest.self, from: json)
        }
    }
}

@Test
func hasherKnownVectors() async throws {
    var sha256 = StreamingHasher(.sha256)
    sha256.update(Data("a".utf8))
    sha256.update(Data("bc".utf8))
    #expect(sha256.finalize().hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(StreamingHasher(.md5).finalize().hex == "d41d8cd98f00b204e9800998ecf8427e")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("blob.bin")
    let bytes = Data(repeating: 0xa5, count: 3 << 20)
    try bytes.write(to: file)
    for algorithm in [DigestAlgorithm.sha256, .md5] {
        var streaming = StreamingHasher(algorithm)
        streaming.update(bytes)
        #expect(try await FileHasher.digest(of: file, algorithm: algorithm) == streaming.finalize())
        #expect(try await FileHasher.digest(of: file, algorithm: algorithm, bufferSize: 65_537) == streaming.finalize())
    }
}
