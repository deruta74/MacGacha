// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreMedia
import LauncherCore

public struct WebMSample: Sendable {
    public let data: Data
    public let presentationTime: CMTime
    public let isKeyframe: Bool
    public let isDisplayed: Bool
}
public struct WebMVideo: Sendable {
    public let width: Int
    public let height: Int
    public let samples: [WebMSample]
    public let duration: CMTime
    public let configuration: VP9Configuration
}
public enum WebMDemuxer {
    public static let maximumFileBytes = 64 << 20
    public static let maximumSampleBytes = 8 << 20
    /// Synchronous bounded I/O. Call on BlockingIO or the player's decoding queue.
    public static func load(from url: URL) throws -> WebMVideo {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw invalid() }
        let fs = try ContainedFileSystem(root: url.deletingLastPathComponent()).pinRoot()
        return try parse(fs.readFile(at: SafeRelativePath(url.lastPathComponent), maxBytes: maximumFileBytes))
    }
    public static func parse(_ data: Data) throws -> WebMVideo {
        guard data.count <= maximumFileBytes else { throw invalid() }
        var parser = WebMParser(bytes: Array(data))
        return try parser.parse()
    }
    static func invalid() -> LauncherError { .io("Unsupported or malformed backdrop video") }
}

private struct WebMParser {
    struct Element { let id: UInt64; let body: Int; let end: Int; let unknown: Bool }
    struct Track { var number: UInt64 = 0; var type: UInt64 = 0; var codec = ""; var width = 0; var height = 0; var duration: Int64?; var codecPrivate: [UInt8] = [] }
    struct Block { let range: Range<Int>; let ticks: Int64; let key: Bool }
    let bytes: [UInt8]
    var elements = 0
    var tracks: [Track] = []
    var blocks: [Block] = []
    var scale: Int64 = 1_000_000
    let segmentChildren: Set<UInt64> = [0x114d9b74, 0x1549a966, 0x1654ae6b, 0x1f43b675, 0x1c53bb6b, 0x1941a469, 0x1043a770, 0x1254c367]
    mutating func element(_ offset: Int, limit: Int, allowUnknownMaster: Bool = false) throws -> Element {
        elements += 1
        guard elements <= 100_000 else { throw WebMDemuxer.invalid() }
        var cursor = offset
        let id = try vint(&cursor, limit: limit, identifier: true)
        let size = try vint(&cursor, limit: limit)
        let unknown = size.value == (UInt64(1) << (7 * size.width)) - 1
        guard !unknown || (allowUnknownMaster && (id.value == 0x18538067 || id.value == 0x1f43b675)) else { throw WebMDemuxer.invalid() }
        guard unknown || size.value <= UInt64(limit - cursor) else { throw WebMDemuxer.invalid() }
        return Element(id: id.value, body: cursor, end: unknown ? limit : cursor + Int(size.value), unknown: unknown)
    }
    func vint(_ cursor: inout Int, limit: Int, identifier: Bool = false) throws -> (value: UInt64, width: Int) {
        guard cursor < limit, let width = (1...(identifier ? 4 : 8)).first(where: { bytes[cursor] & (0x80 >> ($0 - 1)) != 0 }), width <= limit - cursor else { throw WebMDemuxer.invalid() }
        var value = UInt64(identifier ? bytes[cursor] : bytes[cursor] & (0xff >> width))
        for i in 1..<width { value = value << 8 | UInt64(bytes[cursor + i]) }
        cursor += width
        return (value, width)
    }
    func uint(_ e: Element) throws -> UInt64 {
        guard !e.unknown, (1...8).contains(e.end - e.body) else { throw WebMDemuxer.invalid() }
        return bytes[e.body..<e.end].reduce(0) { $0 << 8 | UInt64($1) }
    }
    mutating func parse() throws -> WebMVideo {
        let header = try element(0, limit: bytes.count)
        guard header.id == 0x1a45dfa3, header.end <= 4096 else { throw WebMDemuxer.invalid() }
        var offset = header.body, webm = false
        while offset < header.end {
            let e = try element(offset, limit: header.end)
            if e.id == 0x4282 { webm = Array(bytes[e.body..<e.end]) == Array("webm".utf8) }
            offset = e.end
        }
        guard webm else { throw WebMDemuxer.invalid() }
        let segment = try element(header.end, limit: bytes.count, allowUnknownMaster: true)
        guard segment.id == 0x18538067, segment.end == bytes.count else { throw WebMDemuxer.invalid() }
        offset = segment.body
        while offset < segment.end {
            let e = try element(offset, limit: segment.end, allowUnknownMaster: true)
            guard e.id != 0x18538067 else { throw WebMDemuxer.invalid() }
            switch e.id {
            case 0x1549a966: try info(e)
            case 0x1654ae6b: try trackList(e)
            case 0x1f43b675: offset = try cluster(e); continue
            default: break
            }
            offset = e.end
        }
        let videos = tracks.filter { $0.type == 1 }
        guard videos.count == 1, let track = videos.first, track.codec == "V_VP9", track.number > 0,
            track.width > 0, track.height > 0, track.width <= 4096, track.height <= 4096,
            track.width * track.height <= 8_294_400,
            Set(tracks.map(\.number)).count == tracks.count else { throw WebMDemuxer.invalid() }
        var samples: [WebMSample] = [], configuration: VP9Configuration?
        for block in blocks {
            var cursor = block.range.lowerBound
            let number = try vint(&cursor, limit: block.range.upperBound).value
            guard number == track.number else { continue }
            guard block.range.upperBound - cursor >= 3 else { throw WebMDemuxer.invalid() }
            let relative = Int64(Int16(bitPattern: UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])))
            let flags = bytes[cursor + 2]; cursor += 3
            guard flags & 0x06 == 0, block.range.upperBound - cursor <= WebMDemuxer.maximumSampleBytes else { throw WebMDemuxer.invalid() }
            let (ticks, overflow) = block.ticks.addingReportingOverflow(relative)
            let (ns, timeOverflow) = ticks.multipliedReportingOverflow(by: scale)
            guard !overflow, !timeOverflow, ns >= 0, ns <= 120_000_000_000 else { throw WebMDemuxer.invalid() }
            for frame in try VP9Configuration.frames(in: Data(bytes[cursor..<block.range.upperBound])) {
                let header = try VP9Configuration.header(frame, width: track.width, height: track.height)
                if let config = header.configuration { configuration = configuration ?? config }
                samples.append(WebMSample(data: frame, presentationTime: CMTime(value: ns, timescale: 1_000_000_000),
                    isKeyframe: header.keyframe, isDisplayed: header.displayed && flags & 0x08 == 0))
                guard samples.count <= 36_000 else { throw WebMDemuxer.invalid() }
            }
        }
        guard let first = samples.first, first.isKeyframe, var config = configuration else { throw WebMDemuxer.invalid() }
        let shown = samples.filter(\.isDisplayed).map(\.presentationTime)
        guard let start = shown.first, let end = shown.last else { throw WebMDemuxer.invalid() }
        var smallest: CMTime?
        for pair in zip(shown, shown.dropFirst()) {
            let delta = CMTimeSubtract(pair.1, pair.0)
            guard delta.seconds > 0 else { throw WebMDemuxer.invalid() }
            if smallest == nil || delta.seconds < smallest!.seconds { smallest = delta }
        }
        let step = track.duration.map { CMTime(value: $0, timescale: 1_000_000_000) } ?? smallest
        guard let step, step.seconds > 0, step.seconds <= 10 else { throw WebMDemuxer.invalid() }
        let duration = CMTimeAdd(CMTimeSubtract(end, start), step)
        guard duration.seconds > 0, duration.seconds <= 120 else { throw WebMDemuxer.invalid() }
        try config.apply(codecPrivate: track.codecPrivate, width: track.width, height: track.height, frameInterval: smallest ?? step)
        return WebMVideo(width: track.width, height: track.height, samples: samples, duration: duration, configuration: config)
    }
    mutating func info(_ parent: Element) throws {
        var offset = parent.body
        while offset < parent.end {
            let e = try element(offset, limit: parent.end)
            if e.id == 0x2ad7b1 {
                let value = try uint(e)
                guard value > 0, value <= 1_000_000_000 else { throw WebMDemuxer.invalid() }
                scale = Int64(value)
            }
            offset = e.end
        }
    }
    mutating func trackList(_ parent: Element) throws {
        var offset = parent.body
        while offset < parent.end {
            let e = try element(offset, limit: parent.end)
            if e.id == 0xae { tracks.append(try track(e)); guard tracks.count <= 32 else { throw WebMDemuxer.invalid() } }
            offset = e.end
        }
    }
    mutating func track(_ parent: Element) throws -> Track {
        var result = Track(), offset = parent.body
        while offset < parent.end {
            let e = try element(offset, limit: parent.end)
            switch e.id {
            case 0xd7: result.number = try uint(e)
            case 0x83: result.type = try uint(e)
            case 0x86: guard e.end - e.body <= 64 else { throw WebMDemuxer.invalid() }; result.codec = String(decoding: bytes[e.body..<e.end], as: UTF8.self)
            case 0x63a2: guard e.end - e.body <= 4096 else { throw WebMDemuxer.invalid() }; result.codecPrivate = Array(bytes[e.body..<e.end])
            case 0x23e383:
                let n = try uint(e); guard n > 0, n <= 10_000_000_000 else { throw WebMDemuxer.invalid() }; result.duration = Int64(n)
            case 0xe0:
                var child = e.body
                while child < e.end {
                    let dimension = try element(child, limit: e.end)
                    if dimension.id == 0xb0 || dimension.id == 0xba {
                        let n = try uint(dimension); guard n <= 4096 else { throw WebMDemuxer.invalid() }
                        if dimension.id == 0xb0 { result.width = Int(n) } else { result.height = Int(n) }
                    }
                    child = dimension.end
                }
            default: break
            }
            offset = e.end
        }
        return result
    }
    mutating func cluster(_ parent: Element) throws -> Int {
        var offset = parent.body, ticks: Int64 = 0
        while offset < parent.end {
            let e = try element(offset, limit: parent.end, allowUnknownMaster: true)
            if segmentChildren.contains(e.id) {
                guard parent.unknown else { throw WebMDemuxer.invalid() }
                return offset
            }
            guard !e.unknown, e.id != 0x18538067 else { throw WebMDemuxer.invalid() }
            switch e.id {
            case 0xe7: let n = try uint(e); guard n <= UInt64(Int64.max) else { throw WebMDemuxer.invalid() }; ticks = Int64(n)
            case 0xa3: blocks.append(Block(range: e.body..<e.end, ticks: ticks, key: true))
            case 0xa0:
                var child = e.body, range: Range<Int>?
                while child < e.end {
                    let sub = try element(child, limit: e.end)
                    if sub.id == 0xa1 { guard range == nil else { throw WebMDemuxer.invalid() }; range = sub.body..<sub.end }
                    child = sub.end
                }
                guard let range else { throw WebMDemuxer.invalid() }; blocks.append(Block(range: range, ticks: ticks, key: true))
            default: break
            }
            guard blocks.count <= 100_000 else { throw WebMDemuxer.invalid() }
            offset = e.end
        }
        return offset
    }
}
