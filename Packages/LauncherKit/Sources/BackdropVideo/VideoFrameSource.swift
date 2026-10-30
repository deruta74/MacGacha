// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Dispatch
import CoreMedia
import Synchronization
import LauncherCore

package protocol BackdropFrameSource: Sendable {
    /// Nil means paused, not end-of-stream. Sources loop until stopped.
    func next() async throws -> BackdropFrame?
    func setPaused(_ value: Bool)
    func stop()
}
package protocol BackdropDecoding: AnyObject {
    func decode(_ sample: WebMSample) throws -> BackdropFrame?
    func invalidate()
}
extension VP9Decoder: BackdropDecoding {}

/// All codec and file work is serialized, even across rapid source replacement.
/// Only control flags and metrics cross that queue. Surfaces are immutable.
package final class VideoFrameSource: BackdropFrameSource, Sendable {
    package static let capacity = 4
    private static let queue = DispatchQueue(label: "com.lo7ted.macgacha.backdrop-decoder", qos: .userInitiated)
    private struct Control { var paused = false; var stopped = false }
    private let control = Mutex(Control())
    private let metrics = Mutex((queued: 0, peak: 0))
    private let state: QueueState
    private final class QueueState: @unchecked Sendable {
        let url: URL
        let load: @Sendable (URL) throws -> WebMVideo
        let makeDecoder: @Sendable (WebMVideo) throws -> any BackdropDecoding
        var video: WebMVideo?
        var decoder: (any BackdropDecoding)?
        var frames: [BackdropFrame] = []
        var index = 0
        var offset: CMTime = .zero
        init(url: URL, load: @escaping @Sendable (URL) throws -> WebMVideo,
            makeDecoder: @escaping @Sendable (WebMVideo) throws -> any BackdropDecoding) {
            self.url = url; self.load = load; self.makeDecoder = makeDecoder
        }
        func clear() { decoder?.invalidate(); decoder = nil; video = nil; frames.removeAll() }
    }
    package init(url: URL, load: @escaping @Sendable (URL) throws -> WebMVideo = WebMDemuxer.load,
        makeDecoder: @escaping @Sendable (WebMVideo) throws -> any BackdropDecoding = { try VP9Decoder(video: $0) }) {
        state = QueueState(url: url, load: load, makeDecoder: makeDecoder)
    }
    package var queueMetrics: (queued: Int, peak: Int) { metrics.withLock { $0 } }
    package func setPaused(_ value: Bool) { control.withLock { $0.paused = value } }
    package func stop() {
        control.withLock { $0.stopped = true }
        Self.queue.async { [self] in state.clear(); metrics.withLock { $0.queued = 0 } }
    }
    package func drain() async { await withCheckedContinuation { c in Self.queue.async { c.resume() } } }
    package func next() async throws -> BackdropFrame? {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [self] in
                do {
                    guard !control.withLock({ $0.stopped }) else { throw LauncherError.cancelled }
                    guard !control.withLock({ $0.paused }) else { continuation.resume(returning: nil); return }
                    if state.video == nil { state.video = try state.load(state.url) }
                    guard let video = state.video else { throw WebMDemuxer.invalid() }
                    guard !control.withLock({ $0.stopped }) else { throw LauncherError.cancelled }
                    guard !control.withLock({ $0.paused }) else { continuation.resume(returning: nil); return }
                    if state.decoder == nil { state.decoder = try state.makeDecoder(video) }
                    guard let start = video.samples.first(where: \.isDisplayed)?.presentationTime else { throw WebMDemuxer.invalid() }
                    while state.frames.count < Self.capacity && !control.withLock({ $0.paused || $0.stopped }) {
                        if state.index == video.samples.count {
                            state.index = 0; state.offset = CMTimeAdd(state.offset, video.duration)
                            guard state.offset.isNumeric else { throw WebMDemuxer.invalid() }
                        }
                        let original = video.samples[state.index]; state.index += 1
                        let pts = CMTimeAdd(CMTimeSubtract(original.presentationTime, start), state.offset)
                        let sample = WebMSample(data: original.data, presentationTime: pts, isKeyframe: original.isKeyframe, isDisplayed: original.isDisplayed)
                        if let frame = try state.decoder?.decode(sample) {
                            state.frames.append(BackdropFrame(pixelBuffer: frame.pixelBuffer, presentationTime: pts))
                            metrics.withLock { $0.queued = state.frames.count; $0.peak = max($0.peak, $0.queued) }
                        }
                    }
                    guard !control.withLock({ $0.stopped }) else { throw LauncherError.cancelled }
                    guard !control.withLock({ $0.paused }), !state.frames.isEmpty else { continuation.resume(returning: nil); return }
                    let frame = state.frames.removeFirst(); metrics.withLock { $0.queued = state.frames.count }
                    continuation.resume(returning: frame)
                } catch { state.clear(); metrics.withLock { $0.queued = 0 }; continuation.resume(throwing: error) }
            }
        }
    }
    deinit {
        let state = state
        Self.queue.async { state.clear() }
    }
}
