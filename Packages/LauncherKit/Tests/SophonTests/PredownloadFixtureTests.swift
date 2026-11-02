// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
import Sophon

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_PREDOWNLOAD_FIXTURES"] != nil), .timeLimit(.minutes(1)))
func recordedPredownloadMetadataAndManifestsWithoutNetwork() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_PREDOWNLOAD_FIXTURES"]))
    for (name, region, biz) in [("global", Region.global, "hk4e_global"), ("cn", .mainlandChina, "hk4e_cn")] {
        let inputs = try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: root)
            return try ["branches.json", "configs.json", "getPatchBuild-POST.json", "getPatchBuild-game.zst"].map {
                try fs.readFile(at: SafeRelativePath("\(name)-\($0)"), maxBytes: 2 << 20)
            }
        }
        let http = deliveryHTTP(branches: inputs[0], config: inputs[1])
        http.cdn.serve("downloader/sophon_chunk/api/getPatchBuild", data: inputs[2])
        let api = DeliveryAPI(http: http, region: region)
        let branches = try await api.branches(biz: biz)
        let future = try #require(branches.preDownload)
        #expect(!future.diffTags.isEmpty)
        #expect(try await api.config(biz: biz).enableLdiff)
        let build = try await api.patchBuild(future)
        #expect(build.tag == future.tag)
        let category = try #require(build.categories.first { $0.matchingField == "game" })
        http.cdn.serve(String(try category.manifestURL.path.dropFirst()), data: inputs[3])
        let manifest = try await api.patchManifest(category).manifest
        #expect(!manifest.files.isEmpty)
        for tag in future.diffTags {
            #expect(manifest.files.contains { $0.patches[tag] != nil })
            #expect(manifest.deletedFiles[tag] != nil)
            #expect(category.stats[tag] != nil)
        }
    }
}
