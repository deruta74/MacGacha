// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia

public struct VP9Configuration: Sendable {
    public let profile: UInt8 = 0
    public private(set) var level: UInt8 = 10
    public let bitDepth: UInt8 = 8
    public let chromaSubsampling: UInt8 = 1
    public let fullRange: Bool
    public let colorPrimaries: UInt8
    public let transferCharacteristics: UInt8
    public let matrixCoefficients: UInt8
    /// ISO VP Codec Configuration Box: FullBox version/flags, then VPCodecConfigurationRecord.
    public var atom: Data { Data([1, 0, 0, 0, profile, level, bitDepth << 4 | chromaSubsampling << 1 | (fullRange ? 1 : 0), colorPrimaries, transferCharacteristics, matrixCoefficients, 0, 0]) }
    mutating func apply(codecPrivate: [UInt8], width: Int, height: Int, frameInterval: CMTime) throws {
        var declaredLevel: UInt8?, offset = 0
        while offset < codecPrivate.count {
            guard codecPrivate.count - offset >= 2 else { throw WebMDemuxer.invalid() }
            let id = codecPrivate[offset], size = Int(codecPrivate[offset + 1]); offset += 2
            guard size <= codecPrivate.count - offset else { throw WebMDemuxer.invalid() }
            if [1, 2, 3, 4].contains(id) {
                guard size == 1 else { throw WebMDemuxer.invalid() }
                let value = codecPrivate[offset]
                switch id {
                case 1: guard value == 0 else { throw WebMDemuxer.invalid() }
                case 2: declaredLevel = value
                case 3: guard value == 8 else { throw WebMDemuxer.invalid() }
                case 4: guard value <= 1 else { throw WebMDemuxer.invalid() }
                default: break
                }
            }
            offset += size
        }
        // VP9 bitstreams carry no level. Infer the lowest fitting level when WebM omits it.
        let limits: [(UInt8, Double, Int)] = [(10, 829440, 36864), (11, 2764800, 73728), (20, 4608000, 122880),
            (21, 9216000, 245760), (30, 20736000, 552960), (31, 36864000, 983040), (40, 83558400, 2228224),
            (41, 160432128, 2228224), (50, 311951360, 8912896), (51, 588251136, 8912896), (52, 1176502272, 8912896)]
        let pixels = width * height, rate = Double(pixels) / frameInterval.seconds
        guard let inferred = limits.first(where: { pixels <= $0.2 && rate <= $0.1 })?.0 else { throw WebMDemuxer.invalid() }
        if let declaredLevel { guard limits.contains(where: { $0.0 == declaredLevel }), declaredLevel >= inferred else { throw WebMDemuxer.invalid() }; level = declaredLevel }
        else { level = inferred }
    }
    static func header(_ data: Data, width: Int, height: Int) throws -> (keyframe: Bool, displayed: Bool, configuration: VP9Configuration?) {
        var bits = Bits(bytes: Array(data))
        guard try bits.read(2) == 2 else { throw WebMDemuxer.invalid() }
        let profile = try bits.read(1) | bits.read(1) << 1
        guard profile == 0 else { throw WebMDemuxer.invalid() }
        if try bits.read(1) == 1 { _ = try bits.read(3); return (false, true, nil) }
        let key = try bits.read(1) == 0, shown = try bits.read(1) == 1
        _ = try bits.read(1)
        guard key else { return (false, shown, nil) }
        guard try bits.read(24) == 0x498342 else { throw WebMDemuxer.invalid() }
        let color = try bits.read(3), full = try bits.read(1) == 1
        guard color != 7, try bits.read(16) + 1 == width, try bits.read(16) + 1 == height else { throw WebMDemuxer.invalid() }
        let code: UInt8 = color == 2 ? 1 : [1, 3].contains(color) ? 6 : 2
        return (true, shown, VP9Configuration(fullRange: full, colorPrimaries: code, transferCharacteristics: code, matrixCoefficients: code))
    }
    static func frames(in packet: Data) throws -> [Data] {
        guard let marker = packet.last else { throw WebMDemuxer.invalid() }
        guard marker & 0xe0 == 0xc0 else { return [packet] }
        let count = Int(marker & 7) + 1, width = Int(marker >> 3 & 3) + 1, length = 2 + count * width
        guard packet.count >= length, packet[packet.count - length] == marker else { throw WebMDemuxer.invalid() }
        var offset = 0, frames: [Data] = []
        for i in 0..<count {
            var size = 0
            for j in 0..<width { size |= Int(packet[packet.count - length + 1 + i * width + j]) << (j * 8) }
            guard size > 0, size <= packet.count - length - offset else { throw WebMDemuxer.invalid() }
            frames.append(packet.subdata(in: offset..<(offset + size))); offset += size
        }
        guard offset == packet.count - length else { throw WebMDemuxer.invalid() }
        return frames
    }
}
private struct Bits {
    let bytes: [UInt8]
    var index = 0
    mutating func read(_ count: Int) throws -> Int {
        guard count <= bytes.count * 8 - index else { throw WebMDemuxer.invalid() }
        var value = 0
        for _ in 0..<count { value = value << 1 | Int(bytes[index / 8] >> (7 - index % 8) & 1); index += 1 }
        return value
    }
}
