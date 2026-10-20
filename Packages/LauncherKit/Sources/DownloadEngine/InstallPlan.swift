// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import LauncherCore

public struct ChunkObject: Codable, Sendable, Hashable {
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

    public var partFileName: String {
        var hasher = StreamingHasher(.sha256)
        hasher.update(Data(id.utf8))
        return hasher.finalize().hex + ".part"
    }

    func validate() throws {
        guard !id.isEmpty else { throw invalidPlan("empty object id") }
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
}

public struct InstallPlan: Codable, Sendable {
    public let id: SafeIdentifier
    public let objects: [String: ChunkObject]
    public let files: [FileTask]
    public let deletions: [SafeRelativePath]

    /// Call validate() before using a programmatically constructed plan. Decoding validates automatically.
    public init(id: SafeIdentifier, objects: [String: ChunkObject], files: [FileTask], deletions: [SafeRelativePath] = []) {
        self.id = id
        self.objects = objects
        self.files = files
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey { case id, objects, files, deletions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(SafeIdentifier.self, forKey: .id), objects: try c.decode([String: ChunkObject].self, forKey: .objects),
            files: try c.decode([FileTask].self, forKey: .files), deletions: try c.decode([SafeRelativePath].self, forKey: .deletions))
        try validate()
    }

    public var planDigest: Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This fixed-depth value graph encodes only strings, integers, enums and containers;
        // its synthesized encoders have no failure-producing values or custom callbacks.
        let bytes = try! encoder.encode(self)
        var hasher = StreamingHasher(.sha256)
        hasher.update(bytes)
        return hasher.finalize()
    }

    public func validate() throws {
        for (key, object) in objects {
            guard key == object.id else { throw invalidPlan("object dictionary key does not match id") }
            try object.validate()
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
                guard extent.fileOffset == covered, extent.length > 0 else { throw invalidPlan("extent gap, overlap or invalid length") }
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
        for file in files {
            var ancestor = ""
            for component in file.path.components.dropLast() {
                if !ancestor.isEmpty { ancestor += "/" }
                ancestor += component
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
    let first = path.components[0].lowercased()
    guard first != ".macgacha-staging", first != ".macgacha-state.json" else {
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
