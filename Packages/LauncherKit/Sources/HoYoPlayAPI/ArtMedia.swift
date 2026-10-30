// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Only a bounded header is needed; payloads are streamed directly to contained files.
enum ArtMedia {
    static let headerLimit = 4096
    static func imageExtension(_ bytes: Data) -> String? {
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "jpg" }
        if bytes.count >= 12, bytes.prefix(4) == Data("RIFF".utf8), bytes.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "webp" }
        return nil
    }

    static func isWebM(_ bytes: Data) -> Bool {
        let data = Array(bytes)
        guard data.starts(with: [0x1a, 0x45, 0xdf, 0xa3]), let header = vint(data, at: 4, maximum: 8, identifier: false),
            header.value <= UInt64(headerLimit), header.value <= UInt64(data.count - 4 - header.width) else { return false }
        var offset = 4 + header.width
        let end = offset + Int(header.value)
        while offset < end {
            guard let id = vint(data, at: offset, maximum: 4, identifier: true) else { return false }
            offset += id.width
            guard let size = vint(data, at: offset, maximum: 8, identifier: false) else { return false }
            offset += size.width
            guard offset <= end, size.value <= UInt64(end - offset) else { return false }
            if id.value == 0x4282 { return size.value == 4 && Array(data[offset..<(offset + 4)]) == Array("webm".utf8) }
            offset += Int(size.value)
        }
        return false
    }

    private static func vint(_ data: [UInt8], at offset: Int, maximum: Int, identifier: Bool) -> (value: UInt64, width: Int)? {
        guard offset < data.count, let width = (1...maximum).first(where: { data[offset] & (0x80 >> ($0 - 1)) != 0 }),
            width <= data.count - offset else { return nil }
        var value = UInt64(identifier ? data[offset] : data[offset] & (0xff >> width))
        for index in 1..<width { value = (value << 8) | UInt64(data[offset + index]) }
        if !identifier && value == (UInt64(1) << (7 * width)) - 1 { return nil }
        return (value, width)
    }

}
