// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct GameBranch: Sendable, Codable {
    public let gameID: String
    public let biz: String
    public let packageID: String
    public let password: String
    public let branch: String
    public let tag: String
    public let categories: [BranchCategory]
    public init(gameID: String, biz: String, packageID: String, password: String, branch: String, tag: String, categories: [BranchCategory]) {
        self.gameID = gameID; self.biz = biz; self.packageID = packageID; self.password = password
        self.branch = branch; self.tag = tag; self.categories = categories
    }
}

public struct BranchCategory: Sendable, Codable, Hashable {
    public let id: String
    public let matchingField: String
    public let isAudio: Bool
    public let inFullScenario: Bool
    public init(id: String, matchingField: String, isAudio: Bool, inFullScenario: Bool) {
        self.id = id; self.matchingField = matchingField; self.isAudio = isAudio; self.inFullScenario = inFullScenario
    }
}

public struct GameConfig: Sendable, Codable {
    public let installationDir: SafeRelativePath
    public let executable: SafeRelativePath
    public init(installationDir: SafeRelativePath, executable: SafeRelativePath) {
        self.installationDir = installationDir; self.executable = executable
    }
}

public struct SophonBuild: Sendable, Codable {
    public let buildID: String
    public let tag: String
    public let categories: [BuildCategory]
    public init(buildID: String, tag: String, categories: [BuildCategory]) {
        self.buildID = buildID; self.tag = tag; self.categories = categories
    }
}

public struct ManifestRef: Sendable, Codable, Hashable {
    public let id: String
    /// MD5 of the decoded protobuf, never of its compressed representation.
    public let decodedMD5: Digest
    public let compressedSize: Int64
    public let decodedSize: Int64
    public init(id: String, decodedMD5: Digest, compressedSize: Int64, decodedSize: Int64) {
        self.id = id; self.decodedMD5 = decodedMD5; self.compressedSize = compressedSize; self.decodedSize = decodedSize
    }

    private enum CodingKeys: String, CodingKey { case id, decodedMD5, compressedSize, decodedSize }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), decodedMD5: try c.decode(Digest.self, forKey: .decodedMD5),
            compressedSize: try c.decode(Int64.self, forKey: .compressedSize), decodedSize: try c.decode(Int64.self, forKey: .decodedSize))
        try validate()
    }

    func validate() throws {
        guard compressedSize > 0, compressedSize <= 128 << 20, decodedSize >= 0, decodedSize <= 512 << 20 else {
            throw LauncherError.io("manifest size limit")
        }
        guard !id.isEmpty, id.utf8.count <= 4096, decodedMD5.algorithm == .md5 else {
            throw LauncherError.io("invalid manifest reference")
        }
    }
}

public struct BuildCategory: Sendable, Codable, Hashable {
    /// Persist the policy alongside descriptors, including in paused operations.
    public let region: Region
    public let id: String
    public let matchingField: String
    public let manifest: ManifestRef
    public let manifestPrefix: URL
    public let manifestSuffix: String
    public let chunkPrefix: URL
    public let chunkSuffix: String
    public let compressedSize: Int64
    public let decodedSize: Int64
    public init(id: String, matchingField: String, manifest: ManifestRef, manifestPrefix: URL, manifestSuffix: String,
        chunkPrefix: URL, chunkSuffix: String, compressedSize: Int64, decodedSize: Int64, region: Region = .global) {
        self.region = region
        self.id = id; self.matchingField = matchingField; self.manifest = manifest
        self.manifestPrefix = manifestPrefix; self.manifestSuffix = manifestSuffix
        self.chunkPrefix = chunkPrefix; self.chunkSuffix = chunkSuffix
        self.compressedSize = compressedSize; self.decodedSize = decodedSize
    }

    public var manifestURL: URL { get throws { try deliveryURL(prefix: manifestPrefix, id: manifest.id, suffix: manifestSuffix, region: region) } }
    public func chunkURL(id: String) throws -> URL { try deliveryURL(prefix: chunkPrefix, id: id, suffix: chunkSuffix, region: region) }

    private enum CodingKeys: String, CodingKey {
        case id, matchingField, manifest, manifestPrefix, manifestSuffix, chunkPrefix, chunkSuffix, compressedSize, decodedSize, region
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), matchingField: try c.decode(String.self, forKey: .matchingField),
            manifest: try c.decode(ManifestRef.self, forKey: .manifest), manifestPrefix: try c.decode(URL.self, forKey: .manifestPrefix),
            manifestSuffix: try c.decode(String.self, forKey: .manifestSuffix), chunkPrefix: try c.decode(URL.self, forKey: .chunkPrefix),
            chunkSuffix: try c.decode(String.self, forKey: .chunkSuffix), compressedSize: try c.decode(Int64.self, forKey: .compressedSize),
            decodedSize: try c.decode(Int64.self, forKey: .decodedSize), region: try c.decodeIfPresent(Region.self, forKey: .region) ?? .global)
        try validate()
    }

    func validate() throws {
        guard DeliveryHostPolicy.allows(manifestPrefix, region: region), DeliveryHostPolicy.allows(chunkPrefix, region: region) else {
            throw LauncherError.io("untrusted delivery host")
        }
        try manifest.validate()
        guard compressedSize >= 0, decodedSize >= 0 else { throw LauncherError.io("invalid delivery response") }
        _ = try manifestURL
        _ = try chunkURL(id: "validation")
    }
}
