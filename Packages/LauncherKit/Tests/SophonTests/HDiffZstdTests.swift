// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import Sophon

@Suite(.timeLimit(.minutes(1))) struct HDiffZstdTests {
    @Test(arguments: [[0], [1], [2], [3], [0, 1, 2, 3]])
    func compressedAndMixedSections(sections: [Int]) async throws {
        let fixture = try HDiffFixture()
        let decoded = [Data([0, 0, 2, 2, 2, 4]), Data([0xc8]), Data([0, 1, 0, 0, 0, 0, 0, 0, 0]), Data("XY!".utf8)]
        let encoded = decoded.enumerated().map { sections.contains($0.offset) ? hdiffZstdFrame($0.element) : nil }
        let patch = hdiffEncodedPatch(oldSize: 10, newSize: 9, coverCount: 2, decoded: decoded, encoded: encoded)
        try fixture.store(old: Data("abcdefghij".utf8), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        try await HDiff13.apply(old: fixture.range("old", length: 10), patch: fixture.range("patch", length: Int64(patch.count)),
            expectedSize: 9, output: output)
        #expect(try fixture.readOutput() == Data("acXYefgh!".utf8))
    }

    @Test func rleZstdBlockExpandsAcrossManyOutputSteps() async throws {
        let fixture = try HDiffFixture(), expected = Data(repeating: 65, count: 250_000)
        let control = hdiffUInt(UInt64(expected.count - 1), tagBits: 2)
        let decoded = [Data(), control, Data(), expected]
        let encoded = decoded.enumerated().map { hdiffZstdFrame($0.element, rle: $0.offset == 3) as Data? }
        let patch = hdiffEncodedPatch(oldSize: 0, newSize: UInt64(expected.count), coverCount: 0, decoded: decoded, encoded: encoded)
        #expect(patch.count < 100)
        try fixture.store(old: Data(), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        try await HDiff13.apply(old: fixture.range("old", length: 0), patch: fixture.range("patch", length: Int64(patch.count)),
            expectedSize: Int64(expected.count), output: output)
        #expect(try fixture.readOutput() == expected)
    }

    @Test func rejectsTruncatedTrailingAndWrongSizeZstdFrames() async throws {
        let fixture = try HDiffFixture()
        let content = Data([1, 2, 3]), frame = hdiffZstdFrame(Data([1, 2, 3]))
        let badFrames = [Data(frame.dropLast()), frame + hdiffZstdFrame(Data()), hdiffZstdFrame(Data([1, 2])), hdiffZstdFrame(Data([1, 2, 3, 4]))]
        for bad in badFrames {
            let patch = hdiffEncodedPatch(oldSize: 0, newSize: 3, coverCount: 0,
                decoded: [Data(), Data([2]), Data(), content], encoded: [nil, nil, nil, bad])
            try fixture.store(old: Data(), patch: patch)
            let output = try fixture.output(); defer { try? output.close() }
            await #expect(throws: LauncherError.malformedPatch) {
                try await HDiff13.apply(old: fixture.range("old", length: 0), patch: fixture.range("patch", length: Int64(patch.count)),
                    expectedSize: 3, output: output)
            }
        }
    }

    @Test func cancellationClosesZstdStreamsAndAllowsAnotherApply() async throws {
        let fixture = try HDiffFixture(), expected = Data(repeating: 65, count: 250_000)
        let decoded = [Data(), hdiffUInt(UInt64(expected.count - 1), tagBits: 2), Data(), expected]
        let encoded = decoded.enumerated().map { hdiffZstdFrame($0.element, rle: $0.offset == 3) as Data? }
        let patch = hdiffEncodedPatch(oldSize: 0, newSize: UInt64(expected.count), coverCount: 0, decoded: decoded, encoded: encoded)
        try fixture.store(old: Data(), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        let source = try fixture.range("old", length: 0), slice = try fixture.range("patch", length: Int64(patch.count))
        let cancelled = Task {
            try await HDiff13.apply(old: source, patch: slice, expectedSize: Int64(expected.count), output: output,
                onStep: { step in if step == .writeOutput { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        await #expect(throws: LauncherError.cancelled) { try await cancelled.value }
        #expect(!Task.isCancelled)
        #expect(try fixture.readOutput().isEmpty)
        try await HDiff13.apply(old: source, patch: slice, expectedSize: Int64(expected.count), output: output)
        #expect(try fixture.readOutput() == expected)
    }

    @Test func boundsZstdWindowBeforeLargeAllocation() async throws {
        let fixture = try HDiffFixture()
        // Non-single-segment frame, windowLog=27 (128 MiB), one last raw byte.
        let frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0, 0x88, 9, 0, 0, 65])
        let patch = hdiffEncodedPatch(oldSize: 0, newSize: 1, coverCount: 0,
            decoded: [Data(), Data([0]), Data(), Data([65])], encoded: [nil, nil, nil, frame])
        try fixture.store(old: Data(), patch: patch)
        let output = try fixture.output(); defer { try? output.close() }
        await #expect(throws: LauncherError.io("HDiff decoder memory limit")) {
            try await HDiff13.apply(old: fixture.range("old", length: 0), patch: fixture.range("patch", length: Int64(patch.count)),
                expectedSize: 1, output: output)
        }
    }
}

func hdiffEncodedPatch(oldSize: UInt64, newSize: UInt64, coverCount: UInt64, decoded: [Data], encoded: [Data?]) -> Data {
    var result = Data("HDIFF13&zstd\0".utf8)
    for n in [newSize, oldSize, coverCount] { result.append(hdiffUInt(n)) }
    for i in 0..<4 { result.append(hdiffUInt(UInt64(decoded[i].count))); result.append(hdiffUInt(UInt64(encoded[i]?.count ?? 0))) }
    for i in 0..<4 { result.append(encoded[i] ?? decoded[i]) }
    return result
}

// Zstandard public frame format: single segment, raw or RLE blocks, no encoder dependency.
func hdiffZstdFrame(_ data: Data, rle: Bool = false) -> Data {
    var frame = Data([0x28, 0xb5, 0x2f, 0xfd])
    if data.count < 256 { frame.append(contentsOf: [0x20, UInt8(data.count)]) }
    else if data.count < 65_792 {
        let n = data.count - 256; frame.append(contentsOf: [0x60, UInt8(n & 255), UInt8(n >> 8)])
    } else {
        frame.append(0xa0)
        for shift in [0, 8, 16, 24] { frame.append(UInt8((data.count >> shift) & 255)) }
    }
    var offset = 0
    repeat {
        let size = min(128 << 10, data.count - offset), last = offset + size == data.count
        let header = (size << 3) | (rle ? 2 : 0) | (last ? 1 : 0)
        frame.append(contentsOf: [UInt8(header & 255), UInt8((header >> 8) & 255), UInt8(header >> 16)])
        if rle && size > 0 { frame.append(data[offset]) }
        else { frame.append(data[offset..<(offset + size)]) }
        offset += size
    } while offset < data.count
    return frame
}
