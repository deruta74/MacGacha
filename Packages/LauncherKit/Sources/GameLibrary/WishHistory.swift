// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct WishHistoryRequest: Sendable {
    public let game: GameDefinition
    public let installRoot: URL
    public let installIdentity: FileSystemIdentity?
    public let language: String
    public let appVersion: String
    public init(game: GameDefinition, installRoot: URL, installIdentity: FileSystemIdentity? = nil,
        language: String, appVersion: String) {
        self.game = game; self.installRoot = installRoot; self.installIdentity = installIdentity
        self.language = language; self.appVersion = appVersion
    }
}

public struct WishHistoryProgress: Sendable, Equatable {
    public let gameID: String
    public let banner: String
    public let page: Int
    public let count: Int
    public init(gameID: String, banner: String, page: Int, count: Int) {
        self.gameID = gameID; self.banner = banner; self.page = page; self.count = count
    }
}

/// Private account data, returned only to the caller's save panel. Never log it.
public struct WishHistoryExport: Sendable {
    public let data: Data
    public let countsByGame: [String: Int]
    public var totalCount: Int { countsByGame.values.reduce(0, +) }
    public var suggestedFilename: String { "MacGacha-wish-history.json" }
    public init(data: Data, countsByGame: [String: Int]) { self.data = data; self.countsByGame = countsByGame }
}

public protocol WishHistoryExporting: Sendable {
    func export(_ request: WishHistoryRequest,
        progress: @escaping @Sendable (WishHistoryProgress) async -> Void) async throws -> WishHistoryExport
}

/// Query credentials deliberately have no printable or reflected representation.
struct WishHistoryLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let credentials: [URLQueryItem]
    var description: String { "WishHistoryLink(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    init?(_ raw: String, game: GameDefinition) {
        guard raw.utf8.count <= 16_384, let url = URLComponents(string: raw),
            url.scheme == "https", url.port == nil || url.port == 443,
            url.user == nil, url.password == nil, let items = url.queryItems else { return nil }
        var apiPaths = Self.banners(game).map { Self.path(game, banner: $0) }
        if game.family == .starrail {
            apiPaths += ["/common/gacha_record/api/getGachaLog", "/common/gacha_record/api/getLdGachaLog"]
        }
        let isAPI = url.host == Self.host(game) && apiPaths.contains(url.path) && url.fragment == nil
        let pageHost = game.region == .global ? "gs.hoyoverse.com" : "webstatic.mihoyo.com"
        let route = game.family == .genshin ? (game.region == .global ? "genshin" : "hk4e") : game.family == .starrail ? "hkrpg" : "nap"
        let event = game.family == .genshin ? "e20190909gacha" : game.family == .starrail ? "e20211215gacha" : "e20230424gacha"
        let prefix = "/\(route)/event/\(event)"
        let pagePaths = [prefix, prefix + "/index.html", prefix + "-v2/index.html", prefix + "-v3/index.html"]
            + (game.family == .genshin ? ["/\(route)/event/e20250716gacha/index.html"] : [])
        let isPage = url.host == pageHost && pagePaths.contains(url.path)
            && items.first(where: { $0.name == "game_biz" })?.value == game.biz
        guard isAPI || isPage else { return nil }
        let names = items.map(\.name)
        guard Set(names).count == names.count,
            let auth = items.first(where: { $0.name == "authkey" })?.value,
            !auth.isEmpty, auth.utf8.count <= 8_192,
            items.first(where: { $0.name == "game_biz" })?.value.map({ $0 == game.biz }) ?? true else { return nil }
        // No untrusted paging, callback, language, or destination parameters survive.
        var copied = items.filter { ["authkey", "authkey_ver", "sign_type", "auth_appid", "init_type", "region"].contains($0.name) }
        if !names.contains("authkey_ver") { copied.append(URLQueryItem(name: "authkey_ver", value: "1")) }
        if !names.contains("sign_type") { copied.append(URLQueryItem(name: "sign_type", value: "2")) }
        credentials = copied
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.credentials.sorted { $0.name < $1.name } == rhs.credentials.sorted { $0.name < $1.name }
    }

    func requestURL(game: GameDefinition, banner: String, page: Int, endID: String, language: String) -> URL {
        var url = URLComponents()
        url.scheme = "https"; url.host = Self.host(game); url.path = Self.path(game, banner: banner)
        url.queryItems = credentials + [URLQueryItem(name: "game_biz", value: game.biz),
            URLQueryItem(name: "size", value: String(Self.pageSize(game, banner: banner))), URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "end_id", value: endID),
            URLQueryItem(name: game.family == .zzz ? "real_gacha_type" : "gacha_type", value: banner)]
        // Foundation leaves '+' literal in a query. Encode it for form-style API decoders.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }

    static func host(_ game: GameDefinition) -> String {
        let biz = game.family == .genshin ? "hk4e" : game.family == .starrail ? "hkrpg" : "nap"
        return "public-operation-\(biz)" + (game.region == .global ? "-sg.hoyoverse.com" : ".mihoyo.com")
    }
    static func path(_ game: GameDefinition, banner: String) -> String {
        if game.family == .genshin { return "/gacha_info/api/" + (isBeyond(game, banner: banner) ? "getBeyondGachaLog" : "getGachaLog") }
        let prefix = game.family == .starrail ? "/common/hkrpg_gacha_record/api/" : "/common/gacha_record/api/"
        return prefix + (game.family == .starrail && ["21", "22"].contains(banner) ? "getLdGachaLog" : "getGachaLog")
    }
    static func isBeyond(_ game: GameDefinition, banner: String) -> Bool {
        game.family == .genshin && ["1000", "2000"].contains(banner)
    }
    static func pageSize(_ game: GameDefinition, banner: String) -> Int { isBeyond(game, banner: banner) ? 5 : 20 }
    static func banners(_ game: GameDefinition) -> [String] {
        switch game.family {
        case .genshin: ["100", "200", "301", "302", "400", "500", "1000", "2000"]
        case .starrail: ["1", "2", "11", "12", "21", "22"]
        case .zzz: ["1", "2", "3", "5", "102", "103"]
        }
    }
}

struct WishHistoryCache {
    static func find(_ request: WishHistoryRequest) throws -> WishHistoryLink {
        do {
            try Task.checkCancellation()
            let fs = try ContainedFileSystem(root: request.installRoot, expectedRootIdentity: request.installIdentity).pinRoot()
            let root = try SafeRelativePath(request.game.dataDirectoryName + "/webCaches")
            let versions = try fs.contentsOfDirectory(at: root)
            // Bound directory work independently of cache-file sizes. No recursive traversal.
            guard versions.count <= 64 else { throw LauncherError.wishHistoryNoCachedLink }
            var candidates: [(SafeRelativePath, Date)] = []
            for version in versions {
                try Task.checkCancellation()
                guard try fs.itemType(at: version) == .directory else { continue }
                let path = try SafeRelativePath(version.description + "/Cache/Cache_Data/index")
                if let date = try fs.modificationDate(at: path) { candidates.append((path, date)) }
            }
            candidates.sort { $0.1 == $1.1 ? $0.0.description.compare($1.0.description, options: .numeric) == .orderedDescending : $0.1 > $1.1 }
            let budget = WishHistoryCacheBudget()
            var selection = WishHistoryCacheSelection()
            for (index, _) in candidates.prefix(16) {
                try Task.checkCancellation()
                guard budget.remaining > 0 else { break }
                let directory = try SafeRelativePath(index.components.dropLast().joined(separator: "/"))
                do {
                    let cache = try WishHistoryBlockCache(fs: fs, root: directory, budget: budget)
                    selection.merge(try cache.select(for: request.game))
                } catch {
                    if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                    // A corrupt cache version cannot contribute partially read candidates.
                }
            }
            if let link = selection.link { return link }
            throw LauncherError.wishHistoryNoCachedLink
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            // Filesystem errors can contain paths. Never let them leave this boundary.
            throw LauncherError.wishHistoryNoCachedLink
        }
    }
}
