// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Sophon

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_PREDOWNLOAD"] == "1"), .timeLimit(.minutes(2)))
func predownloadLiveMetadataAndOnePatchManifestOnly() async throws {
    let http = DeliveryHostPolicy.makeHTTPClient()
    defer { http.invalidate() }
    let api = DeliveryAPI(http: http)
    let branches = try await api.branches(biz: "hk4e_global")
    let config = try await api.config(biz: "hk4e_global")
    #expect(config.enableLdiff)
    // Still exercises the patch protocol between campaigns, without guessing future selectors.
    let branch = branches.preDownload ?? branches.main
    let build = try await api.build(branch)
    let patch = try await api.patchBuild(branch)
    #expect(build.tag == branch.tag)
    #expect(patch.tag == build.tag)
    #expect(patch.buildID == build.buildID)
    let category = try #require(patch.categories.first { $0.matchingField == "game" })
    try #require(category.manifest.compressedSize <= 2 << 20 && category.manifest.decodedSize <= 8 << 20,
        "Live probe refuses a patch manifest above its metadata-only budget")
    let result = try await api.patchManifest(category)
    #expect(!result.manifest.files.isEmpty)
    // No diff container, full manifest, game chunk, executable or installed file is opened.
}
