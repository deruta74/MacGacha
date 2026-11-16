// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Only indexed, allocated, normal entries supply links. Reused block offsets
/// and file modification dates are not evidence of an authorization's age.
struct WishHistoryCacheSelection {
    private var best: Entry?
    private var ambiguous = false
    struct Entry {
        let link: WishHistoryLink
        let created: UInt64
        let used: UInt64
    }
    var link: WishHistoryLink? { ambiguous ? nil : best?.link }
    mutating func include(_ entry: Entry) {
        if let best, best.created > entry.created || (best.created == entry.created && best.used > entry.used) { return }
        if let best, best.created == entry.created, best.used == entry.used {
            if best.link != entry.link { ambiguous = true }
        } else { best = entry; ambiguous = false }
    }
    mutating func merge(_ other: Self) {
        guard let candidate = other.best else { return }
        include(candidate)
        if other.ambiguous, best?.created == candidate.created, best?.used == candidate.used { ambiguous = true }
    }
}

final class WishHistoryCacheBudget {
    private(set) var remaining = 64 << 20
    func consume(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw LauncherError.wishHistoryNoCachedLink }
        remaining -= count
    }
}

/// Chromium blockfile index, EntryStore and RankingsNode layouts. Reads only
/// bounded metadata and key ranges through pinned contained file descriptors.
final class WishHistoryBlockCache {
    private struct File {
        let handle: FileHandle
        let size: UInt64
        var readBytes = 0
    }
    private let fs: ContainedFileSystem
    private let budget: WishHistoryCacheBudget
    private var files: [String: File] = [:]
    private var headers: [Int: Data] = [:]
    private static let maximumEntries = 16_384
    private static let maximumKeyBytes = 16_384
    init(fs: ContainedFileSystem, root: SafeRelativePath, budget: WishHistoryCacheBudget) throws {
        guard let pinned = try fs.pinDirectoryIfPresent(at: root) else { throw LauncherError.wishHistoryNoCachedLink }
        self.fs = pinned; self.budget = budget
    }
    deinit { for file in files.values { try? file.handle.close() } }

    func select(for game: GameDefinition) throws -> WishHistoryCacheSelection {
        let header = try read("index", offset: 0, count: 368)
        guard header.cacheU32(0) == 0xc103cac3,
            [UInt32(0x20000), 0x20001, 0x30000].contains(header.cacheU32(4)),
            header.cacheU32(8) <= Self.maximumEntries else { throw LauncherError.wishHistoryNoCachedLink }
        let tableLength = header.cacheU32(28) == 0 ? 65_536 : Int(header.cacheU32(28))
        guard tableLength > 0, tableLength <= 1 << 20, tableLength.nonzeroBitCount == 1 else { throw LauncherError.wishHistoryNoCachedLink }
        let table = try read("index", offset: 368, count: tableLength * 4)
        let thisID = header.cacheU32(20)
        var visited: Set<UInt32> = [], selection = WishHistoryCacheSelection()
        let regex = try NSRegularExpression(pattern: #"https://[^\x00-\x20"<>\\]{1,16384}"#)
        for bucket in 0..<tableLength {
            if bucket & 255 == 0 { try Task.checkCancellation() }
            var address = table.cacheU32(bucket * 4)
            while address != 0 {
                try Task.checkCancellation()
                guard visited.count < Self.maximumEntries, visited.insert(address).inserted else { throw LauncherError.wishHistoryNoCachedLink }
                let entry = try block(address, type: 2, count: 96)
                guard Int(entry.cacheU32(0)) & (tableLength - 1) == bucket else { throw LauncherError.wishHistoryNoCachedLink }
                let currentAddress = address
                address = entry.cacheU32(4)
                // Evicted and doomed entries can retain complete old key bytes.
                guard entry.cacheU32(20) == 0 else { continue }
                let created = entry.cacheU64(24), length = Int(entry.cacheU32(32))
                guard created > 0, created <= Int64.max, length > 0, length <= Self.maximumKeyBytes else { continue }
                let longKey = entry.cacheU32(36)
                let key: Data
                if length <= 927 {
                    guard longKey == 0 else { throw LauncherError.wishHistoryNoCachedLink }
                    key = try block(currentAddress, type: 2, relativeOffset: 96, count: length + 1)
                } else {
                    guard longKey != 0 else { throw LauncherError.wishHistoryNoCachedLink }
                    key = try keyBytes(longKey, count: length + 1)
                }
                guard key.last == 0, !key.dropLast().contains(0), let text = String(data: key.dropLast(), encoding: .utf8),
                    text.contains("authkey="), let link = uniqueLink(in: text, game: game, regex: regex) else { continue }
                let rankings = try block(entry.cacheU32(8), type: 1, count: 36)
                let dirty = rankings.cacheU32(28), used = rankings.cacheU64(0)
                guard rankings.cacheU32(24) == currentAddress, (dirty == 0 || dirty == thisID), used <= Int64.max else { continue }
                // Creation identifies a newly cached link. Reopening an old URL
                // can change last_used without renewing the credential it holds.
                selection.include(.init(link: link, created: created, used: max(created, used)))
            }
        }
        return selection
    }

    private func uniqueLink(in key: String, game: GameDefinition, regex: NSRegularExpression) -> WishHistoryLink? {
        var selected: WishHistoryLink?
        for match in regex.matches(in: key, range: NSRange(key.startIndex..., in: key)) {
            guard let range = Range(match.range, in: key), let link = WishHistoryLink(String(key[range]), game: game) else { continue }
            if let selected, selected != link { return nil }
            selected = link
        }
        return selected
    }

    private func keyBytes(_ address: UInt32, count: Int) throws -> Data {
        guard address & 0x80000000 != 0 else { throw LauncherError.wishHistoryNoCachedLink }
        let type = Int((address >> 28) & 7)
        if type == 0 {
            let name = String(format: "f_%06x", address & 0x0fffffff)
            guard try file(name).size == count else { throw LauncherError.wishHistoryNoCachedLink }
            return try read(name, offset: 0, count: count)
        }
        guard [2, 3, 4].contains(type) else { throw LauncherError.wishHistoryNoCachedLink }
        return try block(address, type: type, count: count)
    }

    private func block(_ address: UInt32, type: Int, relativeOffset: Int = 0, count: Int) throws -> Data {
        guard address & 0x80000000 != 0, address & 0x0c000000 == 0,
            Int((address >> 28) & 7) == type, [1, 2, 3, 4].contains(type) else { throw LauncherError.wishHistoryNoCachedLink }
        let number = Int((address >> 16) & 255), first = Int(address & 0xffff), blocks = Int((address >> 24) & 3) + 1
        let size = [1: 36, 2: 256, 3: 1024, 4: 4096][type]!
        let name = "data_\(number)"
        let header: Data
        if let cached = headers[number] { header = cached }
        else {
            header = try read(name, offset: 0, count: 8192)
            guard header.cacheU32(0) == 0xc104cac3, header.cacheU32(4) == 0x20000,
                header.cacheU16(8) == number, header.cacheU32(12) == size,
                header.cacheU32(20) <= 64_896, header.cacheU32(16) <= header.cacheU32(20) else { throw LauncherError.wishHistoryNoCachedLink }
            headers[number] = header
        }
        guard header.cacheU16(8) == number, header.cacheU32(12) == size,
            relativeOffset >= 0, count > 0, relativeOffset <= blocks * size, count <= blocks * size - relativeOffset,
            first + blocks <= Int(header.cacheU32(20)) else { throw LauncherError.wishHistoryNoCachedLink }
        for index in first..<(first + blocks) {
            guard header[80 + index / 8] & UInt8(1 << (index % 8)) != 0 else { throw LauncherError.wishHistoryNoCachedLink }
        }
        return try read(name, offset: UInt64(8192 + first * size + relativeOffset), count: count)
    }

    private func file(_ name: String) throws -> File {
        if let cached = files[name] { return cached }
        guard files.count < 32 else { throw LauncherError.wishHistoryNoCachedLink }
        let handle = try fs.openForReading(at: SafeRelativePath(name))
        do {
            let result = File(handle: handle, size: try handle.seekToEnd())
            files[name] = result
            return result
        } catch { try? handle.close(); throw error }
    }
    private func read(_ name: String, offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        var file = try file(name)
        guard count >= 0, offset <= file.size, UInt64(count) <= file.size - offset,
            count <= (16 << 20) - file.readBytes else { throw LauncherError.wishHistoryNoCachedLink }
        try budget.consume(count)
        file.readBytes += count; files[name] = file
        try file.handle.seek(toOffset: offset)
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            guard let part = try file.handle.read(upToCount: min(65_536, count - bytes.count)), !part.isEmpty else { throw LauncherError.wishHistoryNoCachedLink }
            bytes.append(part)
        }
        return bytes
    }
}

private extension Data {
    func cacheU16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func cacheU32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    func cacheU64(_ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << ($1 * 8) }
    }
}
