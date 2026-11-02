// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import Sophon

@Suite struct PatchDeliveryAPITests {
    @Test(arguments: [Region.global, .mainlandChina])
    func postsSelectorsAndDecodesCategoryStats(region: Region) async throws {
        let http = patchHTTP(region: region)
        let build = try await DeliveryAPI(http: http, region: region).patchBuild(testBranch(password: "p+a&b/=?"))
        #expect(build.buildID == "build-test")
        #expect(build.patchID == "patch-test")
        #expect(build.tag == "1.2.3")
        let url = try #require(http.posts.first)
        #expect(url.host == region.sophonBuildHost)
        #expect(url.path == "/downloader/sophon_chunk/api/getPatchBuild")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "password", value: "p+a&b/=?")))
        #expect(items.contains(URLQueryItem(name: "package_id", value: "selector-package")))
        #expect(items.contains(URLQueryItem(name: "branch", value: "main")))
        #expect(!items.contains { $0.name == "tag" })
        #expect(!url.absoluteString.contains("p+a"))
        let category = try #require(build.categories.first)
        #expect(category.region == region)
        #expect(category.diffCodec == .identity)
        #expect(category.stats["1.0.0"]?.compressedSize == 99)
        #expect(category.stats["1.0.0"]?.decodedSize == 101)
        #expect(category.stats["1.0.0"]?.fileCount == 4)
        #expect(category.stats["1.0.0"]?.chunkCount == 2)
        #expect(category.stats["0.9.0"]?.compressedSize == 110)
        #expect(category.stats["missing"] == nil)
        #expect(try category.diffURL(id: "container").absoluteString.hasSuffix("/container?diff=1%2F2"))
        #expect(try category.manifestURL.absoluteString.hasSuffix("/manifest-test?manifest=1"))
        let restored = try JSONDecoder().decode(SophonPatchBuild.self, from: JSONEncoder().encode(build))
        #expect(restored.categories == build.categories)
    }

    @Test(arguments: ["manifest_download", "diff_download"], [0, 1, 2])
    func compressionIsScopedToDescriptor(key: String, compression: Int) async throws {
        let data = patchJSON(descriptor: key, changes: ["compression": compression])
        let api = DeliveryAPI(http: patchHTTP(data: data))
        if compression == 1 || (compression == 0 && key == "diff_download") {
            let build = try await api.patchBuild(testBranch())
            #expect(build.categories.first?.diffCodec == (key == "diff_download" && compression == 1 ? .zstd : .identity))
        } else {
            await #expect(throws: LauncherError.io("unsupported delivery: descriptor")) { try await api.patchBuild(testBranch()) }
        }
    }

    @Test(arguments: ["manifest_download", "diff_download"], ["http://cdn.hoyoverse.com", "https://evil.test", "https://cdn.mihoyo.com"])
    func rejectsUntrustedDescriptors(key: String, prefix: String) async {
        await #expect(throws: LauncherError.io("untrusted delivery host")) {
            try await DeliveryAPI(http: patchHTTP(data: patchJSON(descriptor: key, changes: ["url_prefix": prefix]))).patchBuild(testBranch())
        }
    }

    @Test(arguments: ["manifest_download", "diff_download"], ["encryption", "password"])
    func rejectsEncryption(key: String, field: String) async {
        let value: Any = field == "encryption" ? 1 : "selector"
        await #expect(throws: LauncherError.io("unsupported delivery: descriptor")) {
            try await DeliveryAPI(http: patchHTTP(data: patchJSON(descriptor: key, changes: [field: value]))).patchBuild(testBranch())
        }
    }

    @Test func rejectsPersistedUnsafeDescriptors() async throws {
        let build = try await DeliveryAPI(http: patchHTTP()).patchBuild(testBranch())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(build)) as? [String: Any])
        var categories = object["categories"] as! [[String: Any]]
        categories[0]["diffPrefix"] = "https://evil.test"
        object["categories"] = categories
        #expect(throws: LauncherError.io("untrusted delivery host")) { try JSONDecoder().decode(SophonPatchBuild.self, from: json(object)) }
    }

    @Test(arguments: [true, false])
    func boundsPostMetadata(declaredLength: Bool) async {
        let http = PatchBodyHTTP(length: declaredLength ? (2 << 20) + 1 : nil,
            pieces: [Data(repeating: 0, count: 1 << 20), Data(repeating: 0, count: (1 << 20) + 1)])
        await #expect(throws: LauncherError.io("delivery response size limit")) {
            try await DeliveryAPI(http: http).patchBuild(testBranch())
        }
        #expect(http.cancelled.withLock { $0 })
    }

    @Test func postCancellationDrainsBodyAndSanitizesFailures() async throws {
        let http = PatchBodyHTTP(stalls: true)
        let task = Task { try await DeliveryAPI(http: http).patchBuild(testBranch()) }
        defer { task.cancel() }
        try await http.started.wait()
        task.cancel()
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        #expect(http.cancelled.withLock { $0 })
        await #expect(throws: LauncherError.transport("delivery request timed out")) {
            try await DeliveryAPI(http: patchHTTP(), timeout: .zero).patchBuild(testBranch())
        }
        await #expect(throws: LauncherError.io("delivery retcode -202")) {
            try await DeliveryAPI(http: patchHTTP(data: json(["retcode": -202, "data": NSNull()]))).patchBuild(testBranch())
        }
    }
}

func patchJSON(region: Region = .global, descriptor: String = "diff_download", changes: [String: Any] = [:]) -> Data {
    let host = region == .global ? "cdn.hoyoverse.com" : "cdn.mihoyo.com"
    var manifest: [String: Any] = ["url_prefix": "https://\(host)/manifests", "url_suffix": "?manifest=1", "compression": 1, "encryption": 0, "password": ""]
    var diff: [String: Any] = ["url_prefix": "https://\(host)/diffs", "url_suffix": "?diff=1%2F2", "compression": 0, "encryption": 0, "password": ""]
    if descriptor == "manifest_download" { manifest.merge(changes) { _, new in new } }
    else { diff.merge(changes) { _, new in new } }
    return json(["retcode": 0, "data": ["build_id": "build-test", "patch_id": "patch-test", "tag": "1.2.3", "manifests": [[
        "category_id": "game", "matching_field": "game", "manifest": ["id": "manifest-test", "checksum": md5(manifestProto).hex,
            "compressed_size": String(manifestFrame.count), "uncompressed_size": String(manifestProto.count)],
        "manifest_download": manifest, "diff_download": diff, "stats": [
            "1.0.0": ["compressed_size": "99", "uncompressed_size": "101", "file_count": "4", "chunk_count": "2"],
            "0.9.0": ["compressed_size": 110, "uncompressed_size": 112, "file_count": 6, "chunk_count": 3]
        ]
    ]]]])
}
func patchHTTP(region: Region = .global, data: Data? = nil) -> RecordingHTTP {
    let http = deliveryHTTP()
    http.cdn.serve("downloader/sophon_chunk/api/getPatchBuild", data: data ?? patchJSON(region: region))
    return http
}

private final class PatchBodyHTTP: HTTPClient, Sendable {
    let started = TestEvent(), release = TestEvent()
    let cancelled = Mutex(false)
    private let index = Mutex(0)
    private let pieces: [Data]
    private let length: Int64?
    private let stalls: Bool
    init(length: Int64? = nil, pieces: [Data] = [], stalls: Bool = false) {
        self.length = length; self.pieces = pieces; self.stalls = stalls
    }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("Unexpected GET") }
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) {
        (HTTPResponseHead(status: 200, contentLength: length), HTTPBody(next: {
            self.started.signal()
            if self.stalls { try await self.release.wait(); return nil }
            return self.index.withLock { i in
                guard i < self.pieces.count else { return nil }
                defer { i += 1 }; return self.pieces[i]
            }
        }, onCancel: { self.cancelled.withLock { $0 = true } }))
    }
}
