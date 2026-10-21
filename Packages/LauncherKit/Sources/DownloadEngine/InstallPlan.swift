// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import LauncherCore

public struct ChunkObject: Codable, Sendable, Hashable {
    /// Opaque CDN IDs may contain separators; bound their UTF-8 storage independently of paths.
    public static let maximumIDBytes = 4096
    public let id: String
    public let urls: [URL]
    public let transferSize: Int64
    public let transferDigest: Digest?
    public let decodedSize: Int64
    public let decodedDigest: Digest
    public let codec: ChunkCodec

    public init(id: String, urls: [URL], transferSize: Int64, transferDigest: Digest? = nil,
        decodedSize: Int64, decodedDigest: Digest, codec: ChunkCodec = .identity) {
        self.id = id
        self.urls = urls
        self.transferSize = transferSize
        self.transferDigest = transferDigest
        self.decodedSize = decodedSize
        self.decodedDigest = decodedDigest
        self.codec = codec
    }

    private enum CodingKeys: String, CodingKey {
        case id, urls, transferSize, transferDigest, decodedSize, decodedDigest, codec
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        try Self.validateID(id)
        self.init(id: id,
            urls: try decodeBoundedArray(URL.self, from: c.superDecoder(forKey: .urls), maximum: InstallPlan.maximumURLsPerObject, kind: "object URLs"),
            transferSize: try c.decode(Int64.self, forKey: .transferSize),
            transferDigest: try c.decodeIfPresent(Digest.self, forKey: .transferDigest),
            decodedSize: try c.decode(Int64.self, forKey: .decodedSize),
            decodedDigest: try c.decode(Digest.self, forKey: .decodedDigest), codec: try c.decode(ChunkCodec.self, forKey: .codec))
        try validate()
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty else { throw invalidPlan("empty object id") }
        guard id.utf8.count <= maximumIDBytes else { throw invalidPlan("object id too long") }
    }

    public var partFileName: String {
        var hasher = StreamingHasher(.sha256)
        hasher.update(Data(id.utf8))
        return hasher.finalize().hex + ".part"
    }

    func validate() throws {
        try Self.validateID(id)
        try checkPlanCount(urls.count, maximum: InstallPlan.maximumURLsPerObject, kind: "object URLs")
        guard transferSize > 0, decodedSize > 0 else { throw invalidPlan("object sizes must be positive") }
        if codec == .identity {
            guard transferSize == decodedSize else { throw invalidPlan("identity object sizes differ") }
            if let transferDigest, transferDigest != decodedDigest { throw invalidPlan("identity object digests differ") }
        }
        guard !urls.isEmpty, urls.allSatisfy({
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host?.isEmpty == false
                && $0.user == nil && $0.password == nil
        }) else { throw invalidPlan("objects require credential-free HTTP(S) mirror URLs") }
    }
}

public enum ExtentSource: Codable, Sendable, Hashable {
    case chunk(id: String)
    case local(path: SafeRelativePath, offset: Int64)
}

public struct Extent: Codable, Sendable, Hashable {
    public let source: ExtentSource
    public let fileOffset: Int64
    public let length: Int64
    public let digest: Digest
    public let fallbackChunkID: String?

    public init(source: ExtentSource, fileOffset: Int64, length: Int64, digest: Digest, fallbackChunkID: String? = nil) {
        self.source = source
        self.fileOffset = fileOffset
        self.length = length
        self.digest = digest
        self.fallbackChunkID = fallbackChunkID
    }
}

public struct FileTask: Codable, Sendable, Hashable {
    public let path: SafeRelativePath
    public let size: Int64
    public let digest: Digest
    public let extents: [Extent]

    public init(path: SafeRelativePath, size: Int64, digest: Digest, extents: [Extent]) {
        self.path = path
        self.size = size
        self.digest = digest
        self.extents = extents
    }

    private enum CodingKeys: String, CodingKey { case path, size, digest, extents }
    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, maximumExtents: InstallPlan.maximumExtents)
    }

    fileprivate init(from decoder: any Decoder, maximumExtents: Int) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try c.decode(SafeRelativePath.self, forKey: .path), size: try c.decode(Int64.self, forKey: .size),
            digest: try c.decode(Digest.self, forKey: .digest),
            extents: try decodeBoundedArray(Extent.self, from: c.superDecoder(forKey: .extents), maximum: maximumExtents, kind: "extents"))
    }
}

public struct InstallPlan: Codable, Sendable {
    /// Disk readers must apply this bound before materializing JSON for decoding.
    public static let maximumEncodedBytes = 256 << 20
    public static let maximumObjects = 1_000_000
    public static let maximumURLsPerObject = 16
    public static let maximumFiles = 1_000_000
    public static let maximumDeletions = 1_000_000
    public static let maximumExtents = 2_000_000
    public let id: SafeIdentifier
    public let objects: [String: ChunkObject]
    public let files: [FileTask]
    public let deletions: [SafeRelativePath]

    /// Decoding validates structure independently of codec availability. Call validate()
    /// before executing either a decoded or a programmatically constructed plan.
    public init(id: SafeIdentifier, objects: [String: ChunkObject], files: [FileTask], deletions: [SafeRelativePath] = []) {
        self.id = id
        self.objects = objects
        self.files = files
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey { case id, objects, files, deletions }

    private struct ObjectKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(SafeIdentifier.self, forKey: .id)
        let objectContainer = try c.nestedContainer(keyedBy: ObjectKey.self, forKey: .objects)
        let keys = objectContainer.allKeys
        try checkPlanCount(keys.count, maximum: Self.maximumObjects, kind: "objects")
        var objects: [String: ChunkObject] = [:]
        for key in keys { objects[key.stringValue] = try objectContainer.decode(ChunkObject.self, forKey: key) }
        var fileContainer = try c.nestedUnkeyedContainer(forKey: .files)
        if let count = fileContainer.count { try checkPlanCount(count, maximum: Self.maximumFiles, kind: "files") }
        var files: [FileTask] = []
        var extentCount = 0
        while !fileContainer.isAtEnd {
            try checkPlanCount(files.count + 1, maximum: Self.maximumFiles, kind: "files")
            let file = try FileTask(from: fileContainer.superDecoder(), maximumExtents: Self.maximumExtents - extentCount)
            extentCount += file.extents.count
            files.append(file)
        }
        self.init(id: id, objects: objects, files: files,
            deletions: try decodeBoundedArray(SafeRelativePath.self, from: c.superDecoder(forKey: .deletions), maximum: Self.maximumDeletions, kind: "deletions"))
        try validate(supportedCodecs: Set(ChunkCodec.allCases))
    }

    public var planDigest: Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // This fixed-depth value graph encodes only strings, integers, enums and containers;
        // its synthesized encoders have no failure-producing values or custom callbacks.
        let bytes = try! encoder.encode(self)
        var hasher = StreamingHasher(.sha256)
        hasher.update(bytes)
        return hasher.finalize()
    }

    public func validate(supportedCodecs: Set<ChunkCodec> = ChunkCodec.supportedCodecs) throws {
        try checkPlanCount(objects.count, maximum: Self.maximumObjects, kind: "objects")
        try checkPlanCount(files.count, maximum: Self.maximumFiles, kind: "files")
        try checkPlanCount(deletions.count, maximum: Self.maximumDeletions, kind: "deletions")
        var extentCount = 0
        for file in files {
            try checkPlanCount(file.extents.count, maximum: Self.maximumExtents - extentCount, kind: "extents")
            extentCount += file.extents.count
        }
        for (key, object) in objects {
            guard key == object.id else { throw invalidPlan("object dictionary key does not match id") }
            try object.validate()
            guard supportedCodecs.contains(object.codec) else { throw LauncherError.io("codec unsupported: " + object.codec.rawValue) }
        }
        var destinations = Set<String>()
        var referenced = Set<String>()
        for file in files {
            try validateManifestPath(file.path)
            guard destinations.insert(pathKey(file.path)).inserted else { throw invalidPlan("duplicate file path") }
            guard file.size >= 0 else { throw invalidPlan("negative file size") }
            guard file.size != 0 || file.extents.isEmpty else { throw invalidPlan("empty files must have no extents") }
            var covered: Int64 = 0
            for extent in file.extents {
                guard extent.fileOffset >= 0, extent.fileOffset == covered, extent.length > 0 else {
                    throw invalidPlan("extent gap, overlap or invalid length")
                }
                let (end, overflow) = covered.addingReportingOverflow(extent.length)
                guard !overflow, end <= file.size else { throw invalidPlan("extent exceeds file size") }
                covered = end
                switch extent.source {
                case .chunk(let id):
                    guard extent.fallbackChunkID == nil else { throw invalidPlan("fallback is only allowed on local extents") }
                    try validateReference(id, length: extent.length, digest: extent.digest)
                    referenced.insert(id)
                case .local(let path, let offset):
                    try validateManifestPath(path)
                    guard offset >= 0, !offset.addingReportingOverflow(extent.length).overflow else {
                        throw invalidPlan("invalid local extent range")
                    }
                }
                if let fallback = extent.fallbackChunkID {
                    try validateReference(fallback, length: extent.length, digest: extent.digest)
                    referenced.insert(fallback)
                }
            }
            guard covered == file.size else { throw invalidPlan("short file coverage") }
        }
        // Test component prefixes rather than string prefixes (Data and Data2 are distinct).
        var destinationAncestors = Set<String>()
        for file in files {
            var ancestor = ""
            for component in file.path.components.dropLast() {
                if !ancestor.isEmpty { ancestor += "/" }
                ancestor += component
                destinationAncestors.insert(caseFold(ancestor))
                if destinations.contains(caseFold(ancestor)) {
                    throw invalidPlan("file path is an ancestor of another destination")
                }
            }
        }
        var deleted = Set<String>()
        for path in deletions {
            try validateManifestPath(path)
            let key = pathKey(path)
            guard deleted.insert(key).inserted else { throw invalidPlan("duplicate deletion path") }
            guard !destinations.contains(key) else { throw invalidPlan("path both installed and deleted") }
            guard !destinationAncestors.contains(key) else { throw invalidPlan("deletion overlaps installed path") }
            var ancestor = ""
            for component in path.components.dropLast() {
                if !ancestor.isEmpty { ancestor += "/" }
                ancestor += component
                guard !destinations.contains(caseFold(ancestor)) else { throw invalidPlan("deletion overlaps installed path") }
            }
        }
        guard referenced == Set(objects.keys) else { throw invalidPlan("orphan object") }
    }

    private func validateReference(_ id: String, length: Int64, digest: Digest) throws {
        guard let object = objects[id] else { throw invalidPlan("missing object") }
        guard object.decodedSize == length else { throw invalidPlan("extent and object decoded size mismatch") }
        guard object.decodedDigest == digest else { throw invalidPlan("extent and object decoded digest mismatch") }
    }
}

private func validateManifestPath(_ path: SafeRelativePath) throws {
    let first = caseFold(path.components[0])
    guard first != ".macgacha-staging", first != ".macgacha-state.json", first != ".macgacha-receipts" else {
        throw LauncherError.unsafePath(path.description)
    }
}

private func pathKey(_ path: SafeRelativePath) -> String {
    caseFold(path.description)
}

private func caseFold(_ value: String) -> String {
    value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}

func invalidPlan(_ reason: String) -> LauncherError { .io("invalid plan: " + reason) }

private func checkPlanCount(_ count: Int, maximum: Int, kind: String) throws {
    guard count <= maximum else { throw invalidPlan("too many " + kind) }
}

private func decodeBoundedArray<T: Decodable>(_ type: T.Type, from decoder: any Decoder,
    maximum: Int, kind: String) throws -> [T] {
    var container = try decoder.unkeyedContainer()
    if let count = container.count { try checkPlanCount(count, maximum: maximum, kind: kind) }
    var values: [T] = []
    while !container.isAtEnd {
        try checkPlanCount(values.count + 1, maximum: maximum, kind: kind)
        values.append(try container.decode(T.self))
    }
    return values
}
