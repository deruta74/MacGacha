// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

struct SyntheticWishCacheEntry {
    let key: String
    var created: UInt64 = 10
    var used: UInt64 = 10
    var keyBlock: Int = 0
    var indexed = true
    var state: UInt32 = 0
}

/// Chromium v2.1 blockfile records, generated from public layout definitions.
/// Long synthetic keys exercise the same data_2 addressing used by history URLs.
func writeSyntheticWishCache(_ fs: ContainedFileSystem, at root: SafeRelativePath,
    entries: [SyntheticWishCacheEntry]) throws {
    let capacity = 16
    var index = Data(repeating: 0, count: 368 + capacity * 4)
    index.putCacheInteger(UInt32(0xc103cac3), at: 0)
    index.putCacheInteger(UInt32(0x20001), at: 4)
    index.putCacheInteger(UInt32(entries.filter(\.indexed).count), at: 8)
    index.putCacheInteger(UInt32(1), at: 20)
    index.putCacheInteger(UInt32(capacity), at: 28)
    var rankings = syntheticBlockFile(number: 0, size: 36, capacity: capacity)
    var records = syntheticBlockFile(number: 1, size: 256, capacity: capacity)
    let keys = entries.map { Data(("1/0/" + String(repeating: "p", count: 1_000) + " " + $0.key).utf8) }
    let keyCapacity = max(16, zip(entries, keys).map { $0.0.keyBlock + ($0.1.count + 1 + 1023) / 1024 }.max() ?? 0)
    var data = syntheticBlockFile(number: 2, size: 1024, capacity: keyCapacity)
    for (i, entry) in entries.enumerated() {
        let entryAddress = syntheticCacheAddress(type: 2, file: 1, block: i)
        let rankAddress = syntheticCacheAddress(type: 1, file: 0, block: i)
        let blocks = (keys[i].count + 1 + 1023) / 1024
        precondition(blocks <= 4 && i < capacity)
        let keyAddress = syntheticCacheAddress(type: 3, file: 2, block: entry.keyBlock, blocks: blocks)
        if entry.indexed { index.putCacheInteger(entryAddress, at: 368 + i * 4) }
        let offset = 8192 + i * 256
        records.putCacheInteger(UInt32(i), at: offset)
        records.putCacheInteger(rankAddress, at: offset + 8)
        records.putCacheInteger(entry.state, at: offset + 20)
        records.putCacheInteger(entry.created, at: offset + 24)
        records.putCacheInteger(UInt32(keys[i].count), at: offset + 32)
        records.putCacheInteger(keyAddress, at: offset + 36)
        let rankOffset = 8192 + i * 36
        rankings.putCacheInteger(entry.used, at: rankOffset)
        rankings.putCacheInteger(entryAddress, at: rankOffset + 24)
        data.replaceSubrange((8192 + entry.keyBlock * 1024)..<(8192 + entry.keyBlock * 1024 + keys[i].count), with: keys[i])
        records.markCacheBlocks(i, count: 1)
        rankings.markCacheBlocks(i, count: 1)
        data.markCacheBlocks(entry.keyBlock, count: blocks)
    }
    for (name, bytes) in [("index", index), ("data_0", rankings), ("data_1", records), ("data_2", data)] {
        try fs.writeAtomically(bytes, to: SafeRelativePath(root.description + "/" + name))
    }
}

private func syntheticBlockFile(number: UInt16, size: UInt32, capacity: Int) -> Data {
    var bytes = Data(repeating: 0, count: 8192 + capacity * Int(size))
    bytes.putCacheInteger(UInt32(0xc104cac3), at: 0)
    bytes.putCacheInteger(UInt32(0x20000), at: 4)
    bytes.putCacheInteger(number, at: 8)
    bytes.putCacheInteger(size, at: 12)
    bytes.putCacheInteger(UInt32(capacity), at: 20)
    return bytes
}
func syntheticCacheAddress(type: UInt32, file: UInt32, block: Int, blocks: Int = 1) -> UInt32 {
    0x80000000 | (type << 28) | (UInt32(blocks - 1) << 24) | (file << 16) | UInt32(block)
}
extension Data {
    mutating func putCacheInteger<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    fileprivate mutating func markCacheBlocks(_ first: Int, count: Int) {
        for block in first..<(first + count) { self[80 + block / 8] |= UInt8(1 << (block % 8)) }
        let current = (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[16 + $1]) << ($1 * 8) }
        putCacheInteger(current + UInt32(count), at: 16)
    }
}
