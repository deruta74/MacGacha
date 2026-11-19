// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
@testable import Sophon

@Suite struct SandboxMetadataTests {
    @Test func configRetainsSandboxPaths() async throws {
        let api = DeliveryAPI(http: deliveryHTTP(config: configJSON(overrides: [
            "wpf_exe_dir": "BeyondAssets/BeyondAssistEditor/BeyondEditor.exe", "wpf_pkg_version_dir": "beyond_pkg_version"])))
        let config = try await api.config(biz: "test_global")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        #expect(encoded["wpfExecutable"] as? String == "BeyondAssets/BeyondAssistEditor/BeyondEditor.exe")
        #expect(encoded["wpfPackageVersion"] as? String == "beyond_pkg_version")
    }
    @Test(arguments: Region.allCases)
    func selectsPackageAndRegionalEndpoint(region: Region) async throws {
        let game = GameDefinition.inRegion(region).first { $0.family == .genshin }!
        let http = sandboxMetadataHTTP(sandboxJSON(biz: game.biz))
        let package = try #require(try await DeliveryAPI(http: http, region: region).sandboxPackage(biz: game.biz))
        #expect(package.version == "7.2.0.49085326")
        #expect(package.size == (region == .global ? 508_949_016 : 508_955_528))
        #expect(package.md5.hex == (region == .global ? "0354cd866c20f5bd42ec35b2bcf275cc" : "9fa5a6926c8725da4365d0b78c0338af"))
        #expect(package.region == region)
        let url = try #require(http.requests.first)
        #expect(url.host == region.hypAPIHost)
        #expect(url.path.hasSuffix("/getWPFPackages"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains(URLQueryItem(name: "launcher_id", value: region.launcherID)) == true)
        #expect(query?.contains(URLQueryItem(name: "language", value: region == .global ? "en-us" : "zh-cn")) == true)
    }

    @Test func missingEditionMeansNotOffered() async throws {
        let http = sandboxMetadataHTTP(sandboxJSON(biz: "hk4e_cn"))
        #expect(try await DeliveryAPI(http: http).sandboxPackage(biz: "hk4e_global") == nil)
        #expect(try await DeliveryAPI(http: sandboxMetadataHTTP(json(["retcode": 0, "data": ["wpf_packages": []]])))
            .sandboxPackage(biz: "hk4e_global") == nil)
    }

    @Test(arguments: ["hk4e_cn", "unknown", "hk4e_global?secret=value"])
    func refusesWrongEditionBeforeRequest(biz: String) async {
        let http = sandboxMetadataHTTP(sandboxJSON())
        await #expect(throws: LauncherError.io("invalid sandbox edition")) {
            try await DeliveryAPI(http: http).sandboxPackage(biz: biz)
        }
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: ["http://autopatchhk.yuanshen.com/a.zip", "https://evil.test/a.zip",
        "https://yuanshen.com.evil.test/a.zip", "https://user@autopatchhk.yuanshen.com/a.zip",
        "https://user:pass@autopatchhk.yuanshen.com/a.zip", "https://autopatchhk.yuanshen.com:444/a.zip",
        "https://hyp-api.mihoyo.com/a.zip"])
    func rejectsUntrustedURL(url: String) async {
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(sandboxJSON(overrides: ["url": url]))).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test(arguments: ["", "../7", "7 2", "７.2", String(repeating: "1", count: 65)])
    func rejectsUnsafeVersions(version: String) async {
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(sandboxJSON(overrides: ["version": version]))).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test(arguments: ["", String(repeating: "z", count: 32), String(repeating: "0", count: 31), " 0354cd866c20f5bd42ec35b2bcf275cc "])
    func rejectsBadMD5(digest: String) async {
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(sandboxJSON(overrides: ["md5": digest]))).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test(arguments: ["0", "-1", "4294967297", "9223372036854775808", "+1", "1.0", " 1", ""])
    func rejectsSizeBoundsAndSyntax(size: String) async {
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(sandboxJSON(overrides: ["size": size]))).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test(arguments: ["1", "4294967296"])
    func acceptsInclusiveSizeBounds(size: String) async throws {
        let value = try await DeliveryAPI(http: sandboxMetadataHTTP(sandboxJSON(overrides: ["size": size,
            "version": String(repeating: "a", count: 64), "url": "https://autopatchhk.yuanshen.com:443/a.zip"])))
            .sandboxPackage(biz: "hk4e_global")
        #expect(value?.size == Int64(size))
    }

    @Test func decodedPackagesRevalidateTrustBoundary() throws {
        let package = try SandboxPackage(version: "7.2", url: URL(string: "https://autopatchhk.yuanshen.com/a.zip")!,
            md5: md5(Data()), size: 1)
        let encoded = try JSONEncoder().encode(package)
        #expect(try JSONDecoder().decode(SandboxPackage.self, from: encoded) == package)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["url"] = "http://autopatchhk.yuanshen.com/a.zip"
        #expect(throws: LauncherError.io("invalid sandbox package")) { try JSONDecoder().decode(SandboxPackage.self, from: json(object)) }
        #expect(throws: LauncherError.io("invalid sandbox package")) {
            try SandboxPackage(version: "7.2", url: package.url, md5: Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), size: 1)
        }
    }

    @Test func responseStatusRetcodeAndMalformedMetadataAreRejected() async {
        let http = sandboxMetadataHTTP(sandboxJSON())
        http.cdn.enqueueFault("hyp/hyp-connect/api/getWPFPackages", .status(503))
        await #expect(throws: LauncherError.io("delivery HTTP status 503")) {
            try await DeliveryAPI(http: http).sandboxPackage(biz: "hk4e_global")
        }
        await #expect(throws: LauncherError.io("delivery retcode 17")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(json(["retcode": 17, "data": NSNull()])))
                .sandboxPackage(biz: "hk4e_global")
        }
        await #expect(throws: LauncherError.io("invalid delivery response")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(Data("invalid JSON".utf8))).sandboxPackage(biz: "hk4e_global")
        }
        await #expect(throws: LauncherError.io("invalid delivery response")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(json(["retcode": 0, "data": ["wpf_packages": [[
                "game": ["id": "edition", "biz": "hk4e_global"],
                "wpf_package": ["version": "7.2", "url": "https://autopatchhk.yuanshen.com/a.zip", "md5": String(repeating: "0", count: 32), "size": 3]
            ]]]]))).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test func duplicateEditionMetadataIsAmbiguous() async throws {
        let object = try #require(JSONSerialization.jsonObject(with: sandboxJSON()) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let entries = try #require(data["wpf_packages"] as? [[String: Any]])
        let entry = try #require(entries.last)
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: sandboxMetadataHTTP(json(["retcode": 0, "data": ["wpf_packages": [entry, entry]]])))
                .sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test func cancelledAndExpiredRequestsDoNotOpenHTTP() async {
        let http = sandboxMetadataHTTP(sandboxJSON())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DeliveryAPI(http: http).sandboxPackage(biz: "hk4e_global")
        }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
        await #expect(throws: LauncherError.transport("delivery request timed out")) {
            try await DeliveryAPI(http: http, timeout: .zero).sandboxPackage(biz: "hk4e_global")
        }
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: [true, false])
    func metadataResponseIsBounded(withLength: Bool) async {
        let http = SandboxBodyHTTP(data: Data(repeating: 32, count: (1 << 20) + 1), declaredLength: withLength ? (1 << 20) + 1 : nil)
        await #expect(throws: LauncherError.io("delivery response size limit")) {
            try await DeliveryAPI(http: http).sandboxPackage(biz: "hk4e_global")
        }
    }

    @Test func metadataDeadlineCancelsBody() async {
        let http = SandboxBodyHTTP(data: Data(), stalls: true)
        await #expect(throws: LauncherError.transport("delivery request timed out")) {
            try await DeliveryAPI(http: http, timeout: .milliseconds(20)).sandboxPackage(biz: "hk4e_global")
        }
        #expect(http.cancelled.withLock { $0 })
    }

    @Test(arguments: ["", "BeyondAssets/../escape", "/absolute"])
    func configEmptyAndUnsafePaths(path: String) async throws {
        let api = DeliveryAPI(http: deliveryHTTP(config: configJSON(overrides: ["wpf_exe_dir": path, "wpf_pkg_version_dir": path])))
        if path.isEmpty {
            let config = try await api.config(biz: "test_global")
            #expect(config.wpfExecutable == nil)
            #expect(config.wpfPackageVersion == nil)
        } else {
            await #expect(throws: LauncherError.unsafePath("delivery path")) { try await api.config(biz: "test_global") }
        }
        let legacy = try JSONDecoder().decode(GameConfig.self, from: Data(#"{"installationDir":"Game","executable":"Game.exe"}"#.utf8))
        #expect(legacy.wpfExecutable == nil)
        #expect(legacy.wpfPackageVersion == nil)
    }

    @Test func packageDownloadsUseSharedClientAndRejectWrongRegion() async throws {
        let http = sandboxMetadataHTTP(sandboxJSON())
        http.cdn.serve("a.zip", data: Data([1, 2, 3]))
        let package = try SandboxPackage(version: "7.2", url: URL(string: "https://autopatchhk.yuanshen.com/a.zip")!, md5: md5(Data([1, 2, 3])), size: 3)
        let (head, body) = try await DeliveryAPI(http: http).sandboxDownload(package)
        #expect(head.status == 200)
        var received = Data()
        for try await piece in body { received.append(piece) }
        #expect(received == Data([1, 2, 3]))
        await #expect(throws: LauncherError.io("invalid sandbox package")) {
            try await DeliveryAPI(http: http, region: .mainlandChina).sandboxDownload(package)
        }
        let wrongSize = try SandboxPackage(version: "7.2", url: package.url, md5: package.md5, size: 4)
        await #expect(throws: LauncherError.sizeMismatch(path: "sandbox", expected: 4, actual: 3)) {
            try await DeliveryAPI(http: http).sandboxDownload(wrongSize)
        }
    }
}

private func sandboxJSON(biz: String = "hk4e_global", overrides: [String: String] = [:]) -> Data {
    let cn = biz == "hk4e_cn"
    var package = ["version": "7.2.0.49085326",
        "url": cn ? "https://autopatchcn.yuanshen.com/a.zip" : "https://autopatchhk.yuanshen.com/a.zip",
        "md5": cn ? "9fa5a6926c8725da4365d0b78c0338af" : "0354cd866c20f5bd42ec35b2bcf275cc",
        "size": cn ? "508955528" : "508949016"]
    package.merge(overrides) { _, new in new }
    return json(["retcode": 0, "data": ["wpf_packages": [
        ["game": ["id": "other", "biz": "other"], "wpf_package": package],
        ["game": ["id": "edition", "biz": biz], "wpf_package": package]]]])
}
private func sandboxMetadataHTTP(_ payload: Data) -> RecordingHTTP {
    let http = RecordingHTTP()
    http.cdn.serve("hyp/hyp-connect/api/getWPFPackages", data: payload)
    return http
}
private final class SandboxBodyHTTP: HTTPClient, Sendable {
    let data: Data
    let declaredLength: Int64?
    let stalls: Bool
    let cancelled = Mutex(false)
    init(data: Data, declaredLength: Int64? = nil, stalls: Bool = false) {
        self.data = data; self.declaredLength = declaredLength; self.stalls = stalls
    }
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("unexpected POST") }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let sent = Mutex(false)
        return (HTTPResponseHead(status: 200, contentLength: declaredLength), HTTPBody(next: {
            if self.stalls { try await Task.sleep(for: .seconds(30)); return nil }
            return sent.withLock { sent in guard !sent else { return nil }; sent = true; return self.data }
        }, onCancel: { self.cancelled.withLock { $0 = true } }))
    }
}
