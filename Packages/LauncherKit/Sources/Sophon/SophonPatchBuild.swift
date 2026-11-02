// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct SophonPatchBuild: Sendable, Codable {
    public let buildID: String
    public let patchID: String
    public let tag: String
    public let categories: [PatchBuildCategory]
}

public struct PatchBuildStats: Sendable, Codable, Hashable {
    public let compressedSize: Int64
    public let decodedSize: Int64
    public let fileCount: Int64
    public let chunkCount: Int64

    func validate() throws {
        guard compressedSize >= 0, decodedSize >= 0, fileCount >= 0, chunkCount >= 0 else {
            throw LauncherError.io("invalid delivery response")
        }
    }
}

public struct PatchBuildCategory: Sendable, Codable, Hashable {
    public let region: Region
    public let id: String
    public let matchingField: String
    public let manifest: ManifestRef
    public let manifestPrefix: URL
    public let manifestSuffix: String
    public let diffPrefix: URL
    public let diffSuffix: String
    public let diffCodec: ChunkCodec
    /// Server totals keyed by the installed source version, never the target tag.
    public let stats: [String: PatchBuildStats]

    public var manifestURL: URL { get throws { try deliveryURL(prefix: manifestPrefix, id: manifest.id, suffix: manifestSuffix, region: region) } }
    public func diffURL(id: String) throws -> URL { try deliveryURL(prefix: diffPrefix, id: id, suffix: diffSuffix, region: region) }

    init(region: Region, id: String, matchingField: String, manifest: ManifestRef,
        manifestPrefix: URL, manifestSuffix: String, diffPrefix: URL, diffSuffix: String,
        diffCodec: ChunkCodec, stats: [String: PatchBuildStats]) {
        self.region = region; self.id = id; self.matchingField = matchingField; self.manifest = manifest
        self.manifestPrefix = manifestPrefix; self.manifestSuffix = manifestSuffix
        self.diffPrefix = diffPrefix; self.diffSuffix = diffSuffix; self.diffCodec = diffCodec; self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case region, id, matchingField, manifest, manifestPrefix, manifestSuffix, diffPrefix, diffSuffix, diffCodec, stats
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(region: try c.decode(Region.self, forKey: .region), id: try c.decode(String.self, forKey: .id),
            matchingField: try c.decode(String.self, forKey: .matchingField), manifest: try c.decode(ManifestRef.self, forKey: .manifest),
            manifestPrefix: try c.decode(URL.self, forKey: .manifestPrefix), manifestSuffix: try c.decode(String.self, forKey: .manifestSuffix),
            diffPrefix: try c.decode(URL.self, forKey: .diffPrefix), diffSuffix: try c.decode(String.self, forKey: .diffSuffix),
            diffCodec: try c.decode(ChunkCodec.self, forKey: .diffCodec), stats: try c.decode([String: PatchBuildStats].self, forKey: .stats))
        try validate()
    }

    func validate() throws {
        guard DeliveryHostPolicy.allows(manifestPrefix, region: region), DeliveryHostPolicy.allows(diffPrefix, region: region) else {
            throw LauncherError.io("untrusted delivery host")
        }
        try manifest.validate()
        for value in stats.values { try value.validate() }
        _ = try manifestURL
        _ = try diffURL(id: "validation")
    }
}
