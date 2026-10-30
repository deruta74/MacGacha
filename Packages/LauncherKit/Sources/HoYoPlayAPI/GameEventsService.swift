// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

/// HoYoPlay's date is display text, not an event deadline. Links are browser-only.
public struct GameEvent: Codable, Equatable, Sendable {
    public let title: String
    public let date: String
    public let link: URL?

    public init(title: String, date: String, link: URL?) {
        self.title = title; self.date = date
        self.link = link.flatMap { GameEventsService.browserLink($0.absoluteString) }
    }
}

public struct GameEventsSnapshot: Codable, Equatable, Sendable {
    public let posts: [GameEvent]
    public let region: Region
    public let language: HoYoPlayLanguage
    public let fetchedAt: Date
    public var expiresAt: Date { fetchedAt.addingTimeInterval(24 * 3600) }

    public init(posts: [GameEvent], region: Region, language: HoYoPlayLanguage, fetchedAt: Date) {
        self.posts = posts; self.region = region; self.language = language; self.fetchedAt = fetchedAt
    }

    public func isFresh(at date: Date) -> Bool { fetchedAt <= date && date < expiresAt }
}

/// Independent from the art index and asset pruning. Supply its own cache root
/// (a sibling of GameArt); CN uses a contained `cn` subdirectory just like art.
public actor GameEventsService {
    private static let responseLimit = 2 << 20
    private static let indexLimit = 1 << 20
    public static let postLimit = 20
    public static let titleLimit = 512 // Unicode scalars, at most 2048 UTF-8 bytes.
    private let directory: URL
    private let region: Region
    private let language: HoYoPlayLanguage
    private let http: any HTTPClient
    private let ownedHTTP: EventsHTTPSession?
    private let requestTimeout: Duration
    private nonisolated let snapshot = Mutex<[String: GameEventsSnapshot]>([:])
    private nonisolated let currentDate: @Sendable () -> Date
    private var hydrated = false
    private var flight: (id: UUID, task: Task<[String: GameEventsSnapshot], Never>)?

    public init(cacheDirectory: URL, region: Region = .global, language: HoYoPlayLanguage = .enUS,
        http: (any HTTPClient)? = nil, now: @escaping @Sendable () -> Date = Date.init,
        requestTimeout: Duration = .seconds(30)) {
        directory = region == .global ? cacheDirectory : cacheDirectory.appendingPathComponent(region.rawValue, isDirectory: true)
        self.region = region; self.language = region == .mainlandChina ? .zhCN : language
        currentDate = now; self.requestTimeout = requestTimeout
        if let http { self.http = http; ownedHTTP = nil }
        else { let session = EventsHTTPSession(region: region); ownedHTTP = session; self.http = session.client }
    }

    /// Memory-only and TTL-filtered on every read, including after failed requests.
    public nonisolated func cached() -> [String: GameEventsSnapshot] {
        let date = currentDate()
        return snapshot.withLock { $0.filter { $0.value.isFresh(at: date) } }
    }

    public func loadCached() async -> [String: GameEventsSnapshot] {
        guard !hydrated, directory.isFileURL, !Task.isCancelled else { return cached() }
        do {
            let fs = try ContainedFileSystem(root: directory.deletingLastPathComponent())
            hydrate(fs, root: try SafeRelativePath(directory.lastPathComponent))
        } catch { }
        return cached()
    }

    public func refresh() async -> [String: GameEventsSnapshot] {
        guard !Task.isCancelled else { return cached() }
        let current: (id: UUID, task: Task<[String: GameEventsSnapshot], Never>)
        if let flight { current = flight }
        else { current = (UUID(), Task { await self.update() }); flight = current }
        let result = await withTaskCancellationHandler { await current.task.value } onCancel: { current.task.cancel() }
        if flight?.id == current.id { flight = nil }
        return result
    }

    private func hydrate(_ fs: ContainedFileSystem, root: SafeRelativePath) {
        guard !hydrated else { return }
        hydrated = true
        guard let data = try? fs.readFile(at: SafeRelativePath("\(root)/events-index.json"), maxBytes: Self.indexLimit),
            let saved = try? JSONDecoder().decode([String: GameEventsSnapshot].self, from: data), saved.count <= 3 else { return }
        let valid = saved.filter { id, entry in
            GameDefinition.find(id)?.region == region && entry.region == region && entry.language == language
                && entry.fetchedAt.timeIntervalSinceReferenceDate.isFinite && entry.posts.count <= Self.postLimit
                && entry.posts.allSatisfy { post in
                    post.title.unicodeScalars.count <= Self.titleLimit && post.date.unicodeScalars.count <= 128
                        && (post.link == nil || post.link.flatMap { Self.browserLink($0.absoluteString) } != nil)
                }
        }
        snapshot.withLock { $0 = valid }
    }

    private func update() async -> [String: GameEventsSnapshot] {
        do {
            guard directory.isFileURL, requestTimeout > .zero else { return cached() }
            let fs = try ContainedFileSystem(root: directory.deletingLastPathComponent())
            let root = try SafeRelativePath(directory.lastPathComponent)
            try fs.createDirectory(at: root)
            hydrate(fs, root: root)
            let games = try JSONDecoder().decode(EventsEnvelope<EventsGames>.self,
                from: await json(Self.apiURL("getGames", region: region, language: language)))
            guard games.retcode == 0, games.data.games.count <= 100 else { return cached() }
            let registry = Dictionary(uniqueKeysWithValues: GameDefinition.inRegion(region).map { ($0.biz, $0.id) })
            var requested: [String: String] = [:]
            for game in games.data.games {
                guard let id = registry[game.biz], !game.id.isEmpty, game.id.utf8.count <= 128 else { continue }
                requested[id] = game.id
            }
            for (id, remoteID) in requested.sorted(by: { $0.key < $1.key }) {
                do {
                    let data = try await json(Self.apiURL("getGameContent", region: region, language: language, gameID: remoteID))
                    let posts = try Self.parse(data)
                    try Task.checkCancellation()
                    let entry = GameEventsSnapshot(posts: posts, region: region, language: language, fetchedAt: currentDate())
                    var next = snapshot.withLock { $0 }; next[id] = entry
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let bytes = try encoder.encode(next)
                    guard bytes.count <= Self.indexLimit else { continue }
                    try fs.writeAtomically(bytes, to: SafeRelativePath("\(root)/events-index.json"))
                    snapshot.withLock { $0 = next }
                } catch { /* Keep this game's previous successful result, including its original expiry. */ }
                if Task.isCancelled { break }
            }
        } catch { }
        return cached()
    }

    private func json(_ url: URL) async throws -> Data {
        let http = http, timeout = requestTimeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (head, body) = try await http.get(url, byteRangeFrom: nil)
                guard head.status == 200, head.contentLength.map({ $0 >= 0 && $0 <= Self.responseLimit }) ?? true
                    else { throw LauncherError.transport("Invalid events response") }
                var data = Data()
                for try await piece in body {
                    try Task.checkCancellation()
                    guard piece.count <= Self.responseLimit - data.count else { throw LauncherError.transport("Events response exceeds size limit") }
                    data.append(piece)
                }
                return data
            }
            group.addTask { try await Task.sleep(for: timeout); throw LauncherError.transport("Events request timed out") }
            defer { group.cancelAll() }
            guard let data = try await group.next() else { throw LauncherError.cancelled }
            return data
        }
    }

    private static func parse(_ data: Data) throws -> [GameEvent] {
        let response = try JSONDecoder().decode(EventsEnvelope<EventsContent>.self, from: data)
        guard response.retcode == 0, response.data.content.posts.count <= 256 else { throw LauncherError.io("Invalid events response") }
        return try response.data.content.posts.lazy.filter { $0.type == "POST_TYPE_ACTIVITY" }.prefix(postLimit).map {
            guard $0.date.unicodeScalars.count <= 128 else { throw LauncherError.io("Invalid events date length") }
            return GameEvent(title: String($0.title.unicodeScalars.prefix(titleLimit)),
                date: $0.date, link: $0.link.flatMap(browserLink))
        }
    }

    static func apiURL(_ endpoint: String, region: Region, language: HoYoPlayLanguage, gameID: String? = nil) -> URL {
        var url = URLComponents(url: region.hypAPIURL(endpoint), resolvingAgainstBaseURL: false)!
        url.queryItems?.append(URLQueryItem(name: "language", value: region == .mainlandChina ? "zh-cn" : language.rawValue))
        if let gameID { url.queryItems?.append(URLQueryItem(name: "game_id", value: gameID)) }
        return url.url!
    }

    static func browserLink(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, let url = URL(string: text), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func allowedRedirect(_ url: URL, region: Region) -> Bool {
        guard browserLink(url.absoluteString) != nil, let host = url.host?.lowercased() else { return false }
        if host == region.hypAPIHost { return true }
        switch region {
        case .global: return region.artDomains.contains { host.hasSuffix("." + $0) }
        case .mainlandChina: return region.artDomains.contains(host)
        }
    }
}

private struct EventsEnvelope<T: Decodable>: Decodable { let retcode: Int; let data: T }
private struct EventsGames: Decodable { let games: [EventsGame] }
private struct EventsGame: Decodable { let id: String; let biz: String }
private struct EventsContent: Decodable { let content: EventsPosts }
private struct EventsPosts: Decodable { let posts: [EventsPost] }
private struct EventsPost: Decodable { let type: String; let title: String; let date: String; let link: String? }
private final class EventsHTTPSession: Sendable {
    let client: URLSessionHTTPClient
    init(region: Region) { client = URLSessionHTTPClient(redirectPolicy: { GameEventsService.allowedRedirect($0, region: region) }) }
    deinit { client.invalidate() }
}
