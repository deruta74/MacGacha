// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct SophonPatchInstruction: Sendable, Hashable {
    public let containerID: String
    public let containerSize: Int64
    public let containerMD5: Digest
    public let buildID: String
    public let offset: Int64
    public let length: Int64
    /// nil denotes raw target bytes, rather than an HDiff patch from an old file.
    public let originalPath: SafeRelativePath?
    public let originalSize: Int64
    public let originalMD5: Digest?
}

public struct SophonPatchFile: Sendable, Hashable {
    public let path: SafeRelativePath
    public let size: Int64
    public let md5: Digest
    public let patches: [String: SophonPatchInstruction]
}

public struct SophonDeletedFile: Sendable, Hashable {
    public let path: SafeRelativePath
    public let size: Int64
    public let md5: Digest
}

public struct SophonPatchManifest: Sendable {
    public let files: [SophonPatchFile]
    public let deletedFiles: [String: [SophonDeletedFile]]

    public static func decode(_ protobuf: Data) throws -> SophonPatchManifest {
        try decode(protobuf, limits: Limits())
    }

    struct Limits {
        var bytes = 512 << 20
        var files = InstallPlan.maximumFiles
        var patchesPerFile = 256
        var patches = InstallPlan.maximumExtents
        var deletionGroups = 256
        var deletionLists = InstallPlan.maximumFiles
        var deletedFiles = InstallPlan.maximumFiles
    }

    // Field numbers follow Hi3Helper.Sophon SophonPatchProto.proto at
    // 9d3861307039df579d553a22aad723e31fb6aa5b; fixtures are independently handcrafted.
    static func decode(_ protobuf: Data, limits: Limits) throws -> SophonPatchManifest {
        guard protobuf.count <= limits.bytes else { throw LauncherError.io("sophon patch byte limit") }
        var reader = ProtobufReader(protobuf)
        var files: [SophonPatchFile] = [], paths = Set<String>()
        var deleted: [String: [SophonDeletedFile]] = [:]
        var patches = 0, deletedCount = 0, lists = 0
        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                guard files.count < limits.files else { throw LauncherError.io("sophon patch file limit") }
                let file = try decodeFile(reader.child(field), limits: limits, patches: &patches)
                guard paths.insert(pathKey(file.path)).inserted else { throw LauncherError.io("duplicate path") }
                files.append(file)
            case 2:
                guard deleted.count < limits.deletionGroups else { throw LauncherError.io("sophon deletion group limit") }
                let (tag, entries) = try decodeDeletions(reader.child(field), limits: limits, deleted: &deletedCount, lists: &lists)
                guard deleted.updateValue(entries, forKey: tag) == nil else { throw LauncherError.io("duplicate source tag") }
            default: break
            }
        }
        return SophonPatchManifest(files: files, deletedFiles: deleted)
    }

    private static func decodeFile(_ input: ProtobufReader, limits: Limits, patches: inout Int) throws -> SophonPatchFile {
        var reader = input, seen = PatchScalarFields()
        var name: String?, md5: Digest?, size: Int64 = 0
        var instructions: [String: SophonPatchInstruction] = [:]
        while let field = try reader.nextField() {
            if (1...3).contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: name = try text(field)
            case 2: size = try field.int64()
            case 3: md5 = try digest(field)
            case 4:
                guard instructions.count < limits.patchesPerFile, patches < limits.patches else {
                    throw LauncherError.io("sophon patch instruction limit")
                }
                patches += 1
                let (tag, instruction) = try decodeInfo(reader.child(field))
                guard instructions.updateValue(instruction, forKey: tag) == nil else { throw LauncherError.io("duplicate source tag") }
            default: break
            }
        }
        guard let name, let md5 else { throw LauncherError.io("missing required field") }
        for instruction in instructions.values where instruction.originalPath == nil {
            guard instruction.length == size else { throw LauncherError.io("invalid raw copy") }
        }
        return try SophonPatchFile(path: SafeRelativePath(name), size: size, md5: md5, patches: instructions)
    }

    private static func decodeInfo(_ input: ProtobufReader) throws -> (String, SophonPatchInstruction) {
        var reader = input, seen = PatchScalarFields()
        var tag: String?, chunk: (String, SophonPatchInstruction)?
        while let field = try reader.nextField() {
            if (1...2).contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: tag = try identifier(field)
            case 2: chunk = try decodeInstruction(reader.child(field))
            default: break
            }
        }
        guard let tag, let (innerTag, instruction) = chunk else { throw LauncherError.io("missing required field") }
        guard tag == innerTag else { throw LauncherError.io("inconsistent source tag") }
        return (tag, instruction)
    }

    private static func decodeInstruction(_ input: ProtobufReader) throws -> (String, SophonPatchInstruction) {
        var reader = input, seen = PatchScalarFields()
        var id: String?, tag: String?, build: String?, md5: Digest?
        var size: Int64 = 0, offset: Int64 = 0, length: Int64 = 0, originalSize: Int64 = 0
        var original = "", originalHash = ""
        while let field = try reader.nextField() {
            if (1...10).contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: id = try text(field)
            case 2: tag = try identifier(field)
            case 3: build = try identifier(field)
            case 4: size = try field.int64()
            case 5: md5 = try digest(field)
            case 6: offset = try field.int64()
            case 7: length = try field.int64()
            case 8: original = try text(field)
            case 9: originalSize = try field.int64()
            case 10: originalHash = try text(field, limit: 32)
            default: break
            }
        }
        guard let id, let tag, let build, let md5 else { throw LauncherError.io("missing required field") }
        let container = try SafeRelativePath(id)
        guard container.components.count == 1, id.utf8.count <= ChunkObject.maximumIDBytes else { throw LauncherError.io("invalid object id") }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard size > 0, !overflow, end <= size else { throw LauncherError.io("invalid patch slice") }
        let originalPath: SafeRelativePath?, originalMD5: Digest?
        if original.isEmpty {
            guard originalSize == 0, originalHash.isEmpty else { throw LauncherError.io("invalid raw copy") }
            originalPath = nil; originalMD5 = nil
        } else {
            guard length > 0 else { throw LauncherError.io("invalid patch slice") }
            originalPath = try SafeRelativePath(original)
            originalMD5 = try Digest(algorithm: .md5, hex: originalHash)
        }
        return (tag, SophonPatchInstruction(containerID: id, containerSize: size, containerMD5: md5, buildID: build,
            offset: offset, length: length, originalPath: originalPath, originalSize: originalSize, originalMD5: originalMD5))
    }

    private static func decodeDeletions(_ input: ProtobufReader, limits: Limits, deleted: inout Int,
        lists: inout Int) throws -> (String, [SophonDeletedFile]) {
        var reader = input, seen = PatchScalarFields()
        var tag: String?, files: [SophonDeletedFile] = [], paths = Set<String>()
        while let field = try reader.nextField() {
            switch field.number {
            case 1: try seen.insert(1); tag = try identifier(field)
            case 2:
                guard lists < limits.deletionLists else { throw LauncherError.io("sophon deletion list limit") }
                lists += 1
                var list = try reader.child(field)
                while let entry = try list.nextField() {
                    guard entry.number == 1 else { continue }
                    guard deleted < limits.deletedFiles else { throw LauncherError.io("sophon deleted file limit") }
                    deleted += 1
                    let file = try decodeDeletedFile(list.child(entry))
                    guard paths.insert(pathKey(file.path)).inserted else { throw LauncherError.io("duplicate path") }
                    files.append(file)
                }
            default: break
            }
        }
        guard let tag else { throw LauncherError.io("missing required field") }
        return (tag, files)
    }

    private static func decodeDeletedFile(_ input: ProtobufReader) throws -> SophonDeletedFile {
        var reader = input, seen = PatchScalarFields()
        var name: String?, md5: Digest?, size: Int64 = 0
        while let field = try reader.nextField() {
            if (1...3).contains(field.number) { try seen.insert(field.number) }
            switch field.number {
            case 1: name = try text(field)
            case 2: size = try field.int64()
            case 3: md5 = try digest(field)
            default: break
            }
        }
        guard let name, let md5 else { throw LauncherError.io("missing required field") }
        return try SophonDeletedFile(path: SafeRelativePath(name), size: size, md5: md5)
    }

    private static func text(_ field: ProtobufReader.Field, limit: Int = 4096) throws -> String {
        guard try field.bytes().count <= limit else { throw LauncherError.io("sophon patch string limit") }
        return try field.string()
    }
    private static func identifier(_ field: ProtobufReader.Field) throws -> String {
        let value = try text(field, limit: 256)
        guard !value.isEmpty, !value.utf8.contains(0) else { throw LauncherError.io("invalid patch identifier") }
        return value
    }
    private static func digest(_ field: ProtobufReader.Field) throws -> Digest {
        try Digest(algorithm: .md5, hex: text(field, limit: 32))
    }
    private static func pathKey(_ path: SafeRelativePath) -> String {
        path.description.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private struct PatchScalarFields {
    private var bits: UInt16 = 0
    mutating func insert(_ number: Int) throws {
        let bit = UInt16(1) << number
        guard bits & bit == 0 else { throw LauncherError.io("duplicate field") }
        bits |= bit
    }
}
