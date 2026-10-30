// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia
import CoreVideo
import Testing
import LauncherCore
@testable import BackdropVideo

@Suite(.timeLimit(.minutes(1))) struct VP9DecoderTests {
    @Test(.enabled(if: VP9Decoder.isAvailable)) func hiddenKeyframeInSuperframeIsDecodedButNotDisplayed() async throws {
        try await BlockingIO.run {
            let original = try WebMDemuxer.load(from: #require(Bundle.module.url(forResource: "vp9-decode", withExtension: "webm", subdirectory: "Fixtures")))
            let key = try #require(original.samples.first).data
            var hidden = key; hidden[0] &= ~UInt8(2)
            let marker: UInt8 = 0xd9 // Two frames, four-byte little-endian sizes.
            let size = (0..<4).map { UInt8(truncatingIfNeeded: key.count >> ($0 * 8)) }
            let packet = hidden + key + Data([marker] + size + size + [marker])
            let cluster = ebml(0x1f43b675, ebml(0xe7, Data([0])) + ebml(0xa3, Data([0x81, 0, 0, 0x80]) + packet))
            let video = try WebMDemuxer.parse(container(frameBlocks: cluster, width: 128, height: 128))
            #expect(video.samples.count == 2)
            #expect(!video.samples[0].isDisplayed && video.samples[1].isDisplayed)
            let decoder = try VP9Decoder(video: video); defer { decoder.invalidate() }
            #expect(try decoder.decode(video.samples[0]) == nil)
            #expect(try decoder.decode(video.samples[1]) != nil)
            var broken = packet; broken[broken.count - 2] = 0xff
            #expect(throws: (any Error).self) { try VP9Configuration.frames(in: broken) }
        }
    }
    @Test(.enabled(if: VP9Decoder.isAvailable)) func fixtureActuallyDecodesTwentyDisplayedFrames() async throws {
        let video = try await BlockingIO.run { try WebMDemuxer.load(from: #require(Bundle.module.url(forResource: "vp9-decode", withExtension: "webm", subdirectory: "Fixtures"))) }
        let count = try await BlockingIO.run {
            let decoder = try VP9Decoder(video: video); defer { decoder.invalidate() }
            var count = 0
            for sample in video.samples {
                if let frame = try decoder.decode(sample) {
                    #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 128 && CVPixelBufferGetHeight(frame.pixelBuffer) == 128)
                    count += 1
                }
            }
            return count
        }
        #expect(count == 20)
    }
    @Test(.enabled(if: VP9Decoder.isAvailable && ProcessInfo.processInfo.environment["MACGACHA_BACKDROP_VIDEO"] != nil))
    func explicitlySelectedCachedVideoDecodesWithoutCopyingAsset() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MACGACHA_BACKDROP_VIDEO"])
        try await BlockingIO.run {
            let video = try WebMDemuxer.load(from: URL(fileURLWithPath: path)), decoder = try VP9Decoder(video: video)
            defer { decoder.invalidate() }
            var shown = 0
            for sample in video.samples { if try decoder.decode(sample) != nil { shown += 1 } }
            #expect(shown == video.samples.filter(\.isDisplayed).count)
            print("Backdrop proof: \(video.width)x\(video.height), \(video.samples.count) coded frames, \(shown) displayed frames, \(video.duration.seconds) s")
        }
    }
}
