// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import HoYoPlayAPI
import TestSupport

@Test
func mappingPrefersBasicBackgroundAndExposesNativeVideo() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, video: true)
    let service = GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn)
    let art = await service.refresh()
    #expect(Set(art.keys) == ["genshin", "starrail", "zzz"])
    let genshin = try #require(art["genshin"])
    #expect(try Data(contentsOf: #require(genshin.background)) == png)
    #expect(genshin.background?.lastPathComponent == hashURL("https://fastcdn.hoyoverse.com/preferred") + ".png")
    #expect(genshin.icon?.pathExtension == "jpg" && genshin.logo?.pathExtension == "webp")
    let video = try #require(genshin.video)
    #expect(video.pathExtension == "webm" && genshin.theme != nil)
    let root = temp.url
    let paths = try await BlockingIO.run { try ContainedFileSystem(root: root).contentsOfDirectory(at: SafeRelativePath("GameArt")) }
    #expect(!paths.contains { $0.description.hasSuffix(".html") })
    #expect(service.cached() == art)
    #expect(art["starrail"]?.background?.lastPathComponent == hashURL("https://fastcdn.hoyoverse.com/fallback") + ".png")
}

@Test
func legacyCacheIndexLoadsOfflineWithoutRegeneratingHTML() async throws {
    let temp = try TempDir(), cdn = MockCDN()
    try artFixtures(cdn, video: true)
    let directory = temp.url.appendingPathComponent("GameArt")
    let first = await GameArtService(cacheDirectory: directory, http: cdn).refresh()
    let video = try #require(first["genshin"]?.video)
    let oldPage = try SafeRelativePath(video.deletingPathExtension().appendingPathExtension("html").lastPathComponent)
    let before = try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: directory)
        try fs.removeFile(at: oldPage)
        return try fs.readFile(at: SafeRelativePath("art-index.json"), maxBytes: 1 << 20)
    }
    let requests = cdn.requestLog.count
    let restored = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    #expect(restored["genshin"]?.video == video && restored["genshin"]?.background == first["genshin"]?.background)
    #expect(cdn.requestLog.count == requests)
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: directory)
        #expect(try fs.itemType(at: oldPage) == nil)
        #expect(try fs.readFile(at: SafeRelativePath("art-index.json"), maxBytes: 1 << 20) == before)
    }
}

@Test
func legacyVideoPageKeyDoesNotPreventGameArtDecoding() throws {
    let data = Data(#"{"background":"file:///cache/still.png","video":"file:///cache/video.webm","videoPage":"file:///cache/video.html"}"#.utf8)
    let art = try JSONDecoder().decode(GameArt.self, from: data)
    #expect(art.video?.lastPathComponent == "video.webm" && art.background?.lastPathComponent == "still.png")
}

@Test
func emptyOptionalURLsInOtherLayersDoNotDiscardGameArt() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn)
    // Static entries (even ignored games and later layers) contain empty URL strings.
    // Keep this synthetic: only the response shape matches the live API.
    cdn.serve(apiBasic, data: Data(#"""
        {"retcode":0,"data":{"game_info_list":[
          {"game":{"biz":"ignored"},"backgrounds":[{"background":{"url":"https://fastcdn.hoyoverse.com/unused.webp"},"video":{"url":""},"theme":{"url":""},"type":"BACKGROUND_TYPE_UNSPECIFIED"}]},
          {"game":{"biz":"hk4e_global"},"backgrounds":[{"background":{"url":"https://fastcdn.hoyoverse.com/preferred?format=webp"},"video":{"url":""},"theme":{"url":""},"type":"BACKGROUND_TYPE_UNSPECIFIED"}]},
          {"game":{"biz":"hkrpg_global"},"backgrounds":[{"background":{"url":"https://launcher-webstatic.hoyoverse.com/fallback?format=webp"},"video":{"url":"https://fastcdn.hoyoverse.com/video?format=webm"},"theme":{"url":"https://fastcdn.hoyoverse.com/theme?format=webp"},"type":"BACKGROUND_TYPE_VIDEO"},{"video":{"url":""},"theme":{"url":""},"type":"BACKGROUND_TYPE_UNSPECIFIED"}]},
          {"game":{"biz":"nap_global"},"backgrounds":[{"background":{"url":"https://fastcdn.hoyoverse.com/preferred"},"video":{"url":"https://launcher-webstatic.hoyoverse.com/video"},"theme":{"url":"https://fastcdn.hoyoverse.com/theme"},"type":"BACKGROUND_TYPE_VIDEO"}]}
        ]}}
        """#.utf8))
    cdn.serve("preferred", data: webp)
    let art = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn).refresh()
    #expect(Set(art.keys) == ["genshin", "starrail", "zzz"])
    for id in ["genshin", "starrail", "zzz"] {
        let game = try #require(art[id])
        for file in [game.background, game.icon, game.logo] {
            #expect(FileManager.default.fileExists(atPath: try #require(file).path))
        }
    }
    #expect(art["genshin"]?.background?.pathExtension == "webp")
    #expect(art["genshin"]?.video == nil)
    for id in ["starrail", "zzz"] {
        let game = try #require(art[id])
        for file in [game.video, game.theme] {
            #expect(FileManager.default.fileExists(atPath: try #require(file).path))
        }
    }
}

@Test(arguments: ["http://fastcdn.hoyoverse.com/evil", "https://hoyoverse.com.evil.test/evil", "https://evil.test/evil", "https://fastcdn.hoyoverse.com@evil.test/evil"])
func rejectsUnapprovedAssetURLs(url: String) async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, background: url)
    let art = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn).refresh()
    #expect(art["genshin"]?.background == nil)
    #expect(!cdn.requestLog.contains { $0.path == "evil" })
}

@Test
func nonImagesAndMalformedWebMDoNotBlockStaticSet() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, video: true)
    cdn.serve("icon", data: Data("<html>not an image</html>".utf8))
    cdn.serve("video", data: Data([0x1a, 0x45, 0xdf, 0xa3]) + Data("not actually webm".utf8))
    let art = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn).refresh()
    #expect(art["genshin"]?.background != nil)
    #expect(art["genshin"]?.icon == nil && art["genshin"]?.video == nil)
}

@Test
func sizeCapsRejectOversizedImagesVideosAndJSON() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, video: true)
    cdn.serve("preferred", data: png + Data(repeating: 0, count: 16 << 20))
    cdn.serve("video", data: webm + Data(repeating: 0, count: 64 << 20))
    let service = GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn)
    let art = await service.refresh()
    #expect(art["genshin"]?.background == nil && art["genshin"]?.video == nil)
    let second = try TempDir()
    cdn.serve(apiGames, data: try JSONSerialization.data(withJSONObject: [
        "retcode": 0, "data": ["games": [["biz": "hk4e_global"]]], "padding": String(repeating: " ", count: 2 << 20)]))
    let empty = await GameArtService(cacheDirectory: second.url.appendingPathComponent("GameArt"), http: cdn).refresh()
    #expect(empty.isEmpty)
}

@Test
func cacheTTLAndOfflineFallbackSurviveReinitialization() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); try artFixtures(cdn)
    let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let directory = temp.url.appendingPathComponent("GameArt")
    let service = GameArtService(cacheDirectory: directory, http: cdn, now: { time.withLock { $0 } })
    let original = await service.refresh(); let count = cdn.requestLog.count
    #expect(!original.isEmpty)
    #expect(await service.refresh() == original)
    let restored = GameArtService(cacheDirectory: directory, http: cdn, now: { time.withLock { $0 } })
    #expect(await restored.refresh() == original)
    #expect(cdn.requestLog.count == count)
    time.withLock { $0 = $0.addingTimeInterval(6 * 3600 + 1) }
    cdn.enqueueFault(apiGames, .transportError)
    #expect(await restored.refresh() == original)
    #expect(restored.cached() == original)
}

@Test
func pruningKeepsPagesExactlyWithTheirVideos() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); try artFixtures(cdn, video: true)
    let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let directory = temp.url.appendingPathComponent("com.lo7ted.macgacha/GameArt")
    let outside = temp.url.appendingPathComponent("another-app.webp")
    try webp.write(to: outside)
    let service = GameArtService(cacheDirectory: directory, http: cdn, now: { time.withLock { $0 } })
    let first = await service.refresh()
    let old = try #require(first["genshin"]?.background); let video = try #require(first["genshin"]?.video)
    let page = video.deletingPathExtension().appendingPathExtension("html")
    try await BlockingIO.run {
        try ContainedFileSystem(root: directory).writeAtomically(Data("legacy page".utf8), to: SafeRelativePath(page.lastPathComponent))
    }
    let stray = directory.appendingPathComponent("stray.png"); try png.write(to: stray)
    time.withLock { $0 = $0.addingTimeInterval(6 * 3600 + 1) }
    try artFixtures(cdn, background: "https://other.hoyoverse.com/new")
    cdn.serve("new", data: png)
    let second = await service.refresh()
    #expect(second["genshin"]?.background != old && second["genshin"]?.video == nil)
    for file in [old, video, page, stray] { #expect(!FileManager.default.fileExists(atPath: file.path)) }
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("art-index.json").path))
    #expect(try Data(contentsOf: outside) == webp)
}

@Test
func streamedCapsApplyWithoutContentLengthAndCancellationFinishes() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); try artFixtures(cdn)
    let http = NoLengthHTTP(cdn: cdn)
    let art = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: http).refresh()
    #expect(art["genshin"]?.background == nil && art["genshin"]?.icon != nil)
    let cancelled = Task { () -> [String: GameArt] in
        withUnsafeCurrentTask { $0?.cancel() }
        return await GameArtService(cacheDirectory: temp.url.appendingPathComponent("other"), http: cdn).refresh()
    }
    #expect(await cancelled.value.isEmpty)
}

private let apiGames = "hyp/hyp-connect/api/getGames"
private let apiBasic = "hyp/hyp-connect/api/getAllGameBasicInfo"
private let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
private let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0, 0])
private let webp = Data("RIFF".utf8) + Data([4, 0, 0, 0]) + Data("WEBP".utf8)
private let webm = Data([0x1a, 0x45, 0xdf, 0xa3, 0x87, 0x42, 0x82, 0x84]) + Data("webm".utf8)

private func artFixtures(_ cdn: MockCDN, background: String = "https://fastcdn.hoyoverse.com/preferred", video: Bool = false) throws {
    let display: [String: Any] = ["icon": ["url": "https://launcher-webstatic.hoyoverse.com/icon"],
        "logo": ["url": "https://fastcdn.hoyoverse.com/logo"], "background": ["url": "https://fastcdn.hoyoverse.com/fallback"]]
    let games: [[String: Any]] = ["hk4e_global", "hkrpg_global", "nap_global", "unknown"].map { ["biz": $0, "display": display] }
    cdn.serve(apiGames, data: try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["games": games]]))
    var layer: [String: Any] = ["background": ["url": background], "type": video ? "BACKGROUND_TYPE_VIDEO" : "BACKGROUND_TYPE_IMAGE"]
    if video { layer["video"] = ["url": "https://fastcdn.hoyoverse.com/video"]; layer["theme"] = ["url": "https://fastcdn.hoyoverse.com/theme"] }
    cdn.serve(apiBasic, data: try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["game_info_list": [["game": ["biz": "hk4e_global"], "backgrounds": [layer]]]]]))
    cdn.serve("preferred", data: png); cdn.serve("fallback", data: png); cdn.serve("icon", data: jpeg); cdn.serve("logo", data: webp)
    cdn.serve("video", data: webm); cdn.serve("theme", data: webp)
}

private func hashURL(_ string: String) -> String { var h = StreamingHasher(.sha256); h.update(Data(string.utf8)); return h.finalize().hex }
private struct NoLengthHTTP: HTTPClient {
    let cdn: MockCDN
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard url.lastPathComponent == "preferred" else { return try await cdn.get(url, byteRangeFrom: offset) }
        let count = Mutex(0)
        return (HTTPResponseHead(status: 200), HTTPBody(next: {
            count.withLock { value in
                value += 1
                guard value <= 257 else { return nil }
                var bytes = Data(repeating: 0, count: 65_536)
                if value == 1 { bytes.replaceSubrange(0..<png.count, with: png) }
                return bytes
            }
        }))
    }
}

@Test(.timeLimit(.minutes(1)))
func requestDeadlineStopsNeverEndingBodyAndPreservesOtherImages() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); try artFixtures(cdn)
    let http = StallingArtHTTP(cdn: cdn)
    let service = GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"),
        // Leave healthy requests time to run while CI executes other suites.
        // The minute limit detects a missing deadline without benchmarking I/O.
        http: http, requestTimeout: .seconds(2))
    let art = await service.refresh()
    #expect(http.started.withLock { $0 })
    #expect(art["genshin"]?.background == nil && art["genshin"]?.icon != nil)
}

@Test
func artLogsOnlyHostsAndStatuses() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, background: "https://fastcdn.hoyoverse.com/preferred?token=planted-secret")
    let logs = temp.url.appendingPathComponent("Logs")
    _ = await GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn, log: EventLog(directory: logs)).refresh()
    let text = try String(contentsOf: logs.appendingPathComponent("macgacha.log"), encoding: .utf8)
    #expect(text.contains("fastcdn.hoyoverse.com") && text.contains("status"))
    #expect(!text.contains("planted-secret") && !text.contains("launcher_id") && !text.contains("https://"))
}

@Test
func skippedAssetsAndInvalidResponsesLogSafeReasons() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    try artFixtures(cdn, background: "https://evil.test/private?token=planted-secret", video: true)
    cdn.serve("icon", data: Data("not an image".utf8))
    cdn.serve("video", data: Data("not a video".utf8))
    let logs = temp.url.appendingPathComponent("Logs")
    let service = GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn,
        log: EventLog(directory: logs))
    _ = await service.refresh()
    // Exercise the response-decode failure path as well as per-asset skips.
    let other = GameArtService(cacheDirectory: temp.url.appendingPathComponent("other"), http: cdn,
        log: EventLog(directory: logs))
    cdn.serve(apiBasic, data: Data("not JSON planted-secret".utf8))
    _ = await other.refresh()
    let text = try String(contentsOf: logs.appendingPathComponent("macgacha.log"), encoding: .utf8)
    for reason in ["url-not-allowed", "invalid-image", "invalid-webm", "invalid-api-response"] {
        #expect(text.contains(reason))
    }
    #expect(!text.contains("planted-secret") && !text.contains("https://") && !text.contains("/private"))
}

private final class StallingArtHTTP: HTTPClient, Sendable {
    let cdn: MockCDN
    let started = Mutex(false)
    init(cdn: MockCDN) { self.cdn = cdn }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        guard url.lastPathComponent == "preferred" else { return try await cdn.get(url, byteRangeFrom: offset) }
        return (HTTPResponseHead(status: 200), HTTPBody(next: {
            self.started.withLock { $0 = true }
            try await Task.sleep(for: .seconds(3600))
            return nil
        }))
    }
}

@Test
func refreshRequestsTheInjectedLanguageAndRefetchesWhenItChanges() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); try artFixtures(cdn)
    let http = QueryRecordingHTTP(cdn: cdn)
    let directory = temp.url.appendingPathComponent("GameArt")
    let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    _ = await GameArtService(cacheDirectory: directory, http: http, now: { time.withLock { $0 } }).refresh()
    #expect(http.apiLanguages() == ["en-us", "en-us"])
    // Within the TTL the same language is served from the cache, another language is fetched.
    _ = await GameArtService(cacheDirectory: directory, language: .enUS, http: http, now: { time.withLock { $0 } }).refresh()
    #expect(http.apiLanguages() == ["en-us", "en-us"])
    let russian = await GameArtService(cacheDirectory: directory, language: .ruRU, http: http, now: { time.withLock { $0 } }).refresh()
    #expect(http.apiLanguages() == ["en-us", "en-us", "ru-ru", "ru-ru"])
    #expect(!russian.isEmpty)
}

private final class QueryRecordingHTTP: HTTPClient, Sendable {
    let cdn: MockCDN
    private let urls = Mutex<[URL]>([])
    init(cdn: MockCDN) { self.cdn = cdn }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        urls.withLock { $0.append(url) }
        return try await cdn.get(url, byteRangeFrom: offset)
    }
    /// The `language=` value of every API request so far, in order.
    func apiLanguages() -> [String] {
        urls.withLock { $0 }.filter { $0.host == "sg-hyp-api.hoyoverse.com" }.compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "language" }?.value
        }
    }
}

@Test
func orderedBackgroundsRestoreLargeIndexAndMigrateLegacyOffline() async throws {
    let temp = try TempDir(), cdn = MockCDN(); try artFixtures(cdn)
    let layers: [[String: Any]] = (0..<8).map { n in
        let base = "https://fastcdn.hoyoverse.com/layer-\(n)"
        for suffix in ["", "-icon", "-hover"] { cdn.serve("layer-\(n)" + suffix, data: png) }
        return ["id": "slide-\(n)", "background": ["url": base],
            "icon": ["url": base + "-icon", "hover_url": base + "-hover", "link": n == 0 ? "https://hoyo.link/test" : "http://unsafe.test"]]
    }
    cdn.serve(apiBasic, data: try JSONSerialization.data(withJSONObject: ["data": ["game_info_list": [["game": ["biz": "hk4e_global"], "backgrounds": layers]]]]))
    let directory = temp.url.appendingPathComponent("GameArt")
    let art = await GameArtService(cacheDirectory: directory, http: cdn).refresh()
    let backgrounds = try #require(art["genshin"]?.backgrounds)
    #expect(backgrounds.map(\.id) == (0..<8).map { "slide-\($0)" })
    #expect(backgrounds.allSatisfy { $0.image != nil && $0.highlights?.image != nil && $0.highlights?.hoverImage != nil })
    #expect(backgrounds[0].highlights?.link == URL(string: "https://hoyo.link/test"))
    #expect(backgrounds[1].highlights?.link == nil)
    #expect(!cdn.requestLog.contains { $0.path == "test" })
    let count = cdn.requestLog.count
    let restored = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    #expect(restored == art)
    #expect(cdn.requestLog.count == count)

    let indexURL = directory.appendingPathComponent("art-index.json")
    var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
    var games = try #require(index["games"] as? [String: [String: Any]])
    games["genshin"]?.removeValue(forKey: "backgrounds"); index["games"] = games
    try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
    let legacy = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    let migrated = try #require(legacy["genshin"]?.backgrounds.first)
    #expect(migrated.image == art["genshin"]?.background)
    let again = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    #expect(again["genshin"]?.backgrounds.first?.id == migrated.id)
    try FileManager.default.removeItem(at: #require(migrated.image))
    let missing = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    #expect(missing["genshin"]?.backgrounds.first?.image == nil)

    // A fresh legacy index is refetched at once instead of waiting for the TTL.
    index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
    games = try #require(index["games"] as? [String: [String: Any]])
    games["genshin"]?.removeValue(forKey: "backgrounds"); index["games"] = games
    try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
    let before = cdn.requestLog.count
    let upgraded = await GameArtService(cacheDirectory: directory, http: cdn).refresh()
    #expect(cdn.requestLog.count > before)
    #expect(upgraded["genshin"]?.backgrounds.count == 8)
}

@Test
func highlightsFallbackStaysWithinSlideAndAbsentIconRemovesIt() async throws {
    let temp = try TempDir(), cdn = MockCDN(); try artFixtures(cdn, video: true)
    let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    func serve(_ suffix: String, includeIcon: Bool) throws {
        let layers: [[String: Any]] = ["a", "b"].map { id in
            var layer: [String: Any] = ["id": id, "background": ["url": "https://fastcdn.hoyoverse.com/preferred"]]
            if includeIcon { layer["icon"] = ["url": "https://fastcdn.hoyoverse.com/\(id)\(suffix)", "hover_url": "", "link": "javascript:alert(1)"] }
            return layer
        }
        cdn.serve(apiBasic, data: try JSONSerialization.data(withJSONObject: ["data": ["game_info_list": [["game": ["biz": "hk4e_global"], "backgrounds": layers]]]]))
    }
    cdn.serve("a", data: png); cdn.serve("b", data: jpeg)
    try serve("", includeIcon: true)
    let service = GameArtService(cacheDirectory: temp.url.appendingPathComponent("GameArt"), http: cdn, now: { time.withLock { $0 } })
    let first = await service.refresh()
    time.withLock { $0 += 7 * 3600 }; try serve("-broken", includeIcon: true)
    let failed = await service.refresh()
    #expect(failed["genshin"]?.backgrounds.map(\.highlights) == first["genshin"]?.backgrounds.map(\.highlights))
    #expect(failed["genshin"]?.backgrounds.allSatisfy { $0.highlights?.link == nil } == true)
    time.withLock { $0 += 7 * 3600 }; try serve("", includeIcon: false)
    let removed = await service.refresh()
    #expect(removed["genshin"]?.backgrounds.allSatisfy { $0.highlights == nil } == true)
}

@Test
func boundsFitThreeGamesWithEveryBackgroundAsset() async throws {
    let temp = try TempDir(), cdn = MockCDN(); try artFixtures(cdn)
    let games: [[String: Any]] = ["hk4e_global", "hkrpg_global", "nap_global"].map { biz in
        let layers: [[String: Any]] = (0..<(GameArtService.maximumBackgroundsPerGame + 1)).map { n in
            let base = "\(biz)-\(n)"
            func asset(_ suffix: String, video: Bool = false) -> String {
                let name = base + suffix; cdn.serve(name, data: video ? webm : png)
                return "https://fastcdn.hoyoverse.com/" + name
            }
            return ["id": String(n), "type": "BACKGROUND_TYPE_VIDEO", "background": ["url": asset("-still")],
                "video": ["url": asset("-video", video: true)], "theme": ["url": asset("-theme")],
                "icon": ["url": asset("-normal"), "hover_url": asset("-hover"), "link": "https://hoyo.link/\(base)"]]
        }
        return ["game": ["biz": biz], "backgrounds": layers]
    }
    cdn.serve(apiBasic, data: try JSONSerialization.data(withJSONObject: ["data": ["game_info_list": games]]))
    let directory = temp.url.appendingPathComponent("GameArt")
    let art = await GameArtService(cacheDirectory: directory, http: cdn).refresh()
    #expect(art.count == 3)
    for game in art.values {
        #expect(game.backgrounds.count == GameArtService.maximumBackgroundsPerGame)
        #expect(game.backgrounds.allSatisfy { $0.image != nil && $0.video != nil && $0.theme != nil && $0.highlights?.hoverImage != nil })
    }
    let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("art-index.json"))) as? [String: Any])
    let assets = try #require(index["assets"] as? [String: Any])
    #expect(assets.count > 18 && assets.count <= GameArtService.maximumAssets)
    let count = cdn.requestLog.count
    let restored = await GameArtService(cacheDirectory: directory, http: cdn).loadCached()
    #expect(restored == art && cdn.requestLog.count == count)
}

@Test(arguments: ["http://hoyo.link/x", "javascript:alert(1)", "file:///tmp/x", "https:///", "https://user:pass@hoyo.link/x"])
func highlightsBrowserLinksAreValidatedAlsoWhenDecoded(value: String) throws {
    let bytes = try JSONSerialization.data(withJSONObject: ["image": "file:///tmp/icon.png", "link": value])
    #expect(try JSONDecoder().decode(GameHighlights.self, from: bytes).link == nil)
}
