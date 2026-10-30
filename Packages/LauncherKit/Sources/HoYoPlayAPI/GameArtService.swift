// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

/// A memory snapshot is always synchronous. Disk hydration and every refresh run on
/// this actor, off the main actor. No failure is surfaced to the user.
public actor GameArtService {
    private static let ttl: TimeInterval = 6 * 3600
    // Three games × (16 backgrounds × 5 assets + icon + logo), plus headroom.
    public static let maximumBackgroundsPerGame = 16
    public static let maximumAssets = 320
    private static let indexLimit = 512 << 10
    private static func gameIDs(_ region: Region) -> [String: String] {
        Dictionary(uniqueKeysWithValues: GameDefinition.inRegion(region).map { ($0.biz, $0.id) })
    }
    private nonisolated let snapshot = Mutex<[String: GameArt]>([:])
    private let directory: URL
    private let language: HoYoPlayLanguage
    private let region: Region
    private let http: any HTTPClient
    private let ownedHTTP: ArtHTTPSession?
    private let now: @Sendable () -> Date
    private let log: EventLog?
    private let requestTimeout: Duration
    private var index = ArtIndex()
    private var hydrated = false
    private var flight: (id: UUID, task: Task<[String: GameArt], Never>)?

    public init(cacheDirectory: URL, region: Region = .global, language: HoYoPlayLanguage = .enUS, http: (any HTTPClient)? = nil, log: EventLog? = nil,
        now: @escaping @Sendable () -> Date = Date.init, requestTimeout: Duration = .seconds(30)) {
        // Preserve the existing Global cache. CN owns its index and assets in a
        // separate directory, which Global's regular-file pruning leaves alone.
        self.directory = region == .global ? cacheDirectory : cacheDirectory.appendingPathComponent(region.rawValue, isDirectory: true)
        self.region = region; self.language = region == .mainlandChina ? .zhCN : language
        self.log = log; self.now = now; self.requestTimeout = requestTimeout
        if let http { self.http = http; ownedHTTP = nil }
        else { let session = ArtHTTPSession(region: region); ownedHTTP = session; self.http = session.client }
    }

    /// The last hydrated snapshot. Never performs file I/O or network requests.
    /// First refresh also loads a persisted index, including when offline.
    public nonisolated func cached() -> [String: GameArt] { snapshot.withLock { $0 } }

    /// Hydrates persisted art without network I/O, so startup can display it before
    /// a stale index triggers slower network refreshes. Runs off the main actor.
    public func loadCached() async -> [String: GameArt] {
        guard !hydrated, !Task.isCancelled, directory.isFileURL else { return cached() }
        do {
            let fs = try ContainedFileSystem(root: directory.deletingLastPathComponent())
            let root = try SafeRelativePath(directory.lastPathComponent)
            hydrate(fs, root: root)
        } catch { }
        return cached()
    }

    private func hydrate(_ fs: ContainedFileSystem, root: SafeRelativePath) {
        guard !hydrated else { return }
        hydrated = true
        if let saved = try? readIndex(fs, root: root) { index = saved }
        snapshot.withLock { $0 = buildArt(index) }
    }

    public func refresh() async -> [String: GameArt] {
        if Task.isCancelled { return cached() }
        let current: (id: UUID, task: Task<[String: GameArt], Never>)
        if let flight { current = flight }
        else { current = (UUID(), Task { await self.update() }); flight = current }
        let result = await withTaskCancellationHandler { await current.task.value } onCancel: { current.task.cancel() }
        if flight?.id == current.id { flight = nil }
        return result
    }

    private func update() async -> [String: GameArt] {
        do {
            guard directory.isFileURL, requestTimeout > .zero else { return cached() }
            let fs = try ContainedFileSystem(root: directory.deletingLastPathComponent())
            let root = try SafeRelativePath(directory.lastPathComponent)
            try fs.createDirectory(at: root)
            hydrate(fs, root: root)
            let age = now().timeIntervalSince(index.fetchedAt)
            // Art fetched in another language is stale however fresh it is, and so is an index from
            // before background lists, so an app update shows every background without waiting.
            if age >= 0 && age < Self.ttl && (index.language ?? .enUS) == language,
                index.games.values.allSatisfy({ $0.backgrounds != nil }) { return cached() }
            let http = http; let log = log; let timeout = requestTimeout
            let urls = Self.apiURLs(region: region, language: language)
            let gamesData = try await Self.deadline(timeout) { try await Self.json(urls.games, http: http, log: log) }
            let basicData = try await Self.deadline(timeout) { try await Self.json(urls.basic, http: http, log: log) }
            let requested: [String: RemoteArt]
            do { requested = try Self.parse(gamesData, basicData, region: region) }
            catch { throw ArtFailure.invalidAPIResponse }
            guard !requested.isEmpty else { throw ArtFailure.noSupportedGames }
            var selected = index.games
            var files = index.assets
            var attempted: Set<String> = []
            for (id, remote) in requested.sorted(by: { $0.key < $1.key }) {
                let old = index.games[id] ?? RemoteArt()
                var next = RemoteArt()
                for key in RemoteArt.images {
                    let url = remote[keyPath: key]
                    if let url, await asset(url, video: false, fs: fs, root: root, files: &files, attempted: &attempted) {
                        next[keyPath: key] = url
                    } else { next[keyPath: key] = old[keyPath: key] }
                }
                if let url = remote.video {
                    if await asset(url, video: true, fs: fs, root: root, files: &files, attempted: &attempted) {
                        next.video = url
                        if let theme = remote.theme, await asset(theme, video: false, fs: fs, root: root, files: &files, attempted: &attempted) { next.theme = theme }
                        else if old.video == url { next.theme = old.theme }
                    } else { next.video = old.video; next.theme = old.theme }
                }
                var backgrounds: [RemoteBackground] = []
                for layer in remote.layers {
                    let previous = old.layers.first { $0.id == layer.id }
                    var saved = RemoteBackground(id: layer.id)
                    for key in RemoteBackground.images {
                        if let url = layer[keyPath: key] {
                            if await asset(url, video: false, fs: fs, root: root, files: &files, attempted: &attempted) {
                                saved[keyPath: key] = url
                            } else { saved[keyPath: key] = previous?[keyPath: key] }
                        }
                    }
                    // An absent API icon removes the button; fallback never crosses slides.
                    saved.link = layer.link.flatMap(GameHighlights.browserLink)
                    if let url = layer.video {
                        if await asset(url, video: true, fs: fs, root: root, files: &files, attempted: &attempted) {
                            saved.video = url
                            if let theme = layer.theme, await asset(theme, video: false, fs: fs, root: root, files: &files, attempted: &attempted) {
                                saved.theme = theme
                            } else if previous?.video == url { saved.theme = previous?.theme }
                        } else { saved.video = previous?.video; saved.theme = previous?.theme }
                    }
                    backgrounds.append(saved)
                }
                next.backgrounds = backgrounds
                selected[id] = next
            }
            try Task.checkCancellation()
            let retained = Set(selected.values.flatMap(\.urls).map(\.absoluteString))
            let next = ArtIndex(fetchedAt: now(), language: language, region: region, games: selected, assets: files.filter { retained.contains($0.key) })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(next)
            guard bytes.count <= Self.indexLimit else { return cached() }
            try fs.writeAtomically(bytes, to: SafeRelativePath("\(root)/art-index.json"))
            index = next
            let art = buildArt(next); snapshot.withLock { $0 = art }
            try? prune(fs, root: root, index: next)
            return art
        } catch {
            await log?.log(.info, "game-art", "Refresh skipped", metadata: ["reason": Self.reason(error)])
            return cached()
        }
    }

    private func asset(_ url: URL, video: Bool, fs: ContainedFileSystem, root: SafeRelativePath,
        files: inout [String: AssetRecord], attempted: inout Set<String>) async -> Bool {
        guard Self.allowedAsset(url, region: region) else {
            await log?.log(.info, "game-art", "Asset skipped", metadata: ["reason": "url-not-allowed"])
            return false
        }
        let key = url.absoluteString
        if attempted.insert(key).inserted {
            let http = http; let log = log; let date = now()
            do {
                files[key] = try await Self.deadline(requestTimeout) {
                    try await Self.download(url, video: video, http: http, log: log, fs: fs, root: root, date: date)
                }
            } catch {
                await log?.log(.info, "game-art", "Asset skipped",
                    metadata: ["host": url.host ?? "", "reason": Self.reason(error), "type": video ? "video" : "image"])
            }
        }
        guard let file = files[key]?.file else { return false }
        return video == (file.hasSuffix(".webm"))
    }

    private func readIndex(_ fs: ContainedFileSystem, root: SafeRelativePath) throws -> ArtIndex {
        let data = try fs.readFile(at: SafeRelativePath("\(root)/art-index.json"), maxBytes: Self.indexLimit)
        var saved = try JSONDecoder().decode(ArtIndex.self, from: data)
        guard (saved.region ?? .global) == region, saved.assets.count <= Self.maximumAssets, saved.games.count <= 3, saved.games.values.allSatisfy({ $0.layers.count <= Self.maximumBackgroundsPerGame }), saved.fetchedAt.timeIntervalSinceReferenceDate.isFinite,
            saved.games.keys.allSatisfy({ Self.gameIDs(region).values.contains($0) }) else { throw LauncherError.io("Invalid art index") }
        saved.assets = saved.assets.filter { key, record in
            guard let url = URL(string: key), Self.allowedAsset(url, region: region), record.fetchedAt.timeIntervalSinceReferenceDate.isFinite,
                ["png", "jpg", "webp", "webm"].contains(URL(fileURLWithPath: record.file).pathExtension),
                record.file == Self.hash(url) + "." + URL(fileURLWithPath: record.file).pathExtension else { return false }
            do {
                let path = try SafeRelativePath("\(root)/\(record.file)")
                guard let size = try fs.size(at: path), size > 0, size <= (record.file.hasSuffix(".webm") ? 64 << 20 : 16 << 20) else { return false }
                let handle = try fs.openForReading(at: path); defer { try? handle.close() }
                let prefix = try handle.read(upToCount: ArtMedia.headerLimit) ?? Data()
                if record.file.hasSuffix(".webm") {
                    guard ArtMedia.isWebM(prefix) else { return false }
                } else if ArtMedia.imageExtension(prefix) != URL(fileURLWithPath: record.file).pathExtension { return false }
                return true
            } catch { return false }
        }
        return saved
    }

    private func buildArt(_ index: ArtIndex) -> [String: GameArt] {
        func local(_ url: URL?, video: Bool = false) -> URL? {
            guard let url, let record = index.assets[url.absoluteString], video == record.file.hasSuffix(".webm") else { return nil }
            return directory.appendingPathComponent(record.file)
        }
        return index.games.mapValues { remote in
            let video = local(remote.video, video: true)
            return GameArt(background: local(remote.background), video: video,
                theme: video == nil ? nil : local(remote.theme), icon: local(remote.icon), logo: local(remote.logo),
                backgrounds: remote.layers.map { layer in
                    let highlights = local(layer.highlight).map {
                        GameHighlights(image: $0, hoverImage: local(layer.hover), link: layer.link)
                    }
                    let clip = local(layer.video, video: true)
                    return GameBackground(id: layer.id, image: local(layer.background), video: clip,
                        theme: clip == nil ? nil : local(layer.theme), highlights: highlights)
                })
        }
    }

    private func prune(_ fs: ContainedFileSystem, root: SafeRelativePath, index: ArtIndex) throws {
        var keep = Set(index.assets.values.map(\.file)); keep.insert("art-index.json")
        for path in try fs.contentsOfDirectory(at: root) where !keep.contains(path.components.last ?? "") {
            if try fs.itemType(at: path, allowingLeafSymlink: true) == .regularFile { try fs.removeFile(at: path) }
        }
    }

    private static func deadline<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await Task.sleep(for: timeout); throw LauncherError.transport("Art request timed out") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LauncherError.cancelled }
            return result
        }
    }

    private static func response(_ url: URL, http: any HTTPClient, log: EventLog?, cap: Int) async throws -> HTTPBody {
        let (head, body) = try await http.get(url, byteRangeFrom: nil)
        await log?.log(.info, "game-art", "HTTP response", metadata: ["host": url.host ?? "", "status": String(head.status)])
        guard head.status == 200 else { throw ArtFailure.responseStatus }
        guard head.contentLength.map({ $0 >= 0 && $0 <= cap }) ?? true else { throw ArtFailure.sizeLimit }
        return body
    }

    private static func json(_ url: URL, http: any HTTPClient, log: EventLog?) async throws -> Data {
        let body = try await response(url, http: http, log: log, cap: 2 << 20)
        var data = Data()
        for try await piece in body {
            try Task.checkCancellation()
            guard piece.count <= (2 << 20) - data.count else { throw ArtFailure.sizeLimit }
            data.append(piece)
        }
        return data
    }

    private static func download(_ url: URL, video: Bool, http: any HTTPClient, log: EventLog?,
        fs: ContainedFileSystem, root: SafeRelativePath, date: Date) async throws -> AssetRecord {
        let cap = video ? 64 << 20 : 16 << 20
        let body = try await response(url, http: http, log: log, cap: cap)
        let part = try SafeRelativePath("\(root)/.incoming-\(UUID().uuidString)")
        do {
            let handle = try fs.openForWriting(at: part, truncate: true); defer { try? handle.close() }
            var count = 0; var prefix = Data()
            for try await piece in body {
                try Task.checkCancellation()
                guard piece.count <= cap - count else { throw ArtFailure.sizeLimit }
                if prefix.count < ArtMedia.headerLimit { prefix.append(piece.prefix(ArtMedia.headerLimit - prefix.count)) }
                try SystemFileOps().writeAll(piece, to: handle.fileDescriptor)
                count += piece.count
            }
            let ext: String
            if video { guard ArtMedia.isWebM(prefix) else { throw ArtFailure.invalidWebM }; ext = "webm" }
            else { guard let image = ArtMedia.imageExtension(prefix) else { throw ArtFailure.invalidImage }; ext = image }
            let file = hash(url) + "." + ext
            try fs.fullSync(at: part)
            try fs.rename(from: part, to: SafeRelativePath("\(root)/\(file)"))
            return AssetRecord(file: file, fetchedAt: date)
        } catch {
            await Task.detached { try? fs.removeFile(at: part) }.value
            throw error
        }
    }


    /// The two HoYoPlay endpoints art comes from, in `language`.
    public static func apiURLs(region: Region = .global, language: HoYoPlayLanguage) -> (games: URL, basic: URL) {
        func endpoint(_ name: String) -> URL {
            var components = URLComponents(url: region.hypAPIURL(name), resolvingAgainstBaseURL: false)!
            components.queryItems?.append(URLQueryItem(name: "language", value: region == .mainlandChina ? "zh-cn" : language.rawValue))
            return components.url!
        }
        return (endpoint("getGames"), endpoint("getAllGameBasicInfo"))
    }

    private static func hash(_ url: URL) -> String { var h = StreamingHasher(.sha256); h.update(Data(url.absoluteString.utf8)); return h.finalize().hex }

    // Never log arbitrary error descriptions: they may contain URLs, query secrets or paths.
    private static func reason(_ error: any Error) -> String {
        if let failure = error as? ArtFailure { return failure.rawValue }
        if error is CancellationError { return "cancelled" }
        if let error = error as? LauncherError {
            switch error {
            case .cancelled: return "cancelled"
            case .transport: return "transfer-failed"
            case .fileTooLarge: return "size-limit"
            default: break
            }
        }
        return "cache-or-transfer-failed"
    }
    fileprivate static func allowed(_ url: URL, region: Region) -> Bool {
        validURL(url) && (url.host?.lowercased() == region.hypAPIHost || allowedAsset(url, region: region))
    }
    private static func validURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.absoluteString.utf8.count <= 8192
    }
    private static func allowedAsset(_ url: URL, region: Region) -> Bool {
        guard validURL(url), let host = url.host?.lowercased() else { return false }
        switch region {
        case .global: return region.artDomains.contains { host.hasSuffix("." + $0) }
        case .mainlandChina: return region.artDomains.contains(host)
        }
    }

    private static func parse(_ games: Data, _ basic: Data, region: Region) throws -> [String: RemoteArt] {
        let games = try JSONDecoder().decode(Envelope<Games>.self, from: games)
        let basic = try JSONDecoder().decode(Envelope<Basic>.self, from: basic)
        guard games.retcode ?? 0 == 0, basic.retcode ?? 0 == 0 else { throw LauncherError.io("Art API refused request") }
        let gameIDs = Self.gameIDs(region)
        var result: [String: RemoteArt] = [:]
        for game in games.data.games {
            guard let id = game.biz.flatMap({ gameIDs[$0] }) else { continue }
            result[id] = RemoteArt(background: game.display?.background?.url, icon: game.display?.icon?.url, logo: game.display?.logo?.url)
        }
        for game in basic.data.game_info_list {
            guard let id = game.game.biz.flatMap({ gameIDs[$0] }), let layer = game.backgrounds?.first else { continue }
            var art = result[id] ?? RemoteArt()
            art.background = layer.background?.url ?? art.background
            if layer.type == "BACKGROUND_TYPE_VIDEO" { art.video = layer.video?.url; art.theme = layer.theme?.url }
            var ids: Set<String> = []
            art.backgrounds = (game.backgrounds ?? []).prefix(Self.maximumBackgroundsPerGame).compactMap { layer in
                let stableID = layer.id.flatMap { $0.isEmpty ? nil : $0 }
                    ?? RemoteBackground.legacyID(layer.background?.url)
                guard ids.insert(stableID).inserted else { return nil }
                return RemoteBackground(id: stableID, background: layer.background?.url,
                    video: layer.type == "BACKGROUND_TYPE_VIDEO" ? layer.video?.url : nil,
                    theme: layer.type == "BACKGROUND_TYPE_VIDEO" ? layer.theme?.url : nil,
                    highlight: layer.icon?.url, hover: layer.icon?.hover_url,
                    link: layer.icon?.link.flatMap(GameHighlights.browserLink))
            }
            result[id] = art
        }
        return result
    }
}

private struct AssetRecord: Codable, Sendable { let file: String; let fetchedAt: Date }
private struct ArtIndex: Codable, Sendable {
    var fetchedAt = Date.distantPast
    /// Nil in indexes written before the language was recorded, which were all en-us.
    var language: HoYoPlayLanguage? = nil
    /// Nil belongs to the legacy Global cache.
    var region: Region? = nil
    var games: [String: RemoteArt] = [:]
    var assets: [String: AssetRecord] = [:]
}
private struct RemoteArt: Codable, Sendable {
    var background: URL?; var icon: URL?; var logo: URL?; var video: URL?; var theme: URL?
    static let images: [WritableKeyPath<RemoteArt, URL?> & Sendable] = [\.background, \.icon, \.logo]
    var backgrounds: [RemoteBackground]?
    var layers: [RemoteBackground] {
        backgrounds ?? (background == nil && video == nil ? [] : [RemoteBackground(
            id: RemoteBackground.legacyID(background), background: background, video: video, theme: theme)])
    }
    var urls: [URL] { [background, icon, logo, video, theme].compactMap { $0 } + layers.flatMap(\.urls) }
}
private struct RemoteBackground: Codable, Sendable {
    var id: String
    var background: URL?; var video: URL?; var theme: URL?
    var highlight: URL?; var hover: URL?; var link: URL?
    static let images: [WritableKeyPath<RemoteBackground, URL?> & Sendable] = [\.background, \.highlight, \.hover]
    var urls: [URL] { [background, video, theme, highlight, hover].compactMap { $0 } }
    static func legacyID(_ url: URL?) -> String {
        var hash = StreamingHasher(.sha256); hash.update(Data((url?.absoluteString ?? "missing").utf8))
        return "legacy-" + hash.finalize().hex
    }
}
private struct Envelope<T: Decodable>: Decodable { let retcode: Int?; let data: T }
private struct Link: Decodable {
    let url: URL?
    private enum CodingKeys: String, CodingKey { case url }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // HoYoPlay uses "" for absent video/theme links, including in ignored games
        // and later background layers. URL's Decodable rejects "" and loses the response.
        let value = try values.decodeIfPresent(String.self, forKey: .url)
        url = value.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}
private enum ArtFailure: String, Error {
    case invalidAPIResponse = "invalid-api-response"
    case noSupportedGames = "no-supported-games"
    case invalidImage = "invalid-image"
    case invalidWebM = "invalid-webm"
    case responseStatus = "response-status"
    case sizeLimit = "size-limit"
}
private struct Display: Decodable { let icon: Link?; let logo: Link?; let background: Link? }
private struct Game: Decodable { let biz: String?; let display: Display? }
private struct Games: Decodable { let games: [Game] }
private struct Basic: Decodable { let game_info_list: [BasicGame] }
private struct BasicGame: Decodable { let game: Game; let backgrounds: [Layer]? }
private struct Highlight: Decodable {
    let url: URL?; let hover_url: URL?; let link: URL?
    private enum CodingKeys: String, CodingKey { case url, hover_url, link }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) throws -> URL? {
            try c.decodeIfPresent(String.self, forKey: key).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        url = try read(.url); hover_url = try read(.hover_url); link = try read(.link)
    }
}
private struct Layer: Decodable { let id: String?; let icon: Highlight?; let type: String?; let background: Link?; let video: Link?; let theme: Link? }
private final class ArtHTTPSession: Sendable {
    let client: URLSessionHTTPClient
    init(region: Region) { client = URLSessionHTTPClient(redirectPolicy: { GameArtService.allowed($0, region: region) }) }
    deinit { client.invalidate() }
}
