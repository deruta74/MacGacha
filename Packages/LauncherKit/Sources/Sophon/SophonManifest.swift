// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct SophonChunkRef: Sendable, Hashable {
    public let id: String
    public let decodedMD5: Digest
    public let fileOffset: Int64
    public let compressedSize: Int64
    public let decodedSize: Int64
    public let compressedMD5: Digest?
}

public struct SophonFile: Sendable, Hashable {
    public let path: SafeRelativePath
    public let size: Int64
    public let md5: Digest
    public let chunks: [SophonChunkRef]
}

public struct SophonManifest: Sendable {
    public let files: [SophonFile]

    /// Decodes regular files only. Type-64 directory entries are skipped and
    /// never returned; directories are created from each regular file's safe path.
    /// Unknown fields are skipped, but known scalar fields must occur at most once.
    public static func decode(_ protobuf: Data) throws -> SophonManifest {
        try decode(protobuf, limits: Limits())
    }

    // Testable at small limits; production shares the engine/planner limits.
    struct Limits {
        var files = InstallPlan.maximumFiles
        var chunksPerFile = InstallPlan.maximumExtents
        var chunks = InstallPlan.maximumExtents
    }

    static func decode(_ protobuf: Data, limits: Limits) throws -> SophonManifest {
        var reader = ProtobufReader(protobuf)
        var files: [SophonFile] = []
        var paths = Set<String>()
        var entries = 0, chunkCount = 0
        while let field = try reader.nextField() {
            guard field.number == 1 else { continue }
            // Count wire entries, including skipped directories, before decoding
            // any nested strings, digests, paths or chunks.
            guard entries < limits.files else { throw LauncherError.io("sophon file limit") }
            entries += 1
            if let file = try decodeFile(reader.child(field), limits: limits, chunkCount: &chunkCount) {
                let key = file.path.description.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard paths.insert(key).inserted else { throw LauncherError.io("duplicate path") }
                files.append(file)
            }
        }
        return SophonManifest(files: files)
    }

    private static func decodeFile(_ input: ProtobufReader, limits: Limits, chunkCount: inout Int) throws -> SophonFile? {
        var reader = input
        var seen = ScalarFields()
        var path: String?
        var type: UInt64 = 0
        var size: Int64 = 0
        var md5: Digest?
        var chunks: [SophonChunkRef] = []
        while let field = try reader.nextField() {
            if [1, 3, 4, 5].contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: path = try field.string()
            case 2:
                guard chunks.count < limits.chunksPerFile, chunkCount < limits.chunks else { throw LauncherError.io("sophon chunk limit") }
                chunkCount += 1
                chunks.append(try decodeChunk(reader.child(field)))
            case 3: type = try field.uint64()
            case 4: size = try field.int64()
            case 5: md5 = try Digest(algorithm: .md5, hex: field.string())
            default: break
            }
        }
        if type == 64 { return nil }
        guard type == 0 else { throw LauncherError.io("unsupported entry type") }
        guard let path, let md5 else { throw LauncherError.io("missing required field") }
        let safePath = try SafeRelativePath(path)
        chunks.sort { $0.fileOffset < $1.fileOffset }
        var end: Int64 = 0
        for chunk in chunks {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let (next, overflow) = chunk.fileOffset.addingReportingOverflow(chunk.decodedSize)
            guard !overflow, chunk.fileOffset == end, next <= size else { throw LauncherError.io("invalid chunk layout") }
            end = next
        }
        guard end == size else { throw LauncherError.io("invalid chunk layout") }
        return SophonFile(path: safePath, size: size, md5: md5, chunks: chunks)
    }

    private static func decodeChunk(_ input: ProtobufReader) throws -> SophonChunkRef {
        var reader = input
        var seen = ScalarFields()
        var id: String?
        var md5: Digest?
        var offset: Int64 = 0
        var compressed: Int64?
        var decoded: Int64?
        var compressedMD5: Digest?
        while let field = try reader.nextField() {
            if [1, 2, 3, 4, 5, 7].contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: id = try field.string()
            case 2: md5 = try Digest(algorithm: .md5, hex: field.string())
            case 3: offset = try field.int64()
            case 4: compressed = try field.int64()
            case 5: decoded = try field.int64()
            case 7: compressedMD5 = try Digest(algorithm: .md5, hex: field.string())
            default: break // Field 6 has no verified meaning; it is intentionally unknown.
            }
        }
        guard let id, !id.isEmpty, let md5, let compressed, let decoded else {
            throw LauncherError.io("missing required field")
        }
        guard id.utf8.count <= ChunkObject.maximumIDBytes else { throw LauncherError.io("invalid object id") }
        guard compressed > 0, decoded > 0 else { throw LauncherError.io("invalid chunk layout") }
        return SophonChunkRef(id: id, decodedMD5: md5, fileOffset: offset,
            compressedSize: compressed, decodedSize: decoded, compressedMD5: compressedMD5)
    }
}

/// Known fields fit in one byte; unknown fields neither allocate slots nor count as duplicates.
private struct ScalarFields {
    private var bits: UInt8 = 0
    mutating func insert(_ number: Int) throws {
        let bit = UInt8(1) << number
        guard bits & bit == 0 else { throw LauncherError.io("duplicate field") }
        bits |= bit
    }
}
