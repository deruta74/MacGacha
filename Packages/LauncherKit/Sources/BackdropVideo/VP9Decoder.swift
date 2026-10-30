// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Synchronization
import LauncherCore

/// Immutable decoded surfaces can cross queues. No caller may write their pixels.
public struct BackdropFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) { self.pixelBuffer = pixelBuffer; self.presentationTime = presentationTime }
}

/// Confine each decoder to a dedicated serial queue, or BlockingIO for proof tests.
public final class VP9Decoder {
    private var session: VTDecompressionSession?
    private let format: CMVideoFormatDescription
    /// Capability gate for hardware-backed proof tests; session creation remains authoritative.
    public static var isAvailable: Bool {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
    }
    public init(video: WebMVideo) throws {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        var description: CMVideoFormatDescription?
        let extensions: [String: Any] = [kCMFormatDescriptionExtension_BitsPerComponent as String: video.configuration.bitDepth, kCMFormatDescriptionExtension_Depth as String: 24, kCMFormatDescriptionExtension_FormatName as String: "vp09", kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["vpcC": video.configuration.atom]]
        try Self.check(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9,
            width: Int32(video.width), height: Int32(video.height), extensions: extensions as CFDictionary, formatDescriptionOut: &description))
        guard let description else { throw WebMDemuxer.invalid() }
        format = description
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        try Self.check(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true] as CFDictionary, imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session))
    }
    public func decode(_ sample: WebMSample) throws -> BackdropFrame? {
        guard let session else { throw WebMDemuxer.invalid() }
        var block: CMBlockBuffer?
        try Self.check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: sample.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sample.data.count, flags: 0, blockBufferOut: &block))
        guard let block else { throw WebMDemuxer.invalid() }
        try sample.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw WebMDemuxer.invalid() }
            try Self.check(CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count))
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: sample.presentationTime, decodeTimeStamp: .invalid)
        var size = sample.data.count, buffer: CMSampleBuffer?
        try Self.check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer))
        guard let buffer else { throw WebMDemuxer.invalid() }
        let output = Mutex<(OSStatus, BackdropFrame?)>((noErr, nil))
        try Self.check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { status, _, image, pts, _ in
            output.withLock { $0 = (status, image.map { BackdropFrame(pixelBuffer: $0, presentationTime: pts) }) }
        })
        try Self.check(VTDecompressionSessionWaitForAsynchronousFrames(session))
        let result = output.withLock { $0 }
        try Self.check(result.0)
        guard sample.isDisplayed else { return nil }
        guard let frame = result.1 else { throw WebMDemuxer.invalid() }
        return frame
    }
    public func invalidate() { if let session { VTDecompressionSessionInvalidate(session) }; session = nil }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw LauncherError.io("Backdrop decoder failed (status \(status))") }
    }
}
