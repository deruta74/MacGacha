// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
@testable import GameLibrary

@Suite(.timeLimit(.minutes(1))) struct WishHistoryCacheFreshnessTests {
    @Test(arguments: [0, 8]) func creationTimeWinsRegardlessOfKeyBlockOffset(freshBlock: Int) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            let game = GameDefinition.find("genshin")!
            try writeSyntheticWishCache(fs, at: cachePath(game), entries: [
                .init(key: link(game, marker: "301"), created: 30, used: 30, keyBlock: freshBlock),
                .init(key: link(game, marker: "200"), created: 20, used: 40, keyBlock: freshBlock == 0 ? 8 : 0)])
            #expect(try selectedMarker(game, root: temp.url) == "301")
        }
    }

    @Test func entryMetadataWinsAcrossCacheVersions() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("starrail")!
            try writeSyntheticWishCache(fs, at: cachePath(game, version: "1"), entries: [.init(key: link(game, marker: "301"), created: 30, used: 30)])
            try writeSyntheticWishCache(fs, at: cachePath(game, version: "2"), entries: [.init(key: link(game, marker: "200"), created: 20, used: 40)])
            #expect(try selectedMarker(game, root: temp.url) == "301")
        }
    }

    @Test func unindexedAndEvictedEntriesNeverOverrideAnActiveLink() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("zzz")!
            try writeSyntheticWishCache(fs, at: cachePath(game), entries: [
                .init(key: link(game, marker: "301"), created: 30, used: 30),
                .init(key: link(game, marker: "200"), created: 90, used: 90, keyBlock: 4, indexed: false),
                .init(key: link(game, marker: "100"), created: 100, used: 100, keyBlock: 8, state: 1)])
            #expect(try selectedMarker(game, root: temp.url) == "301")
        }
    }

    @Test func lastUsedBreaksCreationTiesWithoutUsingOffsets() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            try writeSyntheticWishCache(fs, at: cachePath(game), entries: [
                .init(key: link(game, marker: "301"), created: 30, used: 40),
                .init(key: link(game, marker: "200"), created: 30, used: 30, keyBlock: 4)])
            #expect(try selectedMarker(game, root: temp.url) == "301")
        }
    }

    @Test func indistinguishableMetadataDoesNotInventAByteOrderTieBreaker() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            try writeSyntheticWishCache(fs, at: cachePath(game), entries: [
                .init(key: link(game, marker: "301"), created: 30, used: 30),
                .init(key: link(game, marker: "200"), created: 30, used: 30, keyBlock: 4)])
            #expect(throws: LauncherError.wishHistoryNoCachedLink) { try selectedMarker(game, root: temp.url) }
        }
    }

    @Test(arguments: ["index", "table", "cycle", "bitmap", "rank", "dirty", "zero_time", "file_type"])
    func malformedMetadataNeverFallsBackToScanningRawURLs(kind: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            let root = try cachePath(game)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "301"))])
            let name = ["index", "table"].contains(kind) ? "index" : ["rank", "dirty"].contains(kind) ? "data_0" : kind == "bitmap" ? "data_2" : "data_1"
            let path = try SafeRelativePath(root.description + "/" + name)
            var bytes = try fs.readFile(at: path, maxBytes: 65_536)
            switch kind {
            case "index": bytes.putCacheInteger(UInt32(0), at: 0)
            case "table": bytes.putCacheInteger(UInt32.max, at: 28)
            case "cycle": bytes.putCacheInteger(syntheticCacheAddress(type: 2, file: 1, block: 0), at: 8192 + 4)
            case "bitmap": bytes[80] = 0
            case "rank": bytes.putCacheInteger(UInt32(0), at: 8192 + 24)
            case "dirty": bytes.putCacheInteger(UInt32(7), at: 8192 + 28)
            case "zero_time": bytes.putCacheInteger(UInt64(0), at: 8192 + 24)
            default:
                // A cached data_1 header cannot later masquerade as data_2.
                let keyData = try fs.readFile(at: SafeRelativePath(root.description + "/data_2"), maxBytes: 65_536)
                let count = Int((0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[8192 + 32 + $1]) << ($1 * 8) }) + 1
                bytes.replaceSubrange((8192 + 2048)..<(8192 + 2048 + count), with: keyData[8192..<(8192 + count)])
                bytes[80] |= 0b00001100
                bytes.putCacheInteger(syntheticCacheAddress(type: 3, file: 1, block: 2, blocks: 2), at: 8192 + 36)
            }
            try fs.writeAtomically(bytes, to: path)
            #expect(throws: LauncherError.wishHistoryNoCachedLink) { try selectedMarker(game, root: temp.url) }
        }
    }

    @Test func currentDirtyIdCanSupplyAStillOpenHistoryEntry() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            let root = try cachePath(game)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "301"))])
            let path = try SafeRelativePath(root.description + "/data_0")
            var bytes = try fs.readFile(at: path, maxBytes: 65_536)
            bytes.putCacheInteger(UInt32(1), at: 8192 + 28)
            try fs.writeAtomically(bytes, to: path)
            #expect(try selectedMarker(game, root: temp.url) == "301")
        }
    }

    @Test func largeBlockFilesAreReadOnlyAtMetadataAndKeyRanges() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            let root = try cachePath(game)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "301"))])
            let path = try SafeRelativePath(root.description + "/data_2")
            var bytes = try fs.readFile(at: path, maxBytes: 65_536)
            bytes.putCacheInteger(UInt32(64_896), at: 20)
            try fs.writeAtomically(bytes, to: path)
            let handle = try fs.openForWriting(at: path, truncate: false)
            try handle.truncate(atOffset: UInt64(8192 + 64_896 * 1024)); try handle.close()
            let budget = WishHistoryCacheBudget()
            let reader = try WishHistoryBlockCache(fs: fs, root: root, budget: budget)
            #expect(try reader.select(for: game).link != nil)
            #expect(budget.remaining > (64 << 20) - 65_536)
        }
    }

    @Test func metadataSymlinksCannotEscapeTheInstallRoot() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), target = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            let root = try cachePath(game)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "301"))])
            let path = try SafeRelativePath(root.description + "/data_1")
            let targetFS = try ContainedFileSystem(root: target.url)
            try targetFS.writeAtomically(fs.readFile(at: path, maxBytes: 65_536), to: SafeRelativePath("outside"))
            try fs.removeFile(at: path)
            try fs.createSymbolicLink(at: path, target: target.url.appendingPathComponent("outside").path)
            #expect(throws: LauncherError.wishHistoryNoCachedLink) { try selectedMarker(game, root: temp.url) }
        }
    }

    @Test func cacheDirectoryIsPinnedAcrossReplacement() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            let root = try cachePath(game)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "301"), created: 30, used: 30)])
            let reader = try WishHistoryBlockCache(fs: fs, root: root, budget: WishHistoryCacheBudget())
            try fs.moveItem(at: root, to: SafeRelativePath(root.description + "-old"), allowingNonRegularSource: true)
            try writeSyntheticWishCache(fs, at: root, entries: [.init(key: link(game, marker: "200"), created: 20, used: 20)])
            let selected = try #require(reader.select(for: game).link)
            let url = selected.requestURL(game: game, banner: "1", page: 1, endID: "0", language: "en")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "init_type" }?.value == "301")
        }
    }

    @Test func rawUnattributedLinksAreNotFreshnessEvidence() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), game = GameDefinition.find("genshin")!
            try fs.writeAtomically(Data(link(game, marker: "301").utf8), to: SafeRelativePath(cachePath(game).description + "/data_2"))
            #expect(throws: LauncherError.wishHistoryNoCachedLink) { try selectedMarker(game, root: temp.url) }
        }
    }
}

private func cachePath(_ game: LauncherCore.GameDefinition, version: String = "1") throws -> SafeRelativePath {
    try SafeRelativePath(game.dataDirectoryName + "/webCaches/" + version + "/Cache/Cache_Data")
}
private func link(_ game: LauncherCore.GameDefinition, marker: String) -> String {
    let family = game.family == .genshin ? "hk4e" : game.family == .starrail ? "hkrpg" : "nap"
    let host = "public-operation-" + family + (game.region == .global ? "-sg.hoyoverse.com" : ".mihoyo.com")
    let path = game.family == .genshin ? "/gacha_info/api/getGachaLog" : game.family == .starrail ? "/common/hkrpg_gacha_record/api/getGachaLog" : "/common/gacha_record/api/getGachaLog"
    return "https://" + host + path + "?authkey=synthetic-" + marker + "&game_biz=" + game.biz + "&init_type=" + marker
}
private func selectedMarker(_ game: LauncherCore.GameDefinition, root: URL) throws -> String? {
    let link = try WishHistoryCache.find(WishHistoryRequest(game: game, installRoot: root, language: "en-us", appVersion: "0.3.1"))
    let url = link.requestURL(game: game, banner: "1", page: 1, endID: "0", language: "en")
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "init_type" }?.value
}
