// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine

@Suite struct PlanScaleTests {
    @Test func genshinScalePlanRoundTrips() throws {
        var objects: [String: ChunkObject] = [:]; objects.reserveCapacity(200_000)
        var files: [FileTask] = []; files.reserveCapacity(15_000)
        var ordinal = 0
        for index in 0..<15_000 {
            var extents: [Extent] = []
            let count = 13 + (index < 5000 ? 1 : 0)
            for chunk in 0..<count {
                let hash = String(format: "%032llx", UInt64(ordinal))
                let id = String(format: "%016llx", UInt64(ordinal)) + "_" + hash
                let prefix = "https://cdn.example.invalid/sophon/"
                let url = prefix + String(repeating: "p", count: 120 - prefix.utf8.count - 1 - id.utf8.count) + "/" + id
                let digest = try Digest(algorithm: .md5, hex: hash)
                let object = ChunkObject(id: id, urls: [URL(string: url)!], transferSize: 256 << 10,
                    transferDigest: digest, decodedSize: 1 << 20, decodedDigest: digest, codec: .zstd)
                objects[id] = object
                extents.append(Extent(source: .chunk(id: id), fileOffset: Int64(chunk) << 20,
                    length: 1 << 20, digest: digest))
                ordinal += 1
            }
            files.append(FileTask(path: try SafeRelativePath(String(format: "Game_Data/StreamingAssets/Blocks/%05d.blk", index)),
                size: Int64(count) << 20, digest: extents[0].digest, extents: extents))
        }
        let plan = InstallPlan(id: try SafeIdentifier("genshin-scale"), objects: objects, files: files)
        #expect(plan.objects.count == 200_000 && plan.files.count == 15_000)
        #expect(plan.objects.values.allSatisfy { $0.id.utf8.count == 49 && $0.urls[0].absoluteString.utf8.count == 120 })
        try plan.validate(supportedCodecs: [.identity, .zstd])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let start = ContinuousClock.now
        let encoded = try encoder.encode(plan)
        let encoding = start.duration(to: .now)
        #expect(encoded.count < 192 << 20)
        #expect(InstallPlan.maximumEncodedBytes == 256 << 20)
        #expect(encoded.count < InstallPlan.maximumEncodedBytes)
        let decodeStart = ContinuousClock.now
        let decoded = try JSONDecoder().decode(InstallPlan.self, from: encoded)
        let decoding = decodeStart.duration(to: .now)
        try decoded.validate()
        #expect(decoded.planDigest == plan.planDigest)
        print("PlanScale: objects=\(objects.count) files=\(files.count) encodedBytes=\(encoded.count) encode=\(encoding) decode=\(decoding)")
    }
}
