// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreFoundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import GameLibrary

@Suite(.timeLimit(.minutes(1))) struct WishHistoryTests {
    @Test func preferenceDefaultsOffAndRoundTrips() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), store = GlobalLaunchSettingsStore(paths: AppPaths(root: temp.url))
            #expect(!GlobalLaunchSettings().wishHistoryEnabled)
            #expect(try !JSONDecoder().decode(GlobalLaunchSettings.self, from: Data("{}".utf8)).wishHistoryEnabled)
            var settings = GlobalLaunchSettings(); settings.wishHistoryEnabled = true
            try store.save(settings)
            #expect(try store.load().wishHistoryEnabled)
        }
    }

    @Test(arguments: GameDefinition.all) func everyEditionUsesExactEndpointAndBannerParameters(game: LauncherCore.GameDefinition) async throws {
        let temp = try TempDir(); try await cache(temp.url, game: game)
        let http = WishHTTP { _, _ in Self.page([]) }, sleep = WishSleeps()
        let exporter = WishHistoryExporter(http: http, sleep: { try await sleep.wait($0) })
        let result = try await exporter.export(request(game, root: temp.url)) { _ in }
        let urls = http.urls
        let types = game.family == .genshin ? ["100", "200", "301", "302", "400", "500", "1000", "2000"]
            : game.family == .starrail ? ["1", "2", "11", "12", "21", "22"] : ["1", "2", "3", "5", "102", "103"]
        #expect(urls.count == types.count)
        #expect(Set(urls.compactMap { query($0)[game.family == .zzz ? "real_gacha_type" : "gacha_type"] }) == Set(types))
        for url in urls {
            let type = query(url)["gacha_type"] ?? ""
            let expected = game.family == .genshin ? "/gacha_info/api/" + (["1000", "2000"].contains(type) ? "getBeyondGachaLog" : "getGachaLog")
                : game.family == .starrail ? "/common/hkrpg_gacha_record/api/" + (["21", "22"].contains(type) ? "getLdGachaLog" : "getGachaLog") : "/common/gacha_record/api/getGachaLog"
            #expect(url.path == expected)
            #expect(url.host == host(game)); #expect(query(url)["size"] == (game.family == .genshin && ["1000", "2000"].contains(type) ? "5" : "20"))
            #expect(query(url)["lang"] == (game.region == .mainlandChina ? "zh-cn" : "en"))
            #expect(query(url)["game_biz"] == game.biz)
        }
        #expect(await sleep.durations == Array(repeating: .milliseconds(300), count: urls.count - 1))
        #expect(result.countsByGame == [game.id: 0])
    }

    @Test(arguments: GameDefinition.all.map(\.id), [false, true])
    func officialCachedWebpageLinksAreConvertedToOnlyTheEditionAPI(gameID: String, latest: Bool) async throws {
        let temp = try TempDir(), root = temp.url, game = GameDefinition.find(gameID)!
        let family = game.family == .genshin ? "hk4e" : game.family == .starrail ? "hkrpg" : "nap"
        let event = game.family == .genshin ? (latest ? "e20190909gacha-v3" : "e20190909gacha-v2") : game.family == .starrail ? "e20211215gacha" : "e20230424gacha"
        let pageHost = game.region == .global ? "gs.hoyoverse.com" : "webstatic.mihoyo.com"
        let route = game.region == .global && game.family == .genshin ? "genshin" : family
        let raw = "https://\(pageHost)/\(route)/event/\(event)/index.html?authkey=synthetic&game_biz=\(game.biz)#/log"
        try await BlockingIO.run {
            try writeSyntheticWishCache(ContainedFileSystem(root: root),
                at: SafeRelativePath(game.dataDirectoryName + "/webCaches/1/Cache/Cache_Data"), entries: [.init(key: raw)])
        }
        let http = WishHTTP { _, _ in Self.page([]) }
        _ = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: root)) { _ in }
        #expect(!http.urls.isEmpty); #expect(http.urls.allSatisfy { $0.host == host(game) && $0.fragment == nil })
        #expect(http.urls.allSatisfy { query($0)["authkey_ver"] == "1" && query($0)["sign_type"] == "2" })
    }

    @Test(arguments: ["starrail", "starrail-cn"])
    func currentStarRailCacheAPIPathIsAccepted(gameID: String) throws {
        let game = GameDefinition.find(gameID)!
        let raw = "https://\(host(game))/common/hkrpg_gacha_record/api/getGachaLog?authkey=synthetic&game_biz=\(game.biz)"
        #expect(WishHistoryLink(raw, game: game) != nil)
    }

    @Test func pagesUseStringCursorAndDeduplicateSharedCharacterBanners() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            let q = query(url)
            guard ["301", "400"].contains(q["gacha_type"] ?? "") else { return Self.page([]) }
            if q["end_id"] == "0" { return Self.page([Self.item("9999999999999999999", type: "400")]) }
            return Self.page([])
        }
        let progress = Mutex<[WishHistoryProgress]>([])
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }, now: { Date(timeIntervalSince1970: 42) })
            .export(request(game, root: temp.url)) { value in progress.withLock { $0.append(value) } }
        let json = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let info = try #require(json["info"] as? [String: Any])
        #expect(info["version"] as? String == "v4.2")
        #expect(info["export_timestamp"] as? Int == 42); #expect(info["export_app"] as? String == "MacGacha")
        let accounts = try #require(json["hk4e"] as? [[String: Any]])
        let items = try #require(accounts.first?["list"] as? [[String: String]])
        #expect(items.count == 1); #expect(items.first?["id"] == "9999999999999999999")
        #expect(items.first?["uigf_gacha_type"] == "301"); #expect(result.countsByGame == [game.id: 1])
        #expect(progress.withLock { $0.contains { $0.banner == "301" && $0.page == 2 } })
        #expect(http.urls.contains { query($0)["end_id"] == "9999999999999999999" })
    }

    @Test(arguments: ["expired", "network", "invalid", "repeat", "uid", "oversized"])
    func failuresAreTypedAndContainNoPayload(kind: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find("starrail")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { _, index in
            switch kind {
            case "expired": return Data(#"{"retcode":-101,"message":"authkey timeout"}"#.utf8)
            case "network": throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://synthetic.invalid/private")!])
            case "invalid": return Data("SYNTHETIC_PRIVATE".utf8)
            case "oversized": return Data(repeating: 65, count: (1 << 20) + 1)
            case "uid": return Self.page([Self.item(index == 0 ? "100" : "99", uid: index == 0 ? "800000001" : "800000002")])
            default: return Self.page([Self.item("100")])
            }
        }
        let expected: LauncherError = kind == "expired" ? .wishHistoryLinkExpired : kind == "network" ? .wishHistoryNetwork : .wishHistoryInvalidData
        await #expect(throws: expected) {
            try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        }
    }

    @Test func cacheSelectsIndexedLinksAndRefusesWrongEditionAndSymlinks() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game, suffix: "\u{0}https://public-operation-hk4e.mihoyo.com/gacha_info/api/getGachaLog?authkey=synthetic\u{0}https://attacker.invalid/gacha_info/api/getGachaLog?authkey=synthetic")
        let http = WishHTTP { _, _ in Self.page([]) }
        _ = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        #expect(http.urls.allSatisfy { $0.host == host(game) })
        let unsafe = try TempDir(), unsafeRoot = unsafe.url, target = temp.url.path
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: unsafeRoot)
            try fs.createSymbolicLink(at: SafeRelativePath(game.dataDirectoryName), target: target)
        }
        await #expect(throws: LauncherError.wishHistoryNoCachedLink) {
            try await WishHistoryExporter(http: http).export(request(game, root: unsafe.url)) { _ in }
        }
    }

    @Test func cancellationDuringPacingMakesNoNextRequest() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let entered = TestEvent(), http = WishHTTP { _, _ in Self.page([]) }
        let task = Task {
            try await WishHistoryExporter(http: http, sleep: { _ in
                entered.signal()
                try await Task.sleep(for: .seconds(3600))
            }).export(request(game, root: temp.url)) { _ in }
        }
        try await entered.wait(); task.cancel()
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(http.urls.count == 1)
    }

    @Test(arguments: ["http", "suffix", "port", "user", "edition", "path", "duplicate"])
    func untrustedLinksAreRejectedWithoutMakingRequests(kind: String) throws {
        let game = GameDefinition.find("genshin")!
        let base = "https://public-operation-hk4e-sg.hoyoverse.com/gacha_info/api/getGachaLog?authkey=synthetic&game_biz=hk4e_global"
        let raw: String
        switch kind {
        case "http": raw = base.replacingOccurrences(of: "https:", with: "http:")
        case "suffix": raw = base.replacingOccurrences(of: ".com/", with: ".com.attacker.invalid/")
        case "port": raw = base.replacingOccurrences(of: ".com/", with: ".com:444/")
        case "user": raw = base.replacingOccurrences(of: "https://", with: "https://user@")
        case "edition": raw = base.replacingOccurrences(of: "hk4e_global", with: "hk4e_cn")
        case "path": raw = base.replacingOccurrences(of: "getGachaLog", with: "other")
        default: raw = base + "&authkey=duplicate"
        }
        #expect(WishHistoryLink(raw, game: game) == nil)
        let link = try #require(WishHistoryLink(base, game: game))
        #expect(String(reflecting: link) == "WishHistoryLink(redacted)")
        #expect(Mirror(reflecting: link).children.isEmpty)
    }

    @Test func emptyOrOversizedCacheDoesNotCallHTTP() async throws {
        for oversized in [false, true] {
            let temp = try TempDir(), root = temp.url, game = GameDefinition.find("genshin")!
            if oversized {
                try await BlockingIO.run {
                    try ContainedFileSystem(root: root).writeAtomically(Data(repeating: 0, count: (16 << 20) + 1),
                        to: SafeRelativePath(game.dataDirectoryName + "/webCaches/1/Cache/Cache_Data/data_2"))
                }
            }
            let http = WishHTTP { _, _ in Self.page([]) }
            await #expect(throws: LauncherError.wishHistoryNoCachedLink) {
                try await WishHistoryExporter(http: http).export(request(game, root: root)) { _ in }
            }
            #expect(http.urls.isEmpty)
        }
    }

    @Test(arguments: ["starrail", "starrail-cn"])
    func collaborationWarpsExportEveryPoolInV42(gameID: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find(gameID)!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            let q = query(url), type = q["gacha_type"]!
            guard q["end_id"] == "0" else { return Self.page([]) }
            var item = Self.item("90000000000000000" + type, type: type)
            item["lang"] = game.region == .global ? "en-us" : "zh-cn"
            item["new_api_field"] = "preserved"
            return Self.page([item])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let document = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let items = try #require((document["hkrpg"] as? [[String: Any]])?.first?["list"] as? [[String: String]])
        #expect(Set(items.compactMap { $0["gacha_type"] }) == Set(["1", "2", "11", "12", "21", "22"]))
        #expect(items.allSatisfy { $0["new_api_field"] == "preserved" })
        #expect(result.totalCount == 6)
        try await expectV42Schema(document)
    }

    @Test(arguments: ["genshin", "genshin-cn"], [false, true])
    func miliastraPoolsExportSeparatelyWithoutLosingOverlappingIDs(gameID: String, beyondLink: Bool) async throws {
        let temp = try TempDir(), root = temp.url, game = GameDefinition.find(gameID)!
        try await cache(root, game: game)
        if beyondLink {
            let route = game.region == .global ? "https://gs.hoyoverse.com/genshin" : "https://webstatic.mihoyo.com/hk4e"
            let raw = route + "/event/e20250716gacha/index.html?authkey=synthetic&game_biz=" + game.biz + "#/log"
            try await BlockingIO.run {
                try writeSyntheticWishCache(ContainedFileSystem(root: root),
                    at: SafeRelativePath(game.dataDirectoryName + "/webCaches/2.57.0.0/Cache/Cache_Data"), entries: [.init(key: raw)])
            }
        }
        let http = WishHTTP { url, _ in
            let q = query(url)
            guard q["end_id"] == "0" else { return Self.page([]) }
            let type = q["gacha_type"]!
            if type == "100" {
                var item = Self.item("100", type: type); item["lang"] = game.region == .global ? "en-us" : "zh-cn"
                return Self.page([item])
            }
            guard ["1000", "2000"].contains(type) else { return Self.page([]) }
            #expect(url.path == "/gacha_info/api/getBeyondGachaLog")
            #expect(q["size"] == "5")
            let ops = type == "1000" ? ["1000"] : ["2000", "20011", "20012", "20021", "20022"]
            let records: [[String: Any]] = ops.enumerated().map { index, op in
                ["uid": 800000001, "id": type == "1000" ? 100 : 200 - index, "op_gacha_type": Int(op)!,
                    "schedule_id": 1, "item_type": "Avatar", "item_id": 1001, "item_name": "Synthetic avatar",
                    "rank_type": 5, "time": "2026-11-15 12:00:00", "region": "os_asia", "is_up": 1]
            }
            return try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["list": records]])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: root)) { _ in }
        let document = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let ordinary = try #require((document["hk4e"] as? [[String: Any]])?.first?["list"] as? [[String: String]])
        let beyond = try #require((document["hk4e_ugc"] as? [[String: Any]])?.first?["list"] as? [[String: String]])
        #expect(ordinary.count == 1); #expect(beyond.count == 6); #expect(result.countsByGame == [game.id: 7])
        #expect(ordinary.first?["id"] == "100"); #expect(beyond.first?["id"] == "100")
        #expect(Set(beyond.compactMap { $0["op_gacha_type"] }) == Set(["1000", "2000", "20011", "20012", "20021", "20022"]))
        #expect(beyond.allSatisfy { $0["time"] == "2026-11-15 12:00:00" })
        #expect(http.urls.contains { $0.path.hasSuffix("getBeyondGachaLog") && query($0)["end_id"] == "196" })
        try await expectV42Schema(document)
    }

    @Test(arguments: ["schedule", "time", "id", "item", "op", "rank"])
    func malformedMiliastraRecordsFailWithInvalidData(kind: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            guard query(url)["gacha_type"] == "1000" else { return Self.page([]) }
            var item = ["uid": "800000001", "id": "100", "op_gacha_type": "1000", "schedule_id": "1",
                "item_type": "Avatar", "item_id": "1001", "item_name": "Synthetic", "rank_type": "5", "time": "2026-11-15 12:00:00"]
            switch kind {
            case "schedule": item["schedule_id"] = ""
            case "time": item["time"] = "2026-11-15T12:00:00Z"
            case "id": item["id"] = "12345678901234567890"
            case "item": item["item_name"] = nil
            case "op": item["op_gacha_type"] = "invalid"
            default: item["rank_type"] = "-1"
            }
            return Self.page([item])
        }
        await #expect(throws: LauncherError.wishHistoryInvalidData) {
            try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        }
    }

    @Test func beyondOnlyHistoryHasItsOwnArchiveAndCounts() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            guard query(url)["gacha_type"] == "1000", query(url)["end_id"] == "0" else { return Self.page([]) }
            return Self.page([Self.beyondItem()])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let document = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect((document["hk4e"] as? [Any])?.isEmpty == true)
        #expect(result.countsByGame == [game.id: 1])
        try await expectV42Schema(document)
    }

    @Test func beyondCannotMixAnotherAccountWithOrdinaryWishes() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            guard query(url)["end_id"] == "0" else { return Self.page([]) }
            if query(url)["gacha_type"] == "100" { return Self.page([Self.item("100", type: "100")]) }
            if query(url)["gacha_type"] == "1000" {
                var item = Self.beyondItem(); item["uid"] = "800000002"
                return Self.page([item])
            }
            return Self.page([])
        }
        await #expect(throws: LauncherError.wishHistoryInvalidData) {
            try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        }
    }

    @Test func cancellationAtBeyondProgressStartsNoBeyondRequest() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let entered = TestEvent(), never = TestEvent(), http = WishHTTP { _, _ in Self.page([]) }
        let task = Task {
            try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { value in
                if value.banner == "1000" { entered.signal(); try? await never.wait() }
            }
        }
        try await entered.wait(); task.cancel()
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(http.urls.count == 6)
        #expect(!http.urls.contains { $0.path.hasSuffix("getBeyondGachaLog") })
    }

    @Test(arguments: [UInt64(9_007_199_254_740_993), UInt64(9_223_372_036_854_775_808)])
    func numericWireIDsRemainExactBeyondFloatingPointAndSignedBounds(id: UInt64) async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            guard query(url)["gacha_type"] == "1000", query(url)["end_id"] == "0" else { return Self.page([]) }
            var item: [String: Any] = Self.beyondItem(); item["id"] = NSNumber(value: id)
            return try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["list": [item]]])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let document = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let items = try #require((document["hk4e_ugc"] as? [[String: Any]])?.first?["list"] as? [[String: String]])
        #expect(items.first?["id"] == String(id))
        #expect(http.urls.contains { query($0)["end_id"] == String(id) })
        try await expectV42Schema(document)
    }

    @Test(arguments: ["genshin", "starrail", "zzz"], ["id", "time"])
    func ordinaryRecordsMeetCurrentIdAndTimeConstraints(gameID: String, kind: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find(gameID)!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            let q = query(url), first = game.family == .genshin ? "100" : "1"
            guard q["end_id"] == "0", (q["gacha_type"] ?? q["real_gacha_type"]) == first else { return Self.page([]) }
            var item = Self.item("100", type: first)
            item[kind] = kind == "id" ? "12345678901234567890" : "2026-11-15T12:00:00Z"
            return Self.page([item])
        }
        await #expect(throws: LauncherError.wishHistoryInvalidData) {
            try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        }
    }

    @Test(arguments: ["zzz", "zzz-cn"])
    func currentZZZPoolsPreserveAllRawTypesAndExposePublishedEnumGap(gameID: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find(gameID)!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            let q = query(url)
            guard q["end_id"] == "0", let type = q["real_gacha_type"] else { return Self.page([]) }
            var item = Self.item("9000000000000000" + type, type: type)
            item["lang"] = game.region == .global ? "en-us" : "zh-cn"
            return Self.page([item])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let document = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let items = try #require((document["nap"] as? [[String: Any]])?.first?["list"] as? [[String: String]])
        #expect(Set(items.compactMap { $0["gacha_type"] }) == Set(["1", "2", "3", "5", "102", "103"]))
        #expect(result.totalCount == 6)
        let schemaURL = try #require(Bundle.module.url(forResource: "uigf-v4.2.schema", withExtension: "json", subdirectory: "WishHistory"))
        let bytes = try await BlockingIO.run { try ContainedFileSystem(root: schemaURL.deletingLastPathComponent()).readFile(at: SafeRelativePath(schemaURL.lastPathComponent), maxBytes: 65_536) }
        var schema = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(!schemaAccepts(document, schema: schema))
        // The fixture stays unchanged. Overlay only the two missing enum members,
        // proving every other published constraint holds for the complete export.
        var properties = schema["properties"] as! [String: [String: Any]]
        var nap = properties["nap"]!, account = nap["items"] as! [String: Any]
        var accountProperties = account["properties"] as! [String: [String: Any]]
        var list = accountProperties["list"]!, record = list["items"] as! [String: Any]
        var fields = record["properties"] as! [String: [String: Any]]
        fields["gacha_type"]!["enum"] = ["1", "2", "3", "5", "102", "103"]
        record["properties"] = fields; list["items"] = record; accountProperties["list"] = list
        account["properties"] = accountProperties; nap["items"] = account; properties["nap"] = nap; schema["properties"] = properties
        #expect(schemaAccepts(document, schema: schema))
        #expect((document["info"] as? [String: Any])?["version"] as? String == "v4.2")
    }

    @Test(arguments: [("600000001", -5), ("700000001", 1), ("800000001", 8), ("900000001", 8), ("1800000000", 8)])
    func genshinInfersTimezoneWhenAPIOnlyReturnsList(uid: String, expectedZone: Int) async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            let first = query(url)["gacha_type"] == "100" && query(url)["end_id"] == "0"
            return try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["list": first ? [Self.item("100", type: "100", uid: uid)] : []]])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let json = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let account = try #require((json["hk4e"] as? [[String: Any]])?.first)
        #expect(account["timezone"] as? Int == expectedZone)
    }

    @Test func completionEventContainsCountsOnly() async throws {
        let temp = try TempDir(), logs = try TempDir(), root = logs.url, game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let log = EventLog(directory: root.appendingPathComponent("logs")), http = WishHTTP { _, _ in Self.page([]) }
        _ = try await WishHistoryExporter(http: http, sleep: { _ in }, log: log).export(request(game, root: temp.url)) { _ in }
        await log.flush()
        let records = try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: root)
            return try fs.contentsOfDirectory(at: SafeRelativePath("logs")).map { try fs.readFile(at: $0, maxBytes: 65_536) }
        }
        #expect(records.count == 1)
        let text = String(decoding: records.flatMap { $0 }, as: UTF8.self)
        #expect(text.contains("count")); #expect(!text.contains("synthetic")); #expect(!text.contains("authkey"))
    }

    @Test func deadlineCancelsBodyAndNeverExposesTransportPayload() async throws {
        let temp = try TempDir(), game = GameDefinition.find("genshin")!
        try await cache(temp.url, game: game)
        let http = HangingWishHTTP()
        await #expect(throws: LauncherError.wishHistoryNetwork) {
            try await WishHistoryExporter(http: http, deadlineSleep: { _ in try await http.entered.wait() })
                .export(request(game, root: temp.url)) { _ in }
        }
        #expect(http.cancelled.withLock { $0 })
    }

    @Test(arguments: ["genshin", "starrail", "zzz"])
    func exportedBytesConformToPublishedSchema(gameID: String) async throws {
        let temp = try TempDir(), game = GameDefinition.find(gameID)!
        try await cache(temp.url, game: game)
        let http = WishHTTP { url, _ in
            query(url)["end_id"] == "0" && (query(url)["gacha_type"] ?? query(url)["real_gacha_type"]) == (game.family == .genshin ? "100" : "1")
                ? Self.page([Self.item("9000000000000000001", type: game.family == .genshin ? "100" : "1")]) : Self.page([])
        }
        let result = try await WishHistoryExporter(http: http, sleep: { _ in }).export(request(game, root: temp.url)) { _ in }
        let schemaURL = try #require(Bundle.module.url(forResource: "uigf-v4.2.schema", withExtension: "json", subdirectory: "WishHistory"))
        let schemaBytes = try await BlockingIO.run { try ContainedFileSystem(root: schemaURL.deletingLastPathComponent()).readFile(at: SafeRelativePath(schemaURL.lastPathComponent), maxBytes: 65_536) }
        let schema = try #require(JSONSerialization.jsonObject(with: schemaBytes) as? [String: Any])
        let document = try JSONSerialization.jsonObject(with: result.data)
        #expect(schemaAccepts(document, schema: schema))
        #expect(!schemaAccepts(["info": ["version": 4]], schema: schema))
    }

    static func beyondItem() -> [String: String] {
        ["uid": "800000001", "id": "100", "op_gacha_type": "1000", "schedule_id": "1",
            "item_type": "Avatar", "item_id": "1001", "item_name": "Synthetic", "rank_type": "5", "time": "2026-11-15 12:00:00"]
    }
    static func item(_ id: String, type: String = "1", uid: String = "800000001") -> [String: String] {
        ["uid": uid, "id": id, "gacha_type": type, "gacha_id": "200", "item_id": "1001", "time": "2026-11-15 12:00:00", "lang": "en-us", "name": "Synthetic item", "count": "1", "item_type": "Character", "rank_type": "3"]
    }
    static func page(_ items: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["region_time_zone": 8, "list": items]])
    }
}

private func host(_ game: LauncherCore.GameDefinition) -> String {
    let biz = game.family == .genshin ? "hk4e" : game.family == .starrail ? "hkrpg" : "nap"
    return "public-operation-\(biz)" + (game.region == .global ? "-sg.hoyoverse.com" : ".mihoyo.com")
}
private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
private func request(_ game: GameDefinition, root: URL) -> WishHistoryRequest {
    WishHistoryRequest(game: game, installRoot: root, language: "en-us", appVersion: "0.3.1")
}
private func cache(_ root: URL, game: GameDefinition, suffix: String = "") async throws {
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: root)
        let url = "https://\(host(game))/\(game.family == .genshin ? "gacha_info" : "common/gacha_record")/api/getGachaLog?authkey=synthetic%2Btoken%3D&authkey_ver=1&sign_type=2&game_biz=\(game.biz)"
        let keys = (url + suffix).split(separator: "\u{0}").map(String.init)
        let entries = keys.enumerated().map { index, key in
            SyntheticWishCacheEntry(key: key, created: UInt64(index + 1), used: UInt64(index + 1), keyBlock: index * 4)
        }
        try writeSyntheticWishCache(fs, at: SafeRelativePath(game.dataDirectoryName + "/webCaches/2.57.0.0/Cache/Cache_Data"), entries: entries)
    }
}
private final class WishHTTP: HTTPClient, Sendable {
    private let state = Mutex<[URL]>([])
    private let respond: @Sendable (URL, Int) throws -> Data
    init(_ respond: @escaping @Sendable (URL, Int) throws -> Data) { self.respond = respond }
    var urls: [URL] { state.withLock { $0 } }
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { try await get(url, byteRangeFrom: nil) }
    func get(_ url: URL, byteRangeFrom: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let index = state.withLock { let index = $0.count; $0.append(url); return index }
        let data = try respond(url, index), bytes = Mutex<Data?>(data)
        return (HTTPResponseHead(status: 200, contentLength: Int64(data.count)), HTTPBody(next: { bytes.withLock { let data = $0; $0 = nil; return data } }))
    }
}
private actor WishSleeps {
    var durations: [Duration] = []
    func wait(_ duration: Duration) async throws { durations.append(duration) }
}

private func expectV42Schema(_ document: [String: Any]) async throws {
    let schemaURL = try #require(Bundle.module.url(forResource: "uigf-v4.2.schema", withExtension: "json", subdirectory: "WishHistory"))
    let bytes = try await BlockingIO.run { try ContainedFileSystem(root: schemaURL.deletingLastPathComponent()).readFile(at: SafeRelativePath(schemaURL.lastPathComponent), maxBytes: 65_536) }
    let schema = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(schemaAccepts(document, schema: schema))
    #expect((document["info"] as? [String: Any])?["version"] as? String == "v4.2")
    // The published UGC array places account properties beside type, omitting items.
    // Keep the fixture intact and additionally validate the intended account shape.
    if let accounts = document["hk4e_ugc"] as? [[String: Any]] {
        var accountSchema = try #require(schema["properties"] as? [String: [String: Any]])["hk4e_ugc"]!
        accountSchema["type"] = "object"
        for account in accounts { #expect(schemaAccepts(account, schema: accountSchema)) }
        #expect(!schemaAccepts(["uid": "800000001", "timezone": 8, "list": [["id": "invalid"]]], schema: accountSchema))
    }
}

// Evaluates every assertion keyword used by the unmodified published fixture.
private func schemaAccepts(_ value: Any, schema: [String: Any]) -> Bool {
    if let choices = schema["oneOf"] as? [[String: Any]], choices.filter({ schemaAccepts(value, schema: $0) }).count != 1 { return false }
    if let choices = schema["enum"] as? [String], !choices.contains(value as? String ?? "") { return false }
    if let pattern = schema["pattern"] as? String {
        guard let string = value as? String, string.range(of: pattern, options: .regularExpression) != nil else { return false }
    }
    if let string = value as? String {
        if let minimum = schema["minLength"] as? Int, string.unicodeScalars.count < minimum { return false }
        if let maximum = schema["maxLength"] as? Int, string.unicodeScalars.count > maximum { return false }
    }
    switch schema["type"] as? String {
    case "object":
        guard let object = value as? [String: Any] else { return false }
        if let required = schema["required"] as? [String], !required.allSatisfy({ object[$0] != nil }) { return false }
        if let properties = schema["properties"] as? [String: [String: Any]] {
            for (key, childSchema) in properties {
                if let child = object[key], !schemaAccepts(child, schema: childSchema) { return false }
            }
        }
    case "array":
        guard let array = value as? [Any] else { return false }
        if let itemSchema = schema["items"] as? [String: Any], !array.allSatisfy({ schemaAccepts($0, schema: itemSchema) }) { return false }
    case "string": if !(value is String) { return false }
    case "integer":
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue else { return false }
    case nil: break
    default: return false
    }
    return true
}

private final class HangingWishHTTP: HTTPClient, Sendable {
    let entered = TestEvent(), never = TestEvent(), cancelled = Mutex(false)
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { try await get(url, byteRangeFrom: nil) }
    func get(_ url: URL, byteRangeFrom: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        (HTTPResponseHead(status: 200), HTTPBody(next: { [self] in
            entered.signal(); try await never.wait(); return nil
        }, onCancel: { [self] in cancelled.withLock { $0 = true } }))
    }
}
