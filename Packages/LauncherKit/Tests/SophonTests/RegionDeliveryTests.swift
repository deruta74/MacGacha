// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import Sophon

@Suite struct RegionDeliveryTests {
    @Test(arguments: [Region.global, .mainlandChina]) func selectsRegionEndpoints(region: Region) async throws {
        let http = deliveryHTTP()
        let api = DeliveryAPI(http: http, region: region)
        _ = try await api.branch(biz: "test_global")
        _ = try await api.config(biz: "test_global")
        // The synthetic Global descriptor is rejected by CN, after getBuild.
        _ = try? await api.build(testBranch())
        #expect(http.requests.count == 3)
        let host = region == .global ? "sg-hyp-api.hoyoverse.com" : "hyp-api.mihoyo.com"
        let launcher = region == .global ? "VYTpXlbWo8" : "jGHBHlcOq1"
        for url in http.requests.prefix(2) {
            #expect(url.host == host)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "launcher_id", value: launcher)) == true)
        }
        #expect(http.requests.last?.host == (region == .global ? "sg-public-api.hoyoverse.com" : "downloader-api.mihoyo.com"))
    }

    @Test(arguments: ["hk4e_cn", "hkrpg_cn", "nap_cn"]) func cnFixturesParseAndRoundTrip(biz: String) async throws {
        let http = deliveryHTTP(branches: try cnDeliveryFixture("getGameBranches"), build: try cnDeliveryFixture("getBuild-" + biz))
        let api = DeliveryAPI(http: http, region: .mainlandChina)
        let branch = try await api.branch(biz: biz)
        let expected = ["hk4e_cn": ("1Z8W5NHUQb", "7.1.0"), "hkrpg_cn": ("64kMb5iAWu", "4.6.0"), "nap_cn": ("x6znKlJ0xK", "3.3.0")][biz]!
        #expect(branch.gameID == expected.0)
        #expect(branch.tag == expected.1)
        #expect(branch.password.isEmpty)
        let build = try await api.build(branch)
        #expect(build.tag == branch.tag)
        #expect(!build.categories.isEmpty)
        let copy = try JSONDecoder().decode(SophonBuild.self, from: JSONEncoder().encode(build))
        #expect(copy.categories == build.categories)
        for category in copy.categories {
            #expect(category.region == .mainlandChina)
            #expect(DeliveryHostPolicy.allows(try category.manifestURL, region: .mainlandChina))
            #expect(DeliveryHostPolicy.allows(try category.chunkURL(id: "test-chunk"), region: .mainlandChina))
        }
        #expect(http.requests.map(\.host) == ["hyp-api.mihoyo.com", "downloader-api.mihoyo.com"])
    }

    @Test(arguments: [Region.global, .mainlandChina]) func foreignDescriptorRefused(region: Region) async throws {
        let foreign = region == .global ? try cnDeliveryFixture("getBuild-hkrpg_cn") : buildJSON()
        let api = DeliveryAPI(http: deliveryHTTP(build: foreign), region: region)
        await #expect(throws: LauncherError.io("untrusted delivery host")) { try await api.build(testBranch()) }
    }

    @Test(arguments: [Region.global, .mainlandChina]) func deliveryPolicyIsRegionBound(region: Region) {
        let own = region == .global ? ["hoyoverse.com", "starrails.com", "zenlesszonezero.com"] : ["mihoyo.com", "bhsr.com", "juequling.com"]
        let foreign = region == .global ? ["mihoyo.com", "bhsr.com", "juequling.com"] : ["hoyoverse.com", "starrails.com", "zenlesszonezero.com"]
        for domain in own + ["yuanshen.com"] {
            #expect(DeliveryHostPolicy.allows(URL(string: "https://cdn.\(domain)/asset")!, region: region))
            #expect(!DeliveryHostPolicy.allows(URL(string: "https://\(domain).evil.test/asset")!, region: region))
            #expect(!DeliveryHostPolicy.allows(URL(string: "http://\(domain)/asset")!, region: region))
            #expect(!DeliveryHostPolicy.allows(URL(string: "https://user@\(domain)/asset")!, region: region))
        }
        for domain in foreign { #expect(!DeliveryHostPolicy.allows(URL(string: "https://cdn.\(domain)/asset")!, region: region)) }
        let client = DeliveryHostPolicy.makeHTTPClient(region: region)
        client.invalidate()
    }

    @Test func legacyBuildDefaultsToGlobal() throws {
        let category = try BuildCategory(id: "test", matchingField: "game", manifest: ManifestRef(id: "manifest", decodedMD5: Digest(algorithm: .md5, hex: String(repeating: "0", count: 32)), compressedSize: 1, decodedSize: 1), manifestPrefix: URL(string: "https://cdn.hoyoverse.com/m")!, manifestSuffix: "", chunkPrefix: URL(string: "https://cdn.hoyoverse.com/c")!, chunkSuffix: "", compressedSize: 1, decodedSize: 1)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(category)) as? [String: Any])
        object.removeValue(forKey: "region")
        let restored = try JSONDecoder().decode(BuildCategory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.region == .global)
    }
}

// Public CN responses from 2026-10-24, reduced to parser fields. Selector
// passwords are empty; URL queries/fragments and unrelated fields are removed.
func cnDeliveryFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "CN"))
    return try Data(contentsOf: url)
}
