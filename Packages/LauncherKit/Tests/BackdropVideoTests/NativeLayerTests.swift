// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import AVFoundation
import Testing
@testable import BackdropVideo

extension HardwareVP9Tests {
    @Suite(.timeLimit(.minutes(1))) struct NativeLayerTests {
        @Test(.enabled(if: VP9Decoder.isAvailable)) func nativeDecodeLoopsWithBoundedSurfacePrefetch() async throws {
            let url = try #require(Bundle.module.url(forResource: "vp9-decode", withExtension: "webm", subdirectory: "Fixtures"))
            let source = VideoFrameSource(url: url)
            var previous = -1.0
            for _ in 0..<100 {
                let frame = try #require(try await source.next())
                #expect(frame.presentationTime.seconds > previous)
                previous = frame.presentationTime.seconds
            }
            source.stop(); await source.drain()
            #expect(source.queueMetrics.peak <= VideoFrameSource.capacity && source.queueMetrics.queued == 0)
        }
        @Test(.enabled(if: VP9Decoder.isAvailable && ProcessInfo.processInfo.environment["MACGACHA_BACKDROP_VIDEO"] != nil))
        @MainActor func explicitlySelectedVideoReachesNativeLayerReadiness() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["MACGACHA_BACKDROP_VIDEO"])
            let events = AsyncStream<BackdropVideoState?>.makeStream()
            let layer = AVSampleBufferDisplayLayer()
            let player = BackdropVideoPlayer(layer: layer) { _, state in events.continuation.yield(state) }
            let deadline = Task {
                do { try await ContinuousClock().sleep(for: .seconds(10)); events.continuation.yield(nil) }
                catch {}
            }
            defer { deadline.cancel(); player.stop() }
            player.play(URL(fileURLWithPath: path))
            for await state in events.stream {
                guard let state else { Issue.record("Native display readiness deadline exceeded"); return }
                if state == .failed { Issue.record("Native player failed before display readiness"); return }
                if state == .playing {
                    #expect(layer.isReadyForDisplay)
                    print("Native layer proof: first decoded frame enqueued and ready for display")
                    return
                }
            }
        }
    }
}
