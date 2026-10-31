// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Only inspect load commands, never execute runtime tools. Bounds cover fat
/// slice tables, command counts/sizes and strings before any indexing occurs.
enum MachOLoadCommands {
    static let maximumFileBytes = 32 << 20
    static let maximumCommandBytes = 8 << 20

    struct Image: Equatable {
        var rpaths: [String] = []
        var dylibs: [String] = []
    }

    static func images(in data: Data) throws -> [Image] {
        guard data.count <= maximumFileBytes else { throw invalid() }
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        func word(_ at: Int, little: Bool, width: Int = 4) throws -> UInt64 {
            guard at >= 0, width <= bytes.count, at <= bytes.count - width else { throw invalid() }
            return (0..<width).reduce(UInt64(0)) { value, i in
                value | UInt64(bytes[at + i]) << ((little ? i : width - i - 1) * 8)
            }
        }
        func thin(_ offset: Int, _ length: Int) throws -> Image {
            guard length >= 4, offset >= 0, length <= bytes.count, offset <= bytes.count - length else { throw invalid() }
            let magic = try word(offset, little: true)
            let little: Bool, header: Int
            switch magic {
            case 0xfeedface: little = true; header = 28
            case 0xfeedfacf: little = true; header = 32
            case 0xcefaedfe: little = false; header = 28
            case 0xcffaedfe: little = false; header = 32
            default: throw invalid()
            }
            guard length >= header else { throw invalid() }
            let count = Int(try word(offset + 16, little: little))
            let size = Int(try word(offset + 20, little: little))
            guard count <= 8192, size <= maximumCommandBytes, size <= length - header, count <= size / 8 else { throw invalid() }
            var cursor = offset + header
            let end = cursor + size
            var result = Image()
            for _ in 0..<count {
                guard cursor <= end - 8 else { throw invalid() }
                let kind = try word(cursor, little: little)
                let commandSize = Int(try word(cursor + 4, little: little))
                guard commandSize >= 8, commandSize % 4 == 0, commandSize <= end - cursor else { throw invalid() }
                let isRpath = kind == 0x8000001c
                let isDylib = [UInt64(0xc), 0x18, 0x80000018, 0x1f, 0x8000001f, 0x20, 0x23, 0x80000023].contains(kind)
                if isRpath || isDylib {
                    let minimum = isRpath ? 12 : 24
                    guard commandSize >= minimum else { throw invalid() }
                    let start = Int(try word(cursor + 8, little: little))
                    guard start >= minimum, start < commandSize else { throw invalid() }
                    let stringBytes = bytes[(cursor + start)..<(cursor + commandSize)]
                    guard let nul = stringBytes.firstIndex(of: 0), nul - (cursor + start) <= 4096,
                        let path = String(bytes: bytes[(cursor + start)..<nul], encoding: .utf8), !path.isEmpty else { throw invalid() }
                    if isRpath { result.rpaths.append(path) } else { result.dylibs.append(path) }
                }
                cursor += commandSize
            }
            guard cursor == end else { throw invalid() }
            return result
        }
        let magic = try word(0, little: false)
        if [UInt64(0xcafebabe), 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let wide = magic == 0xcafebabf || magic == 0xbfbafeca
            let count = Int(try word(4, little: little)), entrySize = wide ? 32 : 20
            guard count > 0, count <= 64, bytes.count >= 8 + count * entrySize else { throw invalid() }
            var ranges: [Range<Int>] = [], result: [Image] = []
            for index in 0..<count {
                let base = 8 + index * entrySize
                let offset = try word(base + 8, little: little, width: wide ? 8 : 4)
                let size = try word(base + (wide ? 16 : 12), little: little, width: wide ? 8 : 4)
                guard offset >= UInt64(8 + count * entrySize), offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset else { throw invalid() }
                let range = Int(offset)..<Int(offset + size)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid() }
                ranges.append(range)
                result.append(try thin(range.lowerBound, range.count))
            }
            return result
        }
        guard [UInt64(0xfeedface), 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) else { return [] }
        return [try thin(0, bytes.count)]
    }

    private static func invalid() -> LauncherError { .io("Invalid Game Mode Mach-O load commands") }
}
