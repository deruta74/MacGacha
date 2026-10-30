// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
@testable import HoYoPlayAPI
import TestSupport

@Suite struct GameEventsServiceTests {
    @Test(arguments: [Region.global, .mainlandChina])
    func activityPostsUseEditionIDsAndVerbatimDates(region: Region) async throws {
        let temp = try TempDir(), http = EventsHTTP(region: region)
        let service = GameEventsService(cacheDirectory: temp.url.appendingPathComponent("GameEvents"), region: region, language: .deDE, http: http, now: { eventsFixtureDate })
        let result = await service.refresh()
        let id = region == .global ? "genshin" : "genshin-cn"
        let events = try #require(result[id])
        #expect(events.posts.map(\.title) == ["Sanitized event", "No browser link"])
        #expect(events.posts.map(\.date) == ["10/22", "活动期间"])
        #expect(events.posts[0].link == URL(string: "https://external.example/event"))
        #expect(events.posts[1].link == nil)
        #expect(events.region == region && events.language == (region == .global ? .deDE : .zhCN))
        #expect(http.requests.count == 2)
        for url in http.requests {
            #expect(url.host == region.hypAPIHost)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "launcher_id", value: region.launcherID)))
            #expect(query.contains(URLQueryItem(name: "language", value: region == .global ? "de-de" : "zh-cn")))
        }
        #expect(http.requests.last?.query?.contains("game_id=remote-id") == true)
    }

    @Test func failureKeepsOriginalFetchTimeAndEmptyClearsIncludingOnDisk() async throws {
        let temp = try TempDir(), http = EventsHTTP(), clock = EventsDate()
        let directory = temp.url.appendingPathComponent("GameEvents")
        let service = GameEventsService(cacheDirectory: directory, http: http, now: { clock.now })
        let first = await service.refresh()
        clock.advance(3600)
        http.failContent = true
        #expect(await service.refresh() == first)
        let offline = GameEventsService(cacheDirectory: directory, http: http, now: { clock.now })
        #expect(await offline.loadCached() == first)
        http.failContent = false
        http.content = content([])
        let empty = await service.refresh()
        #expect(empty["genshin"]?.posts == [])
        #expect(empty["genshin"]?.fetchedAt == clock.now)
        let restored = GameEventsService(cacheDirectory: directory, http: http, now: { clock.now })
        #expect(await restored.loadCached() == empty)
    }

    @Test func languagesRegionsAndTTLNeverLeakCachedText() async throws {
        let temp = try TempDir(), clock = EventsDate(), http = EventsHTTP()
        let directory = temp.url.appendingPathComponent("GameEvents")
        let service = GameEventsService(cacheDirectory: directory, http: http, now: { clock.now })
        let first = await service.refresh()
        #expect(!first.isEmpty)
        let german = GameEventsService(cacheDirectory: directory, language: .deDE, http: http, now: { clock.now })
        #expect(await german.loadCached().isEmpty)
        let cn = GameEventsService(cacheDirectory: directory, region: .mainlandChina, http: EventsHTTP(region: .mainlandChina), now: { clock.now })
        #expect(await cn.loadCached().isEmpty)
        #expect(await cn.refresh()["genshin-cn"]?.region == .mainlandChina)
        let restored = GameEventsService(cacheDirectory: directory, http: http, now: { clock.now })
        #expect(await restored.loadCached() == first)
        clock.advance(24 * 3600 - 1)
        #expect(service.cached() == first)
        clock.advance(1)
        #expect(service.cached().isEmpty)
        #expect(await restored.loadCached().isEmpty)
        http.failContent = true
        #expect(await service.refresh().isEmpty)
        clock.advance(-24 * 3600 - 1)
        #expect(service.cached().isEmpty) // A future fetch time is untrusted too.
    }

    @Test(arguments: ["", "http://example.test", "javascript:alert(1)", "file:///tmp/a", "//example.test", "https://user:secret@example.test", "https://"])
    func invalidLinksStayVisibleButNotClickable(link: String) async throws {
        let temp = try TempDir(), http = EventsHTTP()
        http.content = content([["type": "POST_TYPE_ACTIVITY", "title": "Visible", "date": "unchanged", "link": link]])
        let result = await GameEventsService(cacheDirectory: temp.url.appendingPathComponent("Events"), http: http, now: { eventsFixtureDate }).refresh()
        #expect(result["genshin"]?.posts.first?.title == "Visible")
        #expect(result["genshin"]?.posts.first?.link == nil)
        #expect(http.requests.count == 2) // The browser destination is never fetched.
    }

    @Test func boundsLimitPostsTitlesDatesAndRejectOversizedResponses() async throws {
        let temp = try TempDir(), http = EventsHTTP()
        let service = GameEventsService(cacheDirectory: temp.url.appendingPathComponent("Events"), http: http, now: { eventsFixtureDate })
        let post = ["type": "POST_TYPE_ACTIVITY", "title": String(repeating: "原", count: 900), "date": String(repeating: "日", count: 100), "link": "https://external.example"]
        http.content = content(Array(repeating: post, count: 100))
        let first = await service.refresh()
        #expect(first["genshin"]?.posts.count == GameEventsService.postLimit)
        #expect(first["genshin"]?.posts.first?.title.unicodeScalars.count == GameEventsService.titleLimit)
        #expect(first["genshin"]?.posts.first?.date == String(repeating: "日", count: 100))
        http.content = content(Array(repeating: post, count: 257))
        #expect(await service.refresh() == first)
        http.content = Data(repeating: 32, count: (2 << 20) + 1)
        #expect(await service.refresh() == first) // Unknown Content-Length, chunk bound.
        http.advertisedLength = (2 << 20) + 1
        #expect(await service.refresh() == first)
    }

    @Test func redirectPolicyMatchesRegionAndNeverUsesBrowserHosts() {
        for region in Region.allCases {
            #expect(GameEventsService.allowedRedirect(region.hypAPIURL("getGames"), region: region))
            #expect(!GameEventsService.allowedRedirect(URL(string: "https://external.example/event")!, region: region))
            #expect(!GameEventsService.allowedRedirect(URL(string: "http://\(region.hypAPIHost)/")!, region: region))
            #expect(!GameEventsService.allowedRedirect(Region.allCases.first { $0 != region }!.hypAPIURL("getGames"), region: region))
        }
        #expect(GameEventsService.allowedRedirect(URL(string: "https://fastcdn.mihoyo.com/a")!, region: .mainlandChina))
        #expect(!GameEventsService.allowedRedirect(URL(string: "https://sub.fastcdn.mihoyo.com/a")!, region: .mainlandChina))
    }

    @Test(arguments: [Region.global, .mainlandChina])
    func everySupportedEditionUsesItsRemoteIDAndOneFailureIsIndependent(region: Region) async throws {
        let temp = try TempDir(), http = EventsHTTP(region: region), clock = EventsDate()
        let games = GameDefinition.inRegion(region)
        http.games = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["games": games.enumerated().map {
            ["biz": $0.element.biz, "id": "remote-\($0.offset)"]
        }]])
        let service = GameEventsService(cacheDirectory: temp.url.appendingPathComponent("Events"), region: region, http: http, now: { clock.now })
        let first = await service.refresh()
        #expect(Set(first.keys) == Set(games.map(\.id)))
        #expect(http.requests.count == 4)
        let remoteIDs = Set(http.requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "game_id" }?.value })
        #expect(remoteIDs == ["remote-0", "remote-1", "remote-2"])
        clock.advance(60)
        http.failedID = "remote-1"
        http.content = content([])
        let next = await service.refresh()
        #expect(next[games[1].id] == first[games[1].id])
        #expect(next[games[0].id]?.posts == [] && next[games[2].id]?.posts == [])
    }

    @Test func malformedOrRefusedResponsesDoNotClearSuccessfulEvents() async throws {
        let temp = try TempDir(), http = EventsHTTP()
        let service = GameEventsService(cacheDirectory: temp.url.appendingPathComponent("Events"), http: http, now: { eventsFixtureDate })
        let first = await service.refresh()
        for data in [Data("invalid".utf8), Data(#"{"retcode":-1,"data":{"content":{"posts":[]}}}"#.utf8), Data(#"{"retcode":0,"data":{}}"#.utf8)] {
            http.content = data
            #expect(await service.refresh() == first)
        }
        http.games = Data(#"{"retcode":-1,"data":{"games":[]}}"#.utf8)
        #expect(await service.refresh() == first)
    }

    @Test func cacheRejectsForgedRegionLanguageAndSymlinkFiles() async throws {
        let temp = try TempDir(), http = EventsHTTP()
        let fs = try ContainedFileSystem(root: temp.url)
        let directory = temp.url.appendingPathComponent("Events")
        let fetched = eventsFixtureDate
        for entry in [
            GameEventsSnapshot(posts: [], region: .mainlandChina, language: .enUS, fetchedAt: fetched),
            GameEventsSnapshot(posts: [], region: .global, language: .deDE, fetchedAt: fetched)
        ] {
            try fs.createDirectory(at: SafeRelativePath("Events"))
            try fs.writeAtomically(JSONEncoder().encode(["genshin": entry]), to: SafeRelativePath("Events/events-index.json"))
            #expect(await GameEventsService(cacheDirectory: directory, http: http, now: { eventsFixtureDate }).loadCached().isEmpty)
        }
        try fs.removeFile(at: SafeRelativePath("Events/events-index.json"))
        // The target is still inside the temporary root; the leaf symlink itself is forbidden.
        try fs.writeAtomically(Data("{}".utf8), to: SafeRelativePath("other.json"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("events-index.json"), withDestinationURL: temp.url.appendingPathComponent("other.json"))
        #expect(await GameEventsService(cacheDirectory: directory, http: http, now: { eventsFixtureDate }).loadCached().isEmpty)
        #expect(http.requests.isEmpty)
    }

    private func content(_ posts: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["content": ["posts": posts]]])
    }

}

private final class EventsHTTP: HTTPClient, Sendable {
    let region: Region
    private let recorded = Mutex<[URL]>([])
    private let state = Mutex((content: Data?.none, games: Data?.none, fail: false, failedID: String?.none, length: Int64?.none))
    var games: Data? { get { state.withLock { $0.games } } set { state.withLock { $0.games = newValue } } }
    var failedID: String? { get { state.withLock { $0.failedID } } set { state.withLock { $0.failedID = newValue } } }
    var requests: [URL] { recorded.withLock { $0 } }
    var failContent: Bool { get { state.withLock { $0.fail } } set { state.withLock { $0.fail = newValue } } }
    var content: Data? { get { state.withLock { $0.content } } set { state.withLock { $0.content = newValue } } }
    var advertisedLength: Int64? { get { state.withLock { $0.length } } set { state.withLock { $0.length = newValue } } }
    init(region: Region = .global) { self.region = region }
    func get(_ url: URL, byteRangeFrom: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        recorded.withLock { $0.append(url) }
        let state = state.withLock { $0 }
        let data: Data
        if url.lastPathComponent == "getGames" {
            let biz = GameDefinition.inRegion(region)[0].biz
            data = state.games ?? Data(#"{"retcode":0,"data":{"games":[{"id":"remote-id","biz":"\#(biz)"},{"id":"ignore","biz":"unsupported"}]}}"#.utf8)
        } else {
            let gameID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "game_id" }?.value
            if state.fail || (state.failedID != nil && state.failedID == gameID) { throw LauncherError.transport("offline") }
            let fixture = Bundle.module.url(forResource: region == .global ? "global" : "cn", withExtension: "json", subdirectory: "Events")!
            data = try state.content ?? Data(contentsOf: fixture)
        }
        let pending = Mutex<Data?>(data)
        return (HTTPResponseHead(status: 200, contentLength: state.length), HTTPBody(next: { pending.withLock { value in defer { value = nil }; return value } }))
    }
}

private final class EventsDate: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
}

private let eventsFixtureDate = Date(timeIntervalSince1970: 1_800_000_000)
