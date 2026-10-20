// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

/// libarchive and ditto can choose different ZIP name records. Require local and
/// central names to agree, including any Unicode-path overrides, before either tool runs.
/// Content, types, links and canonical path collisions are validated by ArchiveExtractor.
enum ZIPDirectory {
    static func validate(_ handle: FileHandle, maxEntries: Int) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 22 else { throw invalid() }
        let size = UInt64(info.st_size)
        let tailStart = size - min(size, 65_557)
        let tail = try read(handle, at: tailStart, count: Int(size - tailStart))
        guard let end = (0...(tail.count - 22)).reversed().first(where: {
            tail.u32($0) == 0x0605_4b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }) else { throw invalid() }
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0, tail.u16(end + 8) == tail.u16(end + 10) else { throw invalid() }
        var count = UInt64(tail.u16(end + 10))
        var centralSize = UInt64(tail.u32(end + 12))
        var offset = UInt64(tail.u32(end + 16))
        let endOffset = tailStart + UInt64(end)
        if count == 0xffff || centralSize == 0xffff_ffff || offset == 0xffff_ffff {
            guard endOffset >= 20 else { throw invalid() }
            let locator = try read(handle, at: endOffset - 20, count: 20)
            guard locator.u32(0) == 0x0706_4b50, locator.u32(4) == 0, locator.u32(16) == 1 else { throw invalid() }
            let record = try read(handle, at: locator.u64(8), count: 56)
            guard record.u32(0) == 0x0606_4b50, record.u64(4) >= 44,
                record.u32(16) == 0, record.u32(20) == 0, record.u64(24) == record.u64(32) else { throw invalid() }
            count = record.u64(32); centralSize = record.u64(40); offset = record.u64(48)
        }
        guard count <= maxEntries else { throw LauncherError.io("Archive entry limit exceeded") }
        guard offset <= endOffset, centralSize <= endOffset - offset else { throw invalid() }
        let centralStart = offset
        let centralEnd = offset + centralSize
        var localOffsets = Set<UInt64>()
        var metadata = 0
        for _ in 0..<count {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard offset <= centralEnd, centralEnd - offset >= 46 else { throw invalid() }
            let central = try read(handle, at: offset, count: 46)
            guard central.u32(0) == 0x0201_4b50, central.u16(34) == 0 else { throw invalid() }
            let nameLength = Int(central.u16(28)); let extraLength = Int(central.u16(30))
            let entrySize = UInt64(46 + nameLength + extraLength + Int(central.u16(32)))
            guard entrySize <= centralEnd - offset, (1...4096).contains(nameLength) else { throw invalid() }
            metadata += nameLength
            guard metadata <= 16 << 20 else { throw LauncherError.io("Archive metadata limit exceeded") }
            let name = try read(handle, at: offset + 46, count: nameLength)
            guard !name.contains(0) else { throw LauncherError.unsafePath("NUL in ZIP path") }
            guard String(data: name, encoding: .utf8) != nil,
                !name.contains(where: { $0 >= 128 }) || central.u16(8) & 0x800 != 0 else {
                throw LauncherError.unsafePath("Invalid ZIP filename encoding")
            }
            let extra = try read(handle, at: offset + 46 + UInt64(nameLength), count: extraLength)
            try validateUnicode(extra, name: name)
            var localOffset = UInt64(central.u32(42))
            if localOffset == 0xffff_ffff {
                guard let zip64 = try fields(extra).first(where: { $0.tag == 1 })?.value else { throw invalid() }
                let position = (central.u32(24) == 0xffff_ffff ? 8 : 0) + (central.u32(20) == 0xffff_ffff ? 8 : 0)
                guard position + 8 <= zip64.count else { throw invalid() }
                localOffset = zip64.u64(position)
            }
            guard localOffsets.insert(localOffset).inserted, localOffset < centralStart, centralStart - localOffset >= 30 else { throw invalid() }
            let local = try read(handle, at: localOffset, count: 30)
            guard local.u32(0) == 0x0403_4b50, local.u16(6) == central.u16(8), local.u16(8) == central.u16(10) else { throw invalid() }
            guard Int(local.u16(26)) == nameLength else { throw LauncherError.unsafePath("Conflicting ZIP entry names") }
            guard UInt64(30 + nameLength + Int(local.u16(28))) <= centralStart - localOffset else { throw invalid() }
            let localName = try read(handle, at: localOffset + 30, count: nameLength)
            guard localName == name else { throw LauncherError.unsafePath("Conflicting ZIP entry names") }
            let localExtra = try read(handle, at: localOffset + 30 + UInt64(nameLength), count: Int(local.u16(28)))
            try validateUnicode(localExtra, name: name)
            offset += entrySize
        }
        guard offset == centralEnd else { throw invalid() }
    }

    private static func validateUnicode(_ extra: Data, name: Data) throws {
        for field in try fields(extra) where field.tag == 0x7075 {
            // An alternate spelling can change containment or collide only in one parser.
            guard field.value.count >= 5, field.value[0] == 1, Data(field.value.dropFirst(5)) == name else {
                throw LauncherError.unsafePath("Conflicting Unicode ZIP path")
            }
        }
    }

    private static func fields(_ data: Data) throws -> [(tag: UInt16, value: Data)] {
        var result: [(UInt16, Data)] = []; var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw invalid() }
            let count = Int(data.u16(offset + 2))
            guard count <= data.count - offset - 4 else { throw invalid() }
            result.append((data.u16(offset), data.subdata(in: (offset + 4)..<(offset + 4 + count))))
            offset += 4 + count
        }
        return result
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        guard offset <= UInt64(Int64.max), count <= 131_072,
            UInt64(count) <= UInt64(Int64.max) - offset else { throw invalid() }
        var data = Data(count: count); var position = 0
        try data.withUnsafeMutableBytes { bytes in
            while position < count {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let read = pread(handle.fileDescriptor, bytes.baseAddress!.advanced(by: position), count - position, Int64(offset) + Int64(position))
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw invalid() }
                position += read
            }
        }
        return data
    }

    private static func invalid() -> LauncherError { .io("Invalid ZIP directory") }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
}
