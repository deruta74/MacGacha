// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import TestSupport
@testable import Sophon

@Suite(.timeLimit(.minutes(1))) struct HDiff13Tests {
    @Test func appliesCoversAndNewDataInsideContainedRanges() async throws {
        let fixture = try HDiffFixture()
        let old = Data("abcdefghij".utf8), expected = Data("abXYefgh!".utf8)
        let patch = hdiffPatch(oldSize: 10, newSize: 9, covers: Data([0, 0, 2, 2, 2, 4]), coverCount: 2,
            control: Data([8]), newData: Data("XY!".utf8))
        try fixture.store(old: Data([99]) + old + Data([98]), patch: Data([97, 96]) + patch + Data([95]))
        let output = try fixture.output()
        defer { try? output.close() }
        try await HDiff13.apply(old: fixture.range("old", offset: 1, length: 10),
            patch: fixture.range("patch", offset: 2, length: Int64(patch.count)), expectedSize: 9, output: output)
        #expect(try fixture.readOutput() == expected)
        #expect(try fixture.fs.readFile(at: SafeRelativePath("old"), maxBytes: 100) == Data([99]) + old + Data([98]))
    }

    @Test func backwardCoversAndRleDifferences() async throws {
        let fixture = try HDiffFixture()
        // Covers old[8..<10], then old[0..<2]. The second old delta is -10 (0x8a).
        // RLE literal deltas [0,0,0,1] turn "ijab" into "ijac".
        let patch = hdiffPatch(oldSize: 10, newSize: 4, covers: Data([8, 0, 2, 0x8a, 0, 2]), coverCount: 2,
            control: Data([0xc3]), rle: Data([0, 0, 0, 1]))
        try fixture.store(old: Data("abcdefghij".utf8), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        try await HDiff13.apply(old: fixture.range("old", length: 10), patch: fixture.range("patch", length: Int64(patch.count)),
            expectedSize: 4, output: output)
        #expect(try fixture.readOutput() == Data("ijac".utf8))
    }

    @Test(arguments: [0, 250_000]) func rawNewDataAndEmptyOutput(size: Int) async throws {
        let fixture = try HDiffFixture(), expected = Data(repeating: 65, count: size)
        let patch = hdiffPatch(oldSize: 0, newSize: UInt64(size), control: size == 0 ? Data() : hdiffUInt(UInt64(size - 1), tagBits: 2), newData: expected)
        try fixture.store(old: Data(), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        try output.write(contentsOf: Data(repeating: 7, count: size + 10))
        try await HDiff13.apply(old: fixture.range("old", length: 0), patch: fixture.range("patch", length: Int64(patch.count)),
            expectedSize: Int64(size), output: output)
        #expect(try fixture.readOutput() == expected)
    }

    @Test func classifiesHeaderErrorsBeforeWriting() async throws {
        let fixture = try HDiffFixture()
        for (patch, failure) in [
            (Data("bad".utf8), LauncherError.malformedPatch),
            (hdiffPatch(oldSize: 1, newSize: 1, compressor: "lzma"), .unsupportedCompressor),
            (hdiffPatch(oldSize: 2, newSize: 1), .sizeMismatch(path: "HDiff source", expected: 2, actual: 1)),
            (hdiffPatch(oldSize: 1, newSize: 2), .sizeMismatch(path: "HDiff output", expected: 1, actual: 2))
        ] {
            try fixture.store(old: Data([1]), patch: patch)
            let output = try fixture.output(); defer { try? output.close() }
            try output.write(contentsOf: Data([42]))
            await #expect(throws: failure) {
                try await HDiff13.apply(old: fixture.range("old", length: 1), patch: fixture.range("patch", length: Int64(patch.count)),
                    expectedSize: 1, output: output)
            }
            #expect(try fixture.readOutput() == Data([42]))
        }
    }

    @Test func truncationsAndOverflowingHeadersAreMalformed() async throws {
        let fixture = try HDiffFixture()
        let valid = hdiffPatch(oldSize: 2, newSize: 3, covers: Data([0, 0, 2]), coverCount: 1,
            control: Data([2]), newData: Data([33]))
        var invalid = (0..<valid.count).map { Data(valid.prefix($0)) }
        invalid.append(valid + Data([0]))
        invalid.append(hdiffPatch(oldSize: UInt64.max, newSize: 3))
        invalid.append(hdiffPatch(oldSize: 2, newSize: UInt64.max))
        // Claimed cover section size wraps if naively added to the header offset.
        var overflow = Data("HDIFF13&\0".utf8)
        for n: UInt64 in [3, 2, 1, UInt64.max, 0, 0, 0, 0, 0, 0, 0] { overflow.append(hdiffUInt(n)) }
        invalid.append(overflow)
        for patch in invalid {
            try fixture.store(old: Data([1, 2]), patch: patch)
            let output = try fixture.output(); defer { try? output.close() }
            await #expect(throws: LauncherError.malformedPatch) {
                try await HDiff13.apply(old: fixture.range("old", length: 2), patch: fixture.range("patch", length: Int64(patch.count)),
                    expectedSize: 3, output: output)
            }
        }
    }

    @Test func cancellationBeforeStartAndBetweenWrites() async throws {
        let fixture = try HDiffFixture(), expected = Data(repeating: 65, count: 250_000)
        let patch = hdiffPatch(oldSize: 0, newSize: UInt64(expected.count),
            control: hdiffUInt(UInt64(expected.count - 1), tagBits: 2), newData: expected)
        try fixture.store(old: Data(), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        let oldRange = try fixture.range("old", length: 0), patchRange = try fixture.range("patch", length: Int64(patch.count))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await HDiff13.apply(old: oldRange, patch: patchRange, expectedSize: Int64(expected.count), output: output)
        }
        await #expect(throws: LauncherError.cancelled) { try await cancelled.value }
        #expect(try fixture.readOutput().isEmpty)
        await #expect(throws: LauncherError.cancelled) {
            try await HDiff13.apply(old: oldRange, patch: patchRange, expectedSize: Int64(expected.count), output: output,
                onStep: { step in if step == .writeOutput { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        // Cancellation happens at the first write boundary, before those bytes are stored.
        #expect(try fixture.readOutput().isEmpty)
    }

    @Test func refusesAliasedOutputAndUnsafeInputs() async throws {
        let fixture = try HDiffFixture(), patch = hdiffPatch(oldSize: 1, newSize: 1, control: Data([0]), newData: Data([2]))
        try fixture.store(old: Data([1]), patch: patch)
        let alias = try fixture.fs.openForWriting(at: SafeRelativePath("old"), truncate: false)
        defer { try? alias.close() }
        await #expect(throws: LauncherError.io("HDiff requires distinct regular files")) {
            try await HDiff13.apply(old: fixture.range("old", length: 1), patch: fixture.range("patch", length: Int64(patch.count)),
                expectedSize: 1, output: alias)
        }
        #expect(try fixture.fs.readFile(at: SafeRelativePath("old"), maxBytes: 10) == Data([1]))
        let output = try fixture.output(); defer { try? output.close() }
        for offset in [Int64(-1), Int64.max] {
            await #expect(throws: LauncherError.io("Invalid HDiff range")) {
                try await HDiff13.apply(old: fixture.range("old", length: 1), patch: fixture.range("patch", offset: offset, length: 2),
                    expectedSize: 1, output: output)
            }
        }
    }
}

final class HDiffFixture {
    let temp: TempDir
    let fs: ContainedFileSystem
    init() throws { temp = try TempDir(); fs = try ContainedFileSystem(root: temp.url) }
    func store(old: Data, patch: Data) throws {
        try fs.writeAtomically(old, to: SafeRelativePath("old"))
        try fs.writeAtomically(patch, to: SafeRelativePath("patch"))
    }
    func output() throws -> FileHandle { try fs.openForWriting(at: SafeRelativePath("output"), truncate: true) }
    func readOutput() throws -> Data { try fs.readFile(at: SafeRelativePath("output"), maxBytes: 1 << 20) }
    func range(_ path: String, offset: Int64 = 0, length: Int64) throws -> HDiff13.FileRange {
        HDiff13.FileRange(fileSystem: fs, path: try SafeRelativePath(path), offset: offset, length: length)
    }
}

// Independent HDIFF13 wire writer, not protobuf: packed integers are big endian.
func hdiffUInt(_ value: UInt64, tagBits: Int = 0, tag: UInt8 = 0) -> Data {
    var rest = value, tail: [UInt8] = []
    while rest >= (1 << (7 - tagBits)) { tail.append(UInt8(rest & 127)); rest >>= 7 }
    var bytes = [UInt8(rest) | (tagBits == 0 ? 0 : tag << (8 - tagBits)) | (tail.isEmpty ? 0 : 1 << (7 - tagBits))]
    for (index, byte) in tail.reversed().enumerated() { bytes.append(byte | (index + 1 < tail.count ? 128 : 0)) }
    return Data(bytes)
}
func hdiffPatch(oldSize: UInt64, newSize: UInt64, compressor: String = "", covers: Data = Data(), coverCount: UInt64 = 0,
    control: Data = Data(), rle: Data = Data(), newData: Data = Data()) -> Data {
    var result = Data("HDIFF13&\(compressor)\0".utf8)
    for value in [newSize, oldSize, coverCount, UInt64(covers.count), 0, UInt64(control.count), 0, UInt64(rle.count), 0, UInt64(newData.count), 0] {
        result.append(hdiffUInt(value))
    }
    return result + covers + control + rle + newData
}
