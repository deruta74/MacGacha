// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import HoYoPlayAPI
import TestSupport

@Suite struct RegionArtTests {
    @Test(arguments: [Region.global, .mainlandChina]) func regionSelectsEndpointsAndContentLanguage(region: Region) throws {
        let urls = GameArtService.apiURLs(region: region, language: .enUS)
        for url in [urls.games, urls.basic] {
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.host == (region == .global ? "sg-hyp-api.hoyoverse.com" : "hyp-api.mihoyo.com"))
            #expect(components.queryItems == [URLQueryItem(name: "launcher_id", value: region == .global ? "VYTpXlbWo8" : "jGHBHlcOq1"),
                URLQueryItem(name: "language", value: region == .global ? "en-us" : "zh-cn")])
        }
    }

    @Test func cnFixturesAndGlobalCacheStaySeparateThroughHydrationAndPruning() async throws {
        let temp = try TempDir(), http = RegionArtHTTP()
        try http.configureCN()
        try http.configureGlobal(background: "https://fastcdn.hoyoverse.com/first.png")
        let directory = temp.url.appendingPathComponent("GameArt")
        let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let global = GameArtService(cacheDirectory: directory, http: http, now: { time.withLock { $0 } })
        let original = await global.refresh()
        let globalFile = try #require(original["genshin"]?.background)
        let cn = GameArtService(cacheDirectory: directory, region: .mainlandChina, http: http, now: { time.withLock { $0 } })
        #expect(await cn.loadCached().isEmpty)
        let chinese = await cn.refresh()
        #expect(Set(chinese.keys) == ["genshin-cn", "starrail-cn", "zzz-cn"])
        for game in chinese.values { #expect(game.background != nil && game.icon != nil && game.logo != nil) }
        let cnFile = try #require(chinese["genshin-cn"]?.background)
        #expect(cnFile.deletingLastPathComponent() != globalFile.deletingLastPathComponent())
        #expect(try Data(contentsOf: globalFile) == regionPNG)
        let count = http.requests.count
        let restoredGlobal = GameArtService(cacheDirectory: directory, http: http, now: { time.withLock { $0 } })
        let restoredCN = GameArtService(cacheDirectory: directory, region: .mainlandChina, http: http, now: { time.withLock { $0 } })
        #expect(await restoredGlobal.loadCached() == original)
        #expect(await restoredCN.loadCached() == chinese)
        #expect(await restoredGlobal.refresh() == original)
        #expect(await restoredCN.refresh() == chinese)
        #expect(http.requests.count == count)
        time.withLock { $0 = $0.addingTimeInterval(6 * 3600 + 1) }
        try http.configureGlobal(background: "https://fastcdn.hoyoverse.com/replacement.png")
        #expect(await global.refresh() != original)
        #expect(try Data(contentsOf: cnFile) == regionPNG)
        #expect(await GameArtService(cacheDirectory: directory, region: .mainlandChina, http: http).loadCached() == chinese)
        let cnRequests = http.requests.filter { $0.host?.hasSuffix(".mihoyo.com") == true }
        #expect(cnRequests.contains { $0.lastPathComponent == "getGames" })
        #expect(cnRequests.contains { $0.lastPathComponent == "getAllGameBasicInfo" })
    }

    @Test(arguments: [Region.global, .mainlandChina]) func artRejectsOtherRegionsCDN(region: Region) async throws {
        let temp = try TempDir(), http = RegionArtHTTP()
        let foreign = region == .global ? "https://fastcdn.mihoyo.com/foreign.png" : "https://fastcdn.hoyoverse.com/foreign.png"
        let biz = region == .global ? "hk4e_global" : "hk4e_cn"
        let games = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["games": [["biz": biz, "display": ["background": ["url": foreign]]]]]])
        let cdn = region == .global ? http.global : http.cn
        cdn.serve("hyp/hyp-connect/api/getGames", data: games)
        cdn.serve("hyp/hyp-connect/api/getAllGameBasicInfo", data: Data(#"{"retcode":0,"data":{"game_info_list":[]}}"#.utf8))
        let art = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("art"), region: region, http: http).refresh()
        #expect(Set(art.keys) == [region == .global ? "genshin" : "genshin-cn"])
        #expect(art.values.allSatisfy { $0.background == nil })
        #expect(!http.requests.contains { $0.absoluteString == foreign })
    }
}

private let regionPNG = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])

private final class RegionArtHTTP: HTTPClient, Sendable {
    let global = MockCDN(), cn = MockCDN()
    private let recorded = Mutex<[URL]>([])
    var requests: [URL] { recorded.withLock { $0 } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        recorded.withLock { $0.append(url) }
        return try await (url.host?.hasSuffix(".mihoyo.com") == true ? cn : global).get(url, byteRangeFrom: offset)
    }
    func configureGlobal(background: String) throws {
        global.serve("hyp/hyp-connect/api/getGames", data: try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["games": [["biz": "hk4e_global", "display": ["background": ["url": background]]]]]]))
        global.serve("hyp/hyp-connect/api/getAllGameBasicInfo", data: Data(#"{"retcode":0,"data":{"game_info_list":[]}}"#.utf8))
        global.serve(URL(string: background)!.path, data: regionPNG)
    }
    func configureCN() throws {
        func images(_ value: Any) {
            if let object = value as? [String: Any] {
                if let string = object["url"] as? String, let url = URL(string: string) { cn.serve(url.path, data: regionPNG) }
                object.values.forEach(images)
            } else if let list = value as? [Any] { list.forEach(images) }
        }
        for name in ["getGames", "getAllGameBasicInfo"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "CN"))
            let data = try Data(contentsOf: url)
            cn.serve("hyp/hyp-connect/api/" + name, data: data)
            images(try JSONSerialization.jsonObject(with: data))
        }
    }
}
