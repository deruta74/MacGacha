// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct DeliveryAPI: Sendable {
    private let http: any HTTPClient
    private let timeout: Duration
    private let log: EventLog?
    private let region: Region
    private static let metadataLimit = 2 << 20

    public init(http: any HTTPClient, region: Region = .global, timeout: Duration = .seconds(30), log: EventLog? = nil) {
        self.http = http; self.region = region; self.timeout = timeout; self.log = log
    }

    public func branch(biz: String) async throws -> GameBranch {
        let data: BranchesWire = try await json(endpoint("getGameBranches"))
        guard let entry = data.game_branches.first(where: { $0.game.biz == biz }), let main = entry.main else {
            throw LauncherError.io("delivery branch unavailable")
        }
        return GameBranch(gameID: entry.game.id, biz: entry.game.biz, packageID: main.package_id,
            password: main.password, branch: main.branch, tag: main.tag, categories: main.categories.map {
                BranchCategory(id: $0.category_id, matchingField: $0.matching_field, isAudio: $0.type == "CATEGORY_TYPE_AUDIO",
                    inFullScenario: $0.scenarios.contains("CATEGORY_SCENARIO_FULL"))
            })
    }

    public func config(biz: String) async throws -> GameConfig {
        let data: ConfigsWire = try await json(endpoint("getGameConfigs"))
        guard let entry = data.launch_configs.first(where: { $0.game.biz == biz }) else {
            throw LauncherError.io("delivery config unavailable")
        }
        do {
            return try GameConfig(installationDir: SafeRelativePath(entry.installation_dir), executable: SafeRelativePath(entry.exe_file_name))
        } catch { throw LauncherError.unsafePath("delivery path") }
    }

    public func build(_ branch: GameBranch, tag: String? = nil) async throws -> SophonBuild {
        var components = URLComponents(url: region.sophonBuildURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "branch", value: branch.branch),
            URLQueryItem(name: "package_id", value: branch.packageID), URLQueryItem(name: "password", value: branch.password)]
        if let tag { components.queryItems?.append(URLQueryItem(name: "tag", value: tag)) }
        // Form-query decoders treat '+' as space, although URLComponents leaves it literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw LauncherError.io("invalid delivery request") }
        let wire: BuildWire = try await json(url)
        return try SophonBuild(buildID: wire.build_id, tag: wire.tag, categories: wire.manifests.map { try $0.model(region: region) })
    }

    public func manifest(_ category: BuildCategory) async throws -> (compressed: Data, manifest: SophonManifest) {
        guard category.region == region else { throw LauncherError.io("untrusted delivery host") }
        try category.validate()
        let url = try category.manifestURL
        let data = try await deadline { try await bytes(url, limit: Int(category.manifest.compressedSize), expected: category.manifest.compressedSize) }
        return try (data, Self.decodeManifest(data, ref: category.manifest))
    }

    public static func decodeManifest(_ compressed: Data, ref: ManifestRef) throws -> SophonManifest {
        try ref.validate()
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard compressed.count == ref.compressedSize else {
            throw LauncherError.sizeMismatch(path: "manifest", expected: ref.compressedSize, actual: Int64(compressed.count))
        }
        let decoded = try Zstd.decode(compressed, expectedSize: Int(ref.decodedSize))
        var hasher = StreamingHasher(.md5); hasher.update(decoded)
        let actual = hasher.finalize()
        guard actual == ref.decodedMD5 else {
            throw LauncherError.digestMismatch(path: "manifest", expected: ref.decodedMD5.hex, actual: actual.hex)
        }
        return try SophonManifest.decode(decoded)
    }

    private func endpoint(_ name: String) -> URL {
        region.hypAPIURL(name)
    }

    private func json<T: Decodable & Sendable>(_ url: URL) async throws -> T {
        let data = try await deadline { try await bytes(url, limit: Self.metadataLimit) }
        do { return try JSONDecoder().decode(Envelope<T>.self, from: data).data }
        catch let error as LauncherError { throw error }
        catch { throw LauncherError.io("invalid delivery response") }
    }

    private func bytes(_ url: URL, limit: Int, expected: Int64? = nil) async throws -> Data {
        guard DeliveryHostPolicy.allows(url, region: region) else { throw LauncherError.io("untrusted delivery host") }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let head: HTTPResponseHead; let body: HTTPBody
        do { (head, body) = try await http.get(url, byteRangeFrom: nil) }
        catch { throw await requestFailure(error) }
        // Fixed descriptions and numeric fields only: no selector, URL, server message or error text.
        await log?.log(.info, "sophon", "HTTP response", metadata: ["status": String(head.status)])
        guard head.status == 200 else { throw LauncherError.io("delivery HTTP status \(head.status)") }
        if let length = head.contentLength {
            if let expected, length != expected { throw LauncherError.sizeMismatch(path: "manifest", expected: expected, actual: length) }
            guard length <= limit else { throw LauncherError.io("delivery response size limit") }
        }
        var data = Data()
        var iterator = body.makeAsyncIterator()
        while true {
            let piece: Data?
            do { piece = try await iterator.next() }
            catch { throw await requestFailure(error) }
            guard let piece else { break }
            guard piece.count <= limit - data.count else {
                if let expected {
                    throw LauncherError.sizeMismatch(path: "manifest", expected: expected, actual: Int64(data.count) + Int64(piece.count))
                }
                throw LauncherError.io("delivery response size limit")
            }
            data.append(piece)
        }
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if let expected, data.count != expected {
            throw LauncherError.sizeMismatch(path: "manifest", expected: expected, actual: Int64(data.count))
        }
        return data
    }

    private func requestFailure(_ error: any Error) async -> LauncherError {
        if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled { return .cancelled }
        await log?.log(.warning, "sophon", "Request failed")
        return .transport("delivery request failed")
    }

    private func deadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard timeout > .zero else { throw LauncherError.transport("delivery request timed out") }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await Task.sleep(for: timeout); throw LauncherError.transport("delivery request timed out") }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else { throw LauncherError.cancelled }
                return result
            } catch {
                if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
                throw error
            }
        }
    }
}

// Private wire models stay separate from the Codable snapshots used in saved build records.
private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T
    private enum CodingKeys: String, CodingKey { case retcode, data }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(Int.self, forKey: .retcode)
        guard code == 0 else { throw LauncherError.io("delivery retcode \(code)") }
        data = try c.decode(T.self, forKey: .data)
    }
}
private struct GameWire: Decodable, Sendable { let id: String; let biz: String }
private struct BranchesWire: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let game: GameWire; let main: Main? }
    struct Main: Decodable, Sendable {
        let package_id: String; let password: String; let branch: String; let tag: String
        let categories: [Category]
    }
    struct Category: Decodable, Sendable {
        let category_id: String; let matching_field: String; let type: String; let scenarios: [String]
    }
    let game_branches: [Entry]
}
private struct ConfigsWire: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let game: GameWire; let installation_dir: String; let exe_file_name: String }
    let launch_configs: [Entry]
}
private struct BuildWire: Decodable, Sendable {
    let build_id: String; let tag: String; let manifests: [Category]
    struct Category: Decodable, Sendable {
        let category_id: String; let matching_field: String; let manifest: Manifest
        let manifest_download: Descriptor; let chunk_download: Descriptor; let stats: Stats
        func model(region: Region) throws -> BuildCategory {
            let (mp, ms) = try manifest_download.validate(region: region)
            let (cp, cs) = try chunk_download.validate(region: region)
            let digest: Digest
            do { digest = try Digest(algorithm: .md5, hex: manifest.checksum) }
            catch { throw LauncherError.io("invalid delivery checksum") }
            let ref = ManifestRef(id: manifest.id, decodedMD5: digest,
                compressedSize: manifest.compressed_size.value, decodedSize: manifest.uncompressed_size.value)
            let result = BuildCategory(id: category_id, matchingField: matching_field, manifest: ref,
                manifestPrefix: mp, manifestSuffix: ms, chunkPrefix: cp, chunkSuffix: cs,
                compressedSize: stats.compressed_size.value, decodedSize: stats.uncompressed_size.value, region: region)
            try result.validate()
            return result
        }
    }
    struct Manifest: Decodable, Sendable {
        let id: String; let checksum: String; let compressed_size: DecimalSize; let uncompressed_size: DecimalSize
    }
    struct Stats: Decodable, Sendable { let compressed_size: DecimalSize; let uncompressed_size: DecimalSize }
    struct Descriptor: Decodable, Sendable {
        let url_prefix: String; let url_suffix: String; let compression: Int; let encryption: Int; let password: String
        func validate(region: Region) throws -> (URL, String) {
            guard compression == 1, encryption == 0, password.isEmpty else { throw LauncherError.io("unsupported delivery: descriptor") }
            guard let prefix = URL(string: url_prefix, encodingInvalidCharacters: false), DeliveryHostPolicy.allows(prefix, region: region) else {
                throw LauncherError.io("untrusted delivery host")
            }
            return (prefix, url_suffix)
        }
    }
}
private struct DecimalSize: Decodable, Sendable {
    let value: Int64
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int64(text) else {
                throw LauncherError.io("invalid delivery response")
            }
            value = size
        } else {
            value = try c.decode(Int64.self)
            guard value >= 0 else { throw LauncherError.io("invalid delivery response") }
        }
    }
}
