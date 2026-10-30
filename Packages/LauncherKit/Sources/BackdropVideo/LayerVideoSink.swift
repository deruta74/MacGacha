// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import AVFoundation
import CoreMedia

@MainActor package protocol BackdropVideoSink: AnyObject {
    var isDisplayable: Bool { get }
    var onReady: (@MainActor @Sendable () -> Void)? { get set }
    func prepare() async
    func enqueue(_ frame: BackdropFrame) async throws
    func setPlaying(_ playing: Bool)
    func flush()
}

/// The macOS 27 receiver is the nondeprecated replacement for
/// requestMediaDataWhenReady: enqueue suspends until the renderer requests data.
@MainActor final class LayerVideoSink: BackdropVideoSink {
    let layer: AVSampleBufferDisplayLayer
    let synchronizer: AVSampleBufferRenderSynchronizer
    let receiver: AVSampleBufferVideoRenderer.Receiver
    var onReady: (@MainActor @Sendable () -> Void)?
    private var observer: (any NSObjectProtocol)?
    var isDisplayable: Bool { layer.isReadyForDisplay }
    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        self.synchronizer = synchronizer
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        synchronizer.setRate(0, time: .zero)
        observer = NotificationCenter.default.addObserver(forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: layer, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onReady?() }
        }
    }
    func prepare() async { await receiver.flush(removingDisplayedImage: true) }
    func enqueue(_ frame: BackdropFrame) async throws {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer, formatDescriptionOut: &format) == noErr,
            let format else { throw WebMDemuxer.invalid() }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: frame.presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw WebMDemuxer.invalid() }
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        switch try await receiver.enqueue(ready) {
        case .enqueued: break
        case .cancelledDueToFlush: throw CancellationError()
        case .enqueuedWithDecodeFailures, .cancelledDueToFlushRequiredToResume, .cancelledDueToError: throw WebMDemuxer.invalid()
        @unknown default: throw WebMDemuxer.invalid()
        }
    }
    func setPlaying(_ playing: Bool) { synchronizer.setRate(playing ? 1 : 0, time: .invalid) }
    func flush() { receiver.flush(); synchronizer.setRate(0, time: .zero) }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        receiver.flush()
    }
}
