// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia
import Testing
import LauncherCore
@testable import BackdropVideo

func tinyVideoURL() throws -> URL { try #require(Bundle.module.url(forResource: "vp9-tiny", withExtension: "webm", subdirectory: "Fixtures")) }
func tinyVideo() async throws -> WebMVideo { try await BlockingIO.run { try WebMDemuxer.load(from: tinyVideoURL()) } }

@Suite struct WebMTests {
    @Test func fixtureSkipsOpusAndKeepsContainerTimestamps() async throws {
        let video = try await tinyVideo()
        #expect(video.width == 64 && video.height == 48)
        #expect(video.samples.filter(\.isDisplayed).count == 20)
        #expect(video.samples.count >= 20)
        #expect(video.samples.first?.isKeyframe == true)
        #expect(abs(video.samples[0].presentationTime.seconds - 0.0) < 0.000001)
        #expect(abs(video.duration.seconds - 2) < 0.001)
    }
    @Test func malformedBoundsAndTruncationAreRefused() async throws {
        let bytes = try await BlockingIO.run {
            let url = try tinyVideoURL()
            return try ContainedFileSystem(root: url.deletingLastPathComponent()).readFile(at: SafeRelativePath(url.lastPathComponent), maxBytes: 64 << 20)
        }
        for cut in [0, 1, 4, 40, bytes.count / 2, bytes.count - 1] {
            #expect(throws: (any Error).self) { try WebMDemuxer.parse(Data(bytes.prefix(cut))) }
        }
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(Data([0x1a, 0x45, 0xdf, 0xa3, 0x01] + [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])) }
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(Data(repeating: 0, count: WebMDemuxer.maximumFileBytes + 1)) }
    }
    @Test func blockGroupAndUnknownClustersRespectScaleAndSignedOffsets() async throws {
        let frame = try #require(try await tinyVideo().samples.first).data
        let block = Data([0x81, 0xff, 0xfb, 0]) + frame
        let group = ebml(0xa0, ebml(0xa1, block))
        let first = Data([0x1f, 0x43, 0xb6, 0x75, 0xff]) + ebml(0xe7, Data([100])) + group
        let second = ebml(0x1f43b675, ebml(0xe7, Data([200])) + ebml(0xa3, Data([0x81, 0, 0, 0x80]) + frame))
        let video = try WebMDemuxer.parse(container(frameBlocks: first + second, scale: 2_000_000))
        #expect(video.samples.count == 2)
        #expect(abs(video.samples[0].presentationTime.seconds - 0.190) < 0.000001)
        #expect(abs(video.samples[1].presentationTime.seconds - 0.4) < 0.000001)
        #expect(video.samples.allSatisfy { $0.isKeyframe })
    }
    @Test func videoLacingOtherCodecsAndMultipleVideoTracksAreRefused() async throws {
        let frame = try #require(try await tinyVideo().samples.first).data
        let laced = ebml(0x1f43b675, ebml(0xe7, Data([0])) + ebml(0xa3, Data([0x81, 0, 0, 0x82]) + frame))
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(container(frameBlocks: laced)) }
        let cluster = ebml(0x1f43b675, ebml(0xe7, Data([0])) + ebml(0xa3, Data([0x81, 0, 0, 0x80]) + frame))
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(container(frameBlocks: cluster, codec: "V_AV1")) }
        #expect(throws: (any Error).self) { try WebMDemuxer.parse(container(frameBlocks: cluster, duplicate: true)) }
        let audio = ebml(0xa3, Data([0x82, 0, 0, 0x86, 0xff]))
        let good = try WebMDemuxer.parse(container(frameBlocks: ebml(0x1f43b675, ebml(0xe7, Data([0])) + audio + ebml(0xa3, Data([0x81, 0, 0, 0x80]) + frame))))
        #expect(good.samples.count == 1)
    }
}

func ebml(_ id: UInt32, _ payload: Data) -> Data {
    let count = id > 0xffffff ? 4 : id > 0xffff ? 3 : id > 0xff ? 2 : 1
    let identifier = (0..<count).reversed().map { UInt8(truncatingIfNeeded: id >> ($0 * 8)) }
    let size = payload.count
    let length: [UInt8] = size < 127 ? [UInt8(size) | 0x80] : [UInt8(size >> 8) | 0x40, UInt8(truncatingIfNeeded: size)]
    return Data(identifier + length) + payload
}
func container(frameBlocks: Data, scale: UInt32 = 1_000_000, codec: String = "V_VP9", duplicate: Bool = false, width: UInt8 = 64, height: UInt8 = 48) -> Data {
    let header = ebml(0x1a45dfa3, ebml(0x4282, Data("webm".utf8)))
    let info = ebml(0x1549a966, ebml(0x2ad7b1, Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: scale >> ($0 * 8)) })))
    let entry = ebml(0xae, ebml(0xd7, Data([1])) + ebml(0x83, Data([1])) + ebml(0x86, Data(codec.utf8))
        + ebml(0x23e383, Data([0x05, 0xf5, 0xe1, 0])) + ebml(0xe0, ebml(0xb0, Data([width])) + ebml(0xba, Data([height]))))
    let audio = ebml(0xae, ebml(0xd7, Data([2])) + ebml(0x83, Data([2])) + ebml(0x86, Data("A_OPUS".utf8)))
    return header + Data([0x18, 0x53, 0x80, 0x67, 0xff]) + info + ebml(0x1654ae6b, entry + (duplicate ? entry : Data()) + audio) + frameBlocks
}
