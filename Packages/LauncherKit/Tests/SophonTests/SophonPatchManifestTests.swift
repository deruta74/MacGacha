// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import Sophon

@Suite struct SophonPatchManifestTests {
    @Test func decodesSourceSpecificPatchesCopiesAndDeletes() throws {
        let data = patchManifest(files: [patchFile(instructions: [patchInfo(), patchInfo(tag: "0.9", chunk: patchInstruction(tag: "0.9", original: ""))]),
            patchFile(path: "unchanged", instructions: [])], deletions: [patchDeletes(), patchDeletes(tag: "0.9", paths: ["old/other"])])
        let manifest = try SophonPatchManifest.decode(data)
        #expect(manifest.files.count == 2)
        let file = try #require(manifest.files.first)
        #expect(file.path.description == "target/file")
        #expect(file.size == 5)
        #expect(file.md5.hex == testMD5)
        let instruction = try #require(file.patches["1.0"])
        #expect(instruction.containerID == "container")
        #expect(instruction.containerSize == 20)
        #expect(instruction.containerMD5.hex == testMD5)
        #expect(instruction.buildID == "source-build")
        #expect(instruction.offset == 3)
        #expect(instruction.length == 5)
        #expect(instruction.originalPath?.description == "old/file")
        #expect(instruction.originalSize == 8)
        #expect(instruction.originalMD5?.hex == testMD5)
        #expect(file.patches["0.9"]?.originalPath == nil)
        #expect(file.patches["0.9"]?.originalMD5 == nil)
        #expect(file.patches["missing"] == nil)
        #expect(manifest.files[1].patches.isEmpty)
        #expect(manifest.deletedFiles["1.0"]?.map(\.path.description) == ["old/file"])
        #expect(manifest.deletedFiles["1.0"]?.first?.size == 8)
        #expect(manifest.deletedFiles["1.0"]?.first?.md5.hex == testMD5)
        #expect(manifest.deletedFiles["0.9"]?.map(\.path.description) == ["old/other"])
        #expect(manifest.deletedFiles["missing"] == nil)
    }

    @Test func zeroDefaultsUnknownFieldsAndFieldOrder() throws {
        // Target field 1="x", field 3=32 ASCII zeroes; size is proto3's zero default.
        let wire = hexBytes("0a 25 0a 01 78 1a 20 " + Array(repeating: "30", count: 32).joined(separator: " "))
        #expect(try SophonPatchManifest.decode(wire).files.first?.size == 0)
        var unknown = ProtobufWriter(); unknown.varint(99, 7)
        let normal = patchManifest(files: [patchFile(instructions: [patchInfo()])])
        #expect(try SophonPatchManifest.decode(normal + unknown.data).files == SophonPatchManifest.decode(normal).files)
        let reordered = patchFile(instructions: [patchInfo()], reverse: true)
        #expect(try SophonPatchManifest.decode(patchManifest(files: [reordered])).files == SophonPatchManifest.decode(normal).files)
    }

    @Test(arguments: ["../escape", "/absolute", "a/../b", "a\\b", "a//b", "a\u{0}b", ""])
    func rejectsUnsafeFileNames(path: String) {
        #expect(throws: (any Error).self) { try SophonPatchManifest.decode(patchManifest(files: [patchFile(path: path)])) }
        if !path.isEmpty {
            #expect(throws: (any Error).self) { try SophonPatchManifest.decode(patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(original: path))])])) }
        }
        #expect(throws: (any Error).self) { try SophonPatchManifest.decode(patchManifest(deletions: [patchDeletes(paths: [path])])) }
        #expect(throws: (any Error).self) { try SophonPatchManifest.decode(patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(id: path))])])) }
    }

    @Test(arguments: [(UInt64(18), UInt64(5)), (UInt64(Int64.max), UInt64(1)), (UInt64(0), UInt64.max)])
    func rejectsOutOfRangeAndOverflowingSlices(offset: UInt64, length: UInt64) {
        #expect(throws: (any Error).self) {
            try SophonPatchManifest.decode(patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(offset: offset, length: length))])]))
        }
    }

    @Test func sliceMayEndExactlyAtContainerBoundary() throws {
        let data = patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(offset: 15))])])
        #expect(try SophonPatchManifest.decode(data).files.first?.patches["1.0"]?.offset == 15)
    }

    @Test func rejectsMissingFieldsAndInvalidDigests() {
        for data in [patchManifest(files: [Data()]), patchManifest(deletions: [Data()]),
            patchManifest(files: [patchFile(md5: "invalid")]),
            patchManifest(files: [patchFile(instructions: [patchInfo(chunk: Data())])]),
            patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(originalMD5: ""))])]),
            patchManifest(files: [patchFile(instructions: [patchInfo(tag: "")])]),
            patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(tag: "other"))])]),
            patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction(id: "nested/container"))])]),
            patchManifest(files: [patchFile(size: UInt64.max)])] {
            #expect(throws: (any Error).self) { try SophonPatchManifest.decode(data) }
        }
    }

    @Test func rejectsDuplicateScalarsPathsAndSourceTags() {
        var duplicate = ProtobufWriter(); duplicate.string(1, "again")
        for data in [patchManifest(files: [patchFile() + duplicate.data]),
            patchManifest(files: [patchFile(), patchFile(path: "TARGET/File")]),
            patchManifest(files: [patchFile(instructions: [patchInfo(), patchInfo()])]),
            patchManifest(files: [patchFile(instructions: [patchInfo(chunk: patchInstruction() + duplicate.data)])]),
            patchManifest(deletions: [patchDeletes(), patchDeletes()]),
            patchManifest(deletions: [patchDeletes(paths: ["old/file", "OLD/File"])])] {
            #expect(throws: (any Error).self) { try SophonPatchManifest.decode(data) }
        }
    }

    @Test func rawCopyRequiresExactTargetLength() {
        let data = patchManifest(files: [patchFile(size: 6, instructions: [patchInfo(chunk: patchInstruction(original: ""))])])
        #expect(throws: LauncherError.io("invalid raw copy")) { try SophonPatchManifest.decode(data) }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func countsAreCheckedBeforeNestedDecoding(kind: Int) {
        let bad = Data([0xff]); var limits = SophonPatchManifest.Limits()
        let data: Data
        switch kind {
        case 0: limits.files = 1; data = patchManifest(files: [patchFile(), bad])
        case 1: limits.patchesPerFile = 1; data = patchManifest(files: [patchFile(instructions: [patchInfo(), bad])])
        case 2: limits.patches = 1; data = patchManifest(files: [patchFile(instructions: [patchInfo()]), patchFile(path: "other", instructions: [bad])])
        case 3: limits.deletionGroups = 1; data = patchManifest(deletions: [patchDeletes(), bad])
        default: limits.deletedFiles = 1; data = patchManifest(deletions: [patchDeletes(paths: ["a", "b"])])
        }
        #expect(throws: LauncherError.io(kind == 0 ? "sophon patch file limit" : kind == 3 ? "sophon deletion group limit" : kind == 4 ? "sophon deleted file limit" : "sophon patch instruction limit")) {
            try SophonPatchManifest.decode(data, limits: limits)
        }
    }

    @Test func boundsBytesStringsAndEmptyDeletionLists() {
        var limits = SophonPatchManifest.Limits(); limits.bytes = 1
        #expect(throws: LauncherError.io("sophon patch byte limit")) {
            try SophonPatchManifest.decode(patchManifest(files: [patchFile()]), limits: limits)
        }
        #expect(throws: LauncherError.io("sophon patch string limit")) {
            try SophonPatchManifest.decode(patchManifest(files: [patchFile(path: String(repeating: "a", count: 4097))]))
        }
        #expect(throws: LauncherError.io("sophon patch string limit")) {
            try SophonPatchManifest.decode(patchManifest(files: [patchFile(instructions: [patchInfo(tag: String(repeating: "v", count: 257))])]))
        }
        var group = ProtobufWriter(); group.string(1, "1.0"); group.bytes(2, Data()); group.bytes(2, Data([0xff]))
        limits = .init(); limits.deletionLists = 1
        #expect(throws: LauncherError.io("sophon deletion list limit")) {
            try SophonPatchManifest.decode(patchManifest(deletions: [group.data]), limits: limits)
        }
    }

    @Test func cancellationStopsDecoder() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SophonPatchManifest.decode(patchManifest(files: [patchFile()]))
        }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
    }

    @Test func compressedManifestChecksSizeThenZstdThenDecodedMD5() throws {
        let protobuf = patchManifest(files: [patchFile()]); let compressed = rawZstd(protobuf)
        let ref = ManifestRef(id: "patch", decodedMD5: md5(protobuf), compressedSize: Int64(compressed.count), decodedSize: Int64(protobuf.count))
        #expect(try DeliveryAPI.decodePatchManifest(compressed, ref: ref).files.count == 1)
        #expect(throws: LauncherError.sizeMismatch(path: "manifest", expected: Int64(compressed.count), actual: 1)) {
            try DeliveryAPI.decodePatchManifest(Data([0]), ref: ref)
        }
        let wrong = ManifestRef(id: "patch", decodedMD5: md5(compressed), compressedSize: ref.compressedSize, decodedSize: ref.decodedSize)
        #expect(throws: LauncherError.digestMismatch(path: "manifest", expected: wrong.decodedMD5.hex, actual: ref.decodedMD5.hex)) {
            try DeliveryAPI.decodePatchManifest(compressed, ref: wrong)
        }
        let bad = Data([0x0b]); let frame = rawZstd(bad)
        let badRef = ManifestRef(id: "patch", decodedMD5: md5(bad), compressedSize: Int64(frame.count), decodedSize: 1)
        #expect(throws: LauncherError.io("invalid protobuf field")) { try DeliveryAPI.decodePatchManifest(frame, ref: badRef) }
    }
}

func patchManifest(files: [Data] = [], deletions: [Data] = []) -> Data {
    var w = ProtobufWriter(); for file in files { w.bytes(1, file) }; for group in deletions { w.bytes(2, group) }; return w.data
}
func patchFile(path: String = "target/file", size: UInt64 = 5, md5: String = testMD5, instructions: [Data] = [], reverse: Bool = false) -> Data {
    var fields: [Data] = []
    var w = ProtobufWriter(); w.string(1, path); fields.append(w.data)
    w = ProtobufWriter(); w.varint(2, size); fields.append(w.data)
    w = ProtobufWriter(); w.string(3, md5); fields.append(w.data)
    for info in instructions { w = ProtobufWriter(); w.bytes(4, info); fields.append(w.data) }
    return (reverse ? fields.reversed() : fields).reduce(Data(), +)
}
func patchInfo(tag: String = "1.0", chunk: Data = patchInstruction()) -> Data {
    var w = ProtobufWriter(); w.string(1, tag); w.bytes(2, chunk); return w.data
}
func patchInstruction(tag: String = "1.0", id: String = "container", offset: UInt64 = 3, length: UInt64 = 5,
    original: String = "old/file", originalMD5: String = testMD5) -> Data {
    var w = ProtobufWriter(); w.string(1, id); w.string(2, tag); w.string(3, "source-build")
    w.varint(4, 20); w.string(5, testMD5); w.varint(6, offset); w.varint(7, length)
    if !original.isEmpty { w.string(8, original); w.varint(9, 8); w.string(10, originalMD5) }
    return w.data
}
func patchDeletes(tag: String = "1.0", paths: [String] = ["old/file"]) -> Data {
    var group = ProtobufWriter(); group.string(1, tag)
    var list = ProtobufWriter()
    for path in paths {
        var file = ProtobufWriter(); file.string(1, path); file.varint(2, 8); file.string(3, testMD5); list.bytes(1, file.data)
    }
    group.bytes(2, list.data); return group.data
}
