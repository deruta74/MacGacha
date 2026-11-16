// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

/// No cache or network work occurs until export is explicitly called.
public struct WishHistoryExporter: WishHistoryExporting {
    private let log: EventLog?
    private let http: (any HTTPClient)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let deadlineSleep: @Sendable (Duration) async throws -> Void
    public init(http: (any HTTPClient)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        deadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: EventLog? = nil) {
        self.log = log
        self.http = http; self.sleep = sleep; self.now = now; self.deadlineSleep = deadlineSleep
    }

    @concurrent public func export(_ request: WishHistoryRequest,
        progress: @escaping @Sendable (WishHistoryProgress) async -> Void) async throws -> WishHistoryExport {
        do {
            try Task.checkCancellation()
            let link = try await BlockingIO.run { try WishHistoryCache.find(request) }
            let owned: URLSessionHTTPClient?
            if http == nil {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil; configuration.httpCookieStorage = nil
                configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
                owned = URLSessionHTTPClient(configuration: configuration, sessionCount: 1,
                    highWaterMark: 1 << 20, lowWaterMark: 256 << 10, redirectPolicy: { url in
                        guard let host = url.host, url.scheme == "https", host == WishHistoryLink.host(request.game),
                            url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                            url.fragment == nil else { return false }
                        return WishHistoryLink.banners(request.game).contains { WishHistoryLink.path(request.game, banner: $0) == url.path }
                    })
            } else { owned = nil }
            defer { owned?.invalidate() }
            let result = try await collect(request, link: link, http: http ?? owned!, progress: progress)
            log?.post(.info, "wishHistory", "Export completed", metadata: ["count": String(result.totalCount)])
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            if let error = error as? LauncherError {
                switch error {
                case .cancelled, .wishHistoryNoCachedLink, .wishHistoryLinkExpired, .wishHistoryInvalidData: throw error
                default: break
                }
            }
            // Includes URLSession failures, which can embed credentials in NSError.userInfo.
            throw LauncherError.wishHistoryNetwork
        }
    }

    private func collect(_ request: WishHistoryRequest, link: WishHistoryLink, http: any HTTPClient,
        progress: @escaping @Sendable (WishHistoryProgress) async -> Void) async throws -> WishHistoryExport {
        let language = WishLanguage(request.language, cn: request.game.region == .mainlandChina)
        var items: [[String: String]] = [], beyondItems: [[String: String]] = []
        var seen: Set<String> = [], beyondSeen: Set<String> = []
        var uid: String?, timezone: Int?, sentRequest = false
        var receivedBytes = 0
        for banner in WishHistoryLink.banners(request.game) {
            var cursor = "0", cursors: Set<String> = []
            for page in 1...10_000 {
                try Task.checkCancellation()
                if sentRequest { try await sleep(.milliseconds(300)) }
                try Task.checkCancellation()
                await progress(WishHistoryProgress(gameID: request.game.id, banner: banner, page: page, count: items.count + beyondItems.count))
                try Task.checkCancellation()
                let url = link.requestURL(game: request.game, banner: banner, page: page, endID: cursor, language: language.api)
                sentRequest = true
                let bytes = try await fetch(url, http: http)
                receivedBytes += bytes.count
                guard receivedBytes <= 64 << 20 else { throw LauncherError.wishHistoryInvalidData }
                let response: Response
                do { response = try JSONDecoder().decode(Response.self, from: bytes) }
                catch { throw LauncherError.wishHistoryInvalidData }
                if response.retcode != 0 {
                    if [-100, -101, -104].contains(response.retcode)
                        || ["authkey timeout", "authkey error"].contains(response.message ?? "") {
                        throw LauncherError.wishHistoryLinkExpired
                    }
                    throw LauncherError.wishHistoryNetwork
                }
                guard let data = response.data, data.list.count <= WishHistoryLink.pageSize(request.game, banner: banner) else { throw LauncherError.wishHistoryInvalidData }
                if data.list.isEmpty { break }
                let zone = data.region_time_zone ?? Self.timezone(for: data.list[0]["uid"], game: request.game)
                guard let zone, (-12...14).contains(zone), timezone == nil || timezone == zone else { throw LauncherError.wishHistoryInvalidData }
                timezone = zone
                let isBeyond = WishHistoryLink.isBeyond(request.game, banner: banner)
                for var item in data.list {
                    guard let itemUID = item["uid"], Self.numeric(itemUID), uid == nil || uid == itemUID,
                        let id = item["id"], Self.numeric(id), id != "0", id.count <= 19,
                        let time = item["time"], Self.validTime(time), item["item_id"] != nil,
                        item.values.allSatisfy({ $0.utf8.count <= 4_096 }),
                        !item.keys.contains(where: { $0.lowercased() == "authkey" }),
                        item["lang"].map({ $0 == language.uigf }) ?? true else { throw LauncherError.wishHistoryInvalidData }
                    uid = itemUID
                    if isBeyond {
                        guard Self.validBeyond(item) else { throw LauncherError.wishHistoryInvalidData }
                        if beyondSeen.insert(id).inserted { beyondItems.append(item) }
                    } else {
                        guard let type = item["gacha_type"], WishHistoryLink.banners(request.game).contains(type),
                            !WishHistoryLink.isBeyond(request.game, banner: type),
                            request.game.family != .starrail || item["gacha_id"] != nil else { throw LauncherError.wishHistoryInvalidData }
                        if request.game.family == .genshin { item["uigf_gacha_type"] = type == "400" ? "301" : type }
                        if seen.insert(id).inserted { items.append(item) }
                    }
                }
                guard items.count + beyondItems.count <= 100_000, let next = data.list.last?["id"], next != cursor,
                    cursor == "0" || Self.less(next, than: cursor), cursors.insert(next).inserted,
                    page < 10_000 else { throw LauncherError.wishHistoryInvalidData }
                cursor = next
            }
        }
        try Task.checkCancellation()
        let account: Account? = items.isEmpty ? nil : uid.map { Account(uid: $0, timezone: timezone!, lang: language.uigf, list: items) }
        let beyondAccount: Account? = beyondItems.isEmpty ? nil : uid.map { Account(uid: $0, timezone: timezone!, lang: language.uigf, list: beyondItems) }
        let family = request.game.family
        let document = Document(info: Info(export_timestamp: Int64(now().timeIntervalSince1970), export_app_version: request.appVersion),
            hk4e: family == .genshin ? account.map { [$0] } ?? [] : nil,
            hkrpg: family == .starrail ? account.map { [$0] } ?? [] : nil,
            nap: family == .zzz ? account.map { [$0] } ?? [] : nil,
            hk4e_ugc: family == .genshin ? beyondAccount.map { [$0] } ?? [] : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(document)
        guard bytes.count <= 64 << 20 else { throw LauncherError.wishHistoryInvalidData }
        try Task.checkCancellation()
        return WishHistoryExport(data: bytes, countsByGame: [request.game.id: items.count + beyondItems.count])
    }

    private func fetch(_ url: URL, http: any HTTPClient) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let (head, body) = try await http.get(url, byteRangeFrom: nil)
                guard head.status == 200 else {
                    throw head.status == 401 || head.status == 403 ? LauncherError.wishHistoryLinkExpired : .wishHistoryNetwork
                }
                guard head.contentLength.map({ $0 <= 1 << 20 }) ?? true else { throw LauncherError.wishHistoryInvalidData }
                var bytes = Data()
                for try await part in body {
                    try Task.checkCancellation()
                    guard part.count <= (1 << 20) - bytes.count else { throw LauncherError.wishHistoryInvalidData }
                    bytes.append(part)
                }
                return bytes
            }
            group.addTask {
                try await deadlineSleep(.seconds(20))
                throw LauncherError.wishHistoryNetwork
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func validBeyond(_ item: [String: String]) -> Bool {
        guard let schedule = item["schedule_id"], numeric(schedule),
            let itemID = item["item_id"], numeric(itemID),
            let rank = item["rank_type"], numeric(rank),
            item["item_type"] != nil, item["item_name"] != nil,
            let type = item["op_gacha_type"], ["1000", "2000", "20011", "20012", "20021", "20022"].contains(type) else { return false }
        return true
    }
    private static func validTime(_ time: String) -> Bool {
        time.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil
    }
    private static func numeric(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func less(_ value: String, than other: String) -> Bool { value.count == other.count ? value < other : value.count < other.count }
    private static func timezone(for uid: String?, game: GameDefinition) -> Int? {
        if game.region == .mainlandChina { return 8 }
        if game.family == .genshin, let uid, uid.count == 10, uid.hasPrefix("18") { return 8 }
        switch uid?.first {
        case "6": return -5
        case "7": return 1
        case "8", "9": return 8
        default: return nil
        }
    }
    private struct Response: Decodable { let retcode: Int; let message: String?; let data: Page? }
    private struct Page: Decodable {
        let list: [[String: String]]
        let region_time_zone: Int?
        private enum CodingKeys: CodingKey { case list, region_time_zone }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            list = try values.decode([[String: WireString]].self, forKey: .list).map { $0.mapValues(\.value) }
            region_time_zone = try values.decodeIfPresent(Int.self, forKey: .region_time_zone)
        }
    }
    /// Newer endpoints return numeric IDs as JSON integers. Never round them through Double.
    private struct WireString: Decodable {
        let value: String
        init(from decoder: any Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            if let string = try? scalar.decode(String.self) { value = string }
            else if let integer = try? scalar.decode(Int64.self) { value = String(integer) }
            else { value = String(try scalar.decode(UInt64.self)) }
        }
    }
    private struct Info: Encodable {
        let export_timestamp: Int64
        let export_app = "MacGacha"
        let export_app_version: String
        let version = "v4.2"
    }
    private struct Account: Encodable { let uid: String; let timezone: Int; let lang: String; let list: [[String: String]] }
    private struct Document: Encodable { let info: Info; let hk4e: [Account]?; let hkrpg: [Account]?; let nap: [Account]?; let hk4e_ugc: [Account]? }
}

private struct WishLanguage {
    let api: String
    let uigf: String
    init(_ language: String, cn: Bool) {
        let codes = ["de-de": "de", "en-us": "en", "es-es": "es", "fr-fr": "fr", "id-id": "id", "ja-jp": "ja", "ko-kr": "ko", "pt-pt": "pt", "ru-ru": "ru", "th-th": "th", "vi-vn": "vi", "zh-cn": "zh-cn", "zh-tw": "zh-tw"]
        let chosen = cn ? "zh-cn" : codes[language] == nil ? "en-us" : language
        // UIGF's published enum uses vi-vn.
        uigf = chosen; api = codes[chosen]!
    }
}
