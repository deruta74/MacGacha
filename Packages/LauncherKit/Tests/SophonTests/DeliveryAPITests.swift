// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import Sophon

@Suite struct DeliveryAPITests {
    @Test func selectsEntryByBizNotIndex() async throws {
        let http = deliveryHTTP(branches: branchesJSON())
        let branch = try await DeliveryAPI(http: http).branch(biz: "test_global")
        #expect(branch.gameID == "test-id")
        #expect(branch.biz == "test_global")
        #expect(branch.packageID == "selector-package")
        #expect(branch.password == "selector-password")
        #expect(branch.branch == "main")
        #expect(branch.tag == "1.2.3")
        #expect(branch.categories.count == 3)
        #expect(branch.categories[0].inFullScenario)
        #expect(!branch.categories[0].isAudio)
        #expect(branch.categories[1].isAudio)
        #expect(!branch.categories[2].inFullScenario)
        let url = try #require(http.requests.first)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
            URLQueryItem(name: "launcher_id", value: "VYTpXlbWo8")) == true)
    }

    @Test func nullPreDownloadIsIgnored() async throws {
        let http = deliveryHTTP(branches: branchesJSON(preDownload: NSNull()))
        #expect(try await DeliveryAPI(http: http).branch(biz: "test_global").branch == "main")
    }

    @Test func wireBranchStringIsPreserved() async throws {
        let http = deliveryHTTP(branches: branchesJSON(branch: "predownload"))
        #expect(try await DeliveryAPI(http: http).branch(biz: "test_global").branch == "predownload")
    }

    @Test(arguments: [false, true])
    func parsesDecimalStringSizes(numericJSON: Bool) async throws {
        let size: Any = numericJSON ? 60_642_059_824 : "60642059824"
        let http = deliveryHTTP(build: buildJSON(statsSize: size))
        let build = try await DeliveryAPI(http: http).build(testBranch())
        #expect(build.buildID == "build-test")
        #expect(build.tag == "1.2.3")
        let category = try #require(build.categories.first)
        #expect(category.compressedSize == 60_642_059_824)
        #expect(category.decodedSize == 61_000_000_000)
        #expect(category.manifest.compressedSize == Int64(manifestFrame.count))
        #expect(category.manifest.decodedSize == Int64(manifestProto.count))
        #expect(category.manifest.decodedMD5 == md5(manifestProto))
        let restored = try JSONDecoder().decode(SophonBuild.self, from: JSONEncoder().encode(build))
        #expect(restored.categories == build.categories)
    }

    @Test(arguments: ["-1", "+1", "3.2", "no", "9223372036854775808", " 12", ""])
    func rejectsNegativeOrNonNumericSizes(size: String) async {
        let http = deliveryHTTP(build: buildJSON(statsSize: size))
        await #expect(throws: LauncherError.io("invalid delivery response")) {
            try await DeliveryAPI(http: http).build(testBranch())
        }
    }

    @Test func retcodeNonZeroThrows() async {
        let http = deliveryHTTP(branches: json(["retcode": 17, "message": "https://example.test/?password=selector-password", "data": NSNull()]))
        await #expect(throws: LauncherError.io("delivery retcode 17")) {
            try await DeliveryAPI(http: http).branch(biz: "test_global")
        }
    }

    @Test func buildURLCarriesSelectorsAndOptionalTag() async throws {
        let http = deliveryHTTP()
        let api = DeliveryAPI(http: http)
        let branch = testBranch(password: "p+a&b/=?")
        _ = try await api.build(branch)
        _ = try await api.build(branch, tag: "0.9 beta")
        let queries = http.requests.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)!.queryItems! }
        #expect(queries[0].contains(URLQueryItem(name: "branch", value: "main")))
        #expect(queries[0].contains(URLQueryItem(name: "package_id", value: "selector-package")))
        #expect(queries[0].contains(URLQueryItem(name: "password", value: "p+a&b/=?")))
        #expect(!queries[0].contains { $0.name == "tag" })
        #expect(queries[1].contains(URLQueryItem(name: "tag", value: "0.9 beta")))
    }

    @Test func selectorsUseFormSafePercentEncoding() async throws {
        let http = deliveryHTTP()
        let branch = GameBranch(gameID: "test-id", biz: "test_global", packageID: "package+id",
            password: "p+a&b/=?", branch: "main+branch", tag: "1.2.3", categories: [])
        _ = try await DeliveryAPI(http: http).build(branch, tag: "tag+old")
        let url = try #require(http.requests.first)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        // Model the standard form-query decoder, where a transmitted '+' means a space.
        let fields = query.split(separator: "&").map { pair -> [String] in
            pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
        }
        #expect(fields.contains(["package_id", "package+id"]))
        #expect(fields.contains(["password", "p+a&b/=?"]))
        #expect(fields.contains(["branch", "main+branch"]))
        #expect(fields.contains(["tag", "tag+old"]))
    }

    @Test func nonEmptySuffixesAreKept() async throws {
        let http = deliveryHTTP(build: buildJSON(manifestSuffix: "?a=1%2F2", chunkSuffix: "?b=3"))
        http.cdn.serve("manifest%2Fpath/manifest-test", data: manifestFrame)
        // MockCDN normalizes URL.path, which decodes percent escapes.
        http.cdn.serve("manifest/path/manifest-test", data: manifestFrame)
        let api = DeliveryAPI(http: http)
        let category = try #require(try await api.build(testBranch()).categories.first)
        #expect(try category.manifestURL.absoluteString == "https://cdn.hoyoverse.com/manifest%2Fpath/manifest-test?a=1%2F2")
        #expect(try category.chunkURL(id: "object").absoluteString == "https://cdn.yuanshen.com/chunks/object?b=3")
        let result = try await api.manifest(category)
        #expect(result.compressed == manifestFrame)
        #expect(result.manifest.files.first?.path.description == "file.bin")
        #expect(http.requests.last?.absoluteString.hasSuffix("?a=1%2F2") == true)
    }

    @Test(arguments: ["https://evil-hoyoverse.com/x", "https://hoyoverse.com.evil.test/x", "http://cdn.hoyoverse.com/x"])
    func rejectsUntrustedHostAndHTTPPrefix(prefix: String) async {
        let http = deliveryHTTP(build: buildJSON(prefix: prefix))
        await #expect(throws: LauncherError.io("untrusted delivery host")) {
            try await DeliveryAPI(http: http).build(testBranch())
        }
        #expect(http.requests.count == 1)
    }

    @Test(arguments: [0, 1, 2])
    func rejectsEncryptedOrUnknownCompression(variant: Int) async {
        let http = deliveryHTTP(build: buildJSON(compression: variant == 0 ? 2 : 1,
            encryption: variant == 1 ? 1 : 0, descriptorPassword: variant == 2 ? "private-selector" : ""))
        await #expect(throws: LauncherError.io("unsupported delivery: descriptor")) {
            try await DeliveryAPI(http: http).build(testBranch())
        }
        #expect(http.requests.count == 1)
    }

    @Test func manifestWrongCompressedLengthThrows() {
        let ref = manifestRef(compressed: Int64(manifestFrame.count + 1))
        // Invalid zstd too: the length error must win before any decoding.
        #expect(throws: LauncherError.sizeMismatch(path: "manifest", expected: ref.compressedSize, actual: 1)) {
            try DeliveryAPI.decodeManifest(Data([0]), ref: ref)
        }
    }

    @Test func manifestWrongDecodedLengthThrows() {
        let ref = manifestRef(decoded: Int64(manifestProto.count + 1))
        #expect(throws: LauncherError.sizeMismatch(path: "decoded object", expected: ref.decodedSize, actual: Int64(manifestProto.count))) {
            try DeliveryAPI.decodeManifest(manifestFrame, ref: ref)
        }
    }

    @Test func manifestChecksumIsOverDecodedBytes() throws {
        let wrong = manifestRef(digest: md5(manifestFrame))
        #expect(throws: LauncherError.digestMismatch(path: "manifest", expected: wrong.decodedMD5.hex, actual: md5(manifestProto).hex)) {
            try DeliveryAPI.decodeManifest(manifestFrame, ref: wrong)
        }
        #expect(try DeliveryAPI.decodeManifest(manifestFrame, ref: manifestRef()).files.count == 1)
    }

    @Test func manifestProtobufIsCheckedOnlyAfterChecksum() {
        let badProto = Data([0x0b]) // An unsupported protobuf group, inside a valid zstd frame.
        let frame = rawZstd(badProto)
        let ref = ManifestRef(id: "bad", decodedMD5: md5(badProto), compressedSize: Int64(frame.count), decodedSize: 1)
        #expect(throws: LauncherError.io("invalid protobuf field")) { try DeliveryAPI.decodeManifest(frame, ref: ref) }
    }

    @Test(arguments: [true, false])
    func manifestSizeLimits(compressedLimit: Bool) async {
        let http = deliveryHTTP()
        let ref = manifestRef(compressed: compressedLimit ? (128 << 20) + 1 : nil,
            decoded: compressedLimit ? nil : (512 << 20) + 1)
        await #expect(throws: LauncherError.io("manifest size limit")) {
            try await DeliveryAPI(http: http).manifest(testCategory(ref: ref))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func streamedLengthIsBoundedWithoutContentLength() async {
        let body = ByteBody(pieces: [Data(repeating: 1, count: 7), Data(repeating: 2, count: 7)])
        let http = BodyHTTP(body: body)
        let ref = manifestRef(compressed: 10)
        await #expect(throws: LauncherError.sizeMismatch(path: "manifest", expected: 10, actual: 14)) {
            try await DeliveryAPI(http: http).manifest(testCategory(ref: ref))
        }
        #expect(body.cancelled.withLock { $0 })
    }

    @Test func selectorsNeverLoggedOrIncludedInErrors() async throws {
        let temp = try TempDir(); let log = EventLog(directory: temp.url)
        let http = deliveryHTTP()
        let api = DeliveryAPI(http: http, log: log)
        _ = try await api.build(testBranch())
        let malicious = FailingHTTP()
        do {
            _ = try await DeliveryAPI(http: malicious, log: log).build(testBranch())
            Issue.record("Expected transport error")
        } catch {
            let text = String(describing: error)
            #expect(!text.contains("selector-package"))
            #expect(!text.contains("selector-password"))
            #expect(!text.contains("https://"))
        }
        let text = try String(contentsOf: temp.url.appendingPathComponent("macgacha.log"), encoding: .utf8)
        #expect(text.contains("sophon"))
        #expect(!text.contains("selector-package"))
        #expect(!text.contains("selector-password"))
        #expect(!text.contains("https://"))
    }

    @Test(arguments: ["../outside", "/absolute"])
    func installationDirAndExecutableMustBeSafe(path: String) async {
        for key in ["installation_dir", "exe_file_name"] {
            let http = deliveryHTTP(config: configJSON(overrides: [key: path]))
            await #expect(throws: LauncherError.unsafePath("delivery path")) {
                try await DeliveryAPI(http: http).config(biz: "test_global")
            }
        }
    }

    @Test func configSelectsByBiz() async throws {
        let config = try await DeliveryAPI(http: deliveryHTTP()).config(biz: "test_global")
        #expect(config.installationDir.description == "Test Game")
        #expect(config.executable.description == "bin/Test.exe")
    }

    @Test func persistedDescriptorsKeepBoundsAndHostChecks() throws {
        let ref = manifestRef(decoded: (512 << 20) + 1)
        let encoded = try JSONEncoder().encode(ref)
        #expect(throws: LauncherError.io("manifest size limit")) {
            try JSONDecoder().decode(ManifestRef.self, from: encoded)
        }
        let valid = testCategory()
        let unsafe = BuildCategory(id: valid.id, matchingField: valid.matchingField, manifest: valid.manifest,
            manifestPrefix: valid.manifestPrefix, manifestSuffix: "", chunkPrefix: URL(string: "https://evil.test")!,
            chunkSuffix: "", compressedSize: valid.compressedSize, decodedSize: valid.decodedSize)
        let badHost = try JSONEncoder().encode(unsafe)
        #expect(throws: LauncherError.io("untrusted delivery host")) {
            try JSONDecoder().decode(BuildCategory.self, from: badHost)
        }
    }

    @Test func metadataBodyLimit() async {
        let http = deliveryHTTP(branches: Data(repeating: 32, count: (2 << 20) + 1))
        await #expect(throws: LauncherError.io("delivery response size limit")) {
            try await DeliveryAPI(http: http).branch(biz: "test_global")
        }
    }

    @Test func cancellationAndDeadlineCancelTheBody() async throws {
        let body = ByteBody(pieces: [], stalls: true)
        let task = Task { try await DeliveryAPI(http: BodyHTTP(body: body), timeout: .seconds(10)).branch(biz: "test_global") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !body.started.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(body.started.withLock { $0 })
        task.cancel()
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(body.cancelled.withLock { $0 })
        let timed = ByteBody(pieces: [], stalls: true)
        await #expect(throws: LauncherError.transport("delivery request timed out")) {
            try await DeliveryAPI(http: BodyHTTP(body: timed), timeout: .milliseconds(50)).branch(biz: "test_global")
        }
        #expect(timed.cancelled.withLock { $0 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"] != nil,
        "Set MACGACHA_SPIKE_FIXTURES for local-only delivery fixtures"))
    func liveShapesParse() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_SPIKE_FIXTURES"]))
        for (game, biz) in [("genshin", "hk4e_global"), ("starrail", "hkrpg_global"), ("zzz", "nap_global")] {
            let dir = root.appendingPathComponent(game)
            let branches = try Data(contentsOf: dir.appendingPathComponent("getGameBranches.json"))
            let configs = try Data(contentsOf: dir.appendingPathComponent("getGameConfigs.json"))
            let buildData = try Data(contentsOf: dir.appendingPathComponent("main-getBuild.json"))
            let api = DeliveryAPI(http: deliveryHTTP(branches: branches, config: configs, build: buildData))
            let branch = try await api.branch(biz: biz)
            #expect(branch.biz == biz)
            _ = try await api.config(biz: biz)
            let build = try await api.build(branch)
            print("LIVE \(game): branch/config/build parsed, categories=\(build.categories.count)")
            var count = 0
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
                where file.lastPathComponent.hasPrefix("main-") && file.lastPathComponent.hasSuffix("-manifest.zst") {
                let matching = String(file.lastPathComponent.dropFirst(5).dropLast("-manifest.zst".count))
                let category = try #require(build.categories.first { $0.matchingField == matching })
                let manifest = try DeliveryAPI.decodeManifest(Data(contentsOf: file), ref: category.manifest)
                count += 1
                print("LIVE \(game)/\(file.lastPathComponent): files=\(manifest.files.count), chunks=\(manifest.files.reduce(0) { $0 + $1.chunks.count })")
            }
            #expect(count > 0)
        }
    }
}

// All data below is synthetic. The raw zstd frame uses the public frame format,
// a single-segment one-byte content size, and one final uncompressed block.
let manifestProto: Data = {
    var f = ProtobufWriter(); f.string(1, "file.bin"); f.string(5, String(repeating: "0", count: 32))
    var m = ProtobufWriter(); m.bytes(1, f.data); return m.data
}()
let manifestFrame = rawZstd(manifestProto)
func rawZstd(_ data: Data) -> Data {
    let header = UInt32(data.count) << 3 | 1
    return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(data.count), UInt8(header & 255), UInt8((header >> 8) & 255), UInt8(header >> 16)]) + data
}
func md5(_ data: Data) -> Digest { var h = StreamingHasher(.md5); h.update(data); return h.finalize() }
func manifestRef(compressed: Int64? = nil, decoded: Int64? = nil, digest: Digest? = nil) -> ManifestRef {
    ManifestRef(id: "manifest-test", decodedMD5: digest ?? md5(manifestProto),
        compressedSize: compressed ?? Int64(manifestFrame.count), decodedSize: decoded ?? Int64(manifestProto.count))
}
func testCategory(ref: ManifestRef = manifestRef()) -> BuildCategory {
    BuildCategory(id: "category", matchingField: "game", manifest: ref,
        manifestPrefix: URL(string: "https://cdn.hoyoverse.com/manifests")!, manifestSuffix: "",
        chunkPrefix: URL(string: "https://cdn.yuanshen.com/chunks")!, chunkSuffix: "", compressedSize: 100, decodedSize: 200)
}
func testBranch(password: String = "selector-password") -> GameBranch {
    GameBranch(gameID: "test-id", biz: "test_global", packageID: "selector-package", password: password,
        branch: "main", tag: "1.2.3", categories: [])
}
func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func branchesJSON(preDownload: Any = NSNull(), branch: String = "main") -> Data {
    json(["retcode": 0, "data": ["game_branches": [
        ["game": ["id": "other", "biz": "other_global"], "main": NSNull()],
        ["game": ["id": "test-id", "biz": "test_global"], "main": [
            "package_id": "selector-package", "password": "selector-password", "branch": branch, "tag": "1.2.3",
            "categories": [
                ["category_id": "base", "matching_field": "game", "type": "CATEGORY_TYPE_RESOURCE", "scenarios": ["CATEGORY_SCENARIO_FULL"]],
                ["category_id": "voice", "matching_field": "en-us", "type": "CATEGORY_TYPE_AUDIO", "scenarios": ["CATEGORY_SCENARIO_FULL"]],
                ["category_id": "small", "matching_field": "101", "type": "CATEGORY_TYPE_RESOURCE", "scenarios": ["CATEGORY_SCENARIO_BASE"]]
            ]], "pre_download": preDownload]
    ]]])
}
func configJSON(overrides: [String: String] = [:]) -> Data {
    var entry: [String: Any] = ["game": ["id": "test-id", "biz": "test_global"], "installation_dir": "Test Game", "exe_file_name": "bin/Test.exe"]
    for (key, value) in overrides { entry[key] = value }
    return json(["retcode": 0, "data": ["launch_configs": [
        ["game": ["id": "other", "biz": "other_global"], "installation_dir": "Other", "exe_file_name": "Other.exe"], entry]]])
}
func buildJSON(statsSize: Any = "100", prefix: String = "https://cdn.hoyoverse.com/manifest%2Fpath",
    manifestSuffix: String = "", chunkSuffix: String = "", compression: Int = 1, encryption: Int = 0, descriptorPassword: String = "") -> Data {
    let descriptor: [String: Any] = ["url_prefix": prefix, "url_suffix": manifestSuffix, "compression": compression, "encryption": encryption, "password": descriptorPassword]
    var chunk = descriptor; chunk["url_prefix"] = "https://cdn.yuanshen.com/chunks"; chunk["url_suffix"] = chunkSuffix
    return json(["retcode": 0, "data": ["build_id": "build-test", "tag": "1.2.3", "manifests": [[
        "category_id": "category", "matching_field": "game", "manifest": ["id": "manifest-test", "checksum": md5(manifestProto).hex,
            "compressed_size": String(manifestFrame.count), "uncompressed_size": String(manifestProto.count)],
        "manifest_download": descriptor, "chunk_download": chunk,
        "stats": ["compressed_size": statsSize, "uncompressed_size": "61000000000"]
    ]]]])
}
func deliveryHTTP(branches: Data = branchesJSON(), config: Data = configJSON(), build: Data = buildJSON()) -> RecordingHTTP {
    let h = RecordingHTTP(); h.cdn.serve("hyp/hyp-connect/api/getGameBranches", data: branches)
    h.cdn.serve("hyp/hyp-connect/api/getGameConfigs", data: config)
    h.cdn.serve("downloader/sophon_chunk/api/getBuild", data: build)
    return h
}
final class RecordingHTTP: HTTPClient, Sendable {
    let cdn = MockCDN(); private let recorded = Mutex<[URL]>([])
    var requests: [URL] { recorded.withLock { $0 } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        recorded.withLock { $0.append(url) }; return try await cdn.get(url, byteRangeFrom: offset)
    }
}
private struct FailingHTTP: HTTPClient {
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        throw LauncherError.transport("Failed \(url.absoluteString)")
    }
}
private struct BodyHTTP: HTTPClient {
    let body: ByteBody
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        (HTTPResponseHead(status: 200), HTTPBody(next: { try await body.next() }, onCancel: { body.cancel() }))
    }
}
private final class ByteBody: Sendable {
    let cancelled = Mutex(false); let started = Mutex(false)
    private let pieces: [Data]; private let index = Mutex(0); private let stalls: Bool
    init(pieces: [Data], stalls: Bool = false) { self.pieces = pieces; self.stalls = stalls }
    func next() async throws -> Data? {
        started.withLock { $0 = true }
        if stalls { try await Task.sleep(for: .seconds(15)); return nil }
        return index.withLock { i in guard i < pieces.count else { return nil }; defer { i += 1 }; return pieces[i] }
    }
    func cancel() { cancelled.withLock { $0 = true } }
}
