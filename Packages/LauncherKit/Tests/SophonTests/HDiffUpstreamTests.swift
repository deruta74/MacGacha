// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
@testable import Sophon

@Suite(.timeLimit(.minutes(1))) struct HDiffUpstreamTests {
    @Test(arguments: ["plain", "zstd"], [false, true])
    func upstreamGeneratedPatchesMatchGoldenSizeAndMD5(name: String, fragmented: Bool) async throws {
        let temporary = try TempDir()
        let source = try fixtureFileSystem(), destination = try ContainedFileSystem(root: temporary.url)
        let outputPath = try SafeRelativePath("output.bin")
        let output = try await BlockingIO.run { try destination.openForWriting(at: outputPath, truncate: true) }
        defer { try? output.close() }
        let old = try HDiff13.FileRange(fileSystem: source, path: SafeRelativePath("HDiffUpstream/old.bin"), length: 300_000)
        let patch = try HDiff13.FileRange(fileSystem: source, path: SafeRelativePath("HDiffUpstream/\(name).hdiff"),
            length: name == "plain" ? 86_690 : 26_304)
        if fragmented {
            // The fixture's entropy blocks are 5–11 KiB encoded. Both the encoded
            // input and decoded output cross these much smaller buffer boundaries.
            try await HDiff13.apply(old: old, patch: patch, expectedSize: 355_000, output: output,
                buffers: .init(read: 257, output: 1024), onStep: { _ in })
        } else {
            try await HDiff13.apply(old: old, patch: patch, expectedSize: 355_000, output: output)
        }
        let (size, digest) = try await BlockingIO.run {
            var size: Int64 = 0, hasher = StreamingHasher(.md5)
            try destination.readFile(at: outputPath, chunkSize: 997) { bytes in
                size += Int64(bytes.count); hasher.update(bytes)
            }
            return (size, hasher.finalize())
        }
        #expect(size == 355_000)
        #expect(digest.hex == "4e1e17e72ca60098640bce0765bc353c")
    }

    @Test func truncatedUpstreamZstdPatchIsMalformed() async throws {
        let temporary = try TempDir()
        let source = try fixtureFileSystem(), destination = try ContainedFileSystem(root: temporary.url)
        let truncatedPath = try SafeRelativePath("truncated-zstd.hdiff"), outputPath = try SafeRelativePath("output.bin")
        let output = try await BlockingIO.run {
            let patch = try source.readFile(at: SafeRelativePath("HDiffUpstream/zstd.hdiff"), maxBytes: 26_304)
            try destination.writeAtomically(Data(patch.dropLast()), to: truncatedPath)
            return try destination.openForWriting(at: outputPath, truncate: true)
        }
        defer { try? output.close() }
        await #expect(throws: LauncherError.malformedPatch) {
            try await HDiff13.apply(
                old: HDiff13.FileRange(fileSystem: source, path: SafeRelativePath("HDiffUpstream/old.bin"), length: 300_000),
                patch: HDiff13.FileRange(fileSystem: destination, path: truncatedPath, length: 26_303),
                expectedSize: 355_000, output: output, buffers: .init(read: 257, output: 1024), onStep: { _ in })
        }
    }

    private func fixtureFileSystem() throws -> ContainedFileSystem {
        try ContainedFileSystem(root: #require(Bundle.module.resourceURL))
    }
}
