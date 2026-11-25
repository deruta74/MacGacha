// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import DownloadEngine
import Foundation
import Testing
import LauncherCore
import Sophon

@Test func selectsTheRequestedServerWhenGamesShareABiz() async throws {
    let api = DeliveryAPI(http: deliveryHTTP(branches: branchesJSON(otherBiz: "test_global"),
        config: configJSON(otherBiz: "test_global")))
    let branch = try await api.branch(biz: "test_global", gameID: "test-id")
    let config = try await api.config(biz: "test_global", gameID: "test-id")
    #expect(branch.gameID == "test-id")
    #expect(config.executable.description == "bin/Test.exe")
    await #expect(throws: LauncherError.io("delivery branch unavailable")) {
        try await api.branch(biz: "test_global", gameID: "missing")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_HI3"] == "1"), .timeLimit(.minutes(10)))
func honkaiImpactGlobalWindowsManifests() async throws {
    let http = DeliveryHostPolicy.makeHTTPClient()
    defer { http.invalidate() }
    let api = DeliveryAPI(http: http)
    let id = "5TIVvvcwtM"
    let branch = try await api.branch(biz: "bh3_global", gameID: id)
    let config = try await api.config(biz: "bh3_global", gameID: id)
    #expect(branch.gameID == id)
    #expect(config.executable.description == "BH3.exe")
    let build = try await api.build(branch)
    #expect(build.tag == branch.tag)
    let categories = try SophonPlanner.selectCategories(branch, build: build, voices: [])
    var target: [PlannedCategory] = []
    for category in categories {
        let manifest = try await api.manifest(category).manifest
        target.append(PlannedCategory(category: category, manifest: manifest))
    }
    let plan = try SophonPlanner.fullPlan(id: SafeIdentifier("hi3-global"), target: target)
    #expect(plan.files.contains { $0.path == config.executable })
    if let directory = ProcessInfo.processInfo.environment["MACGACHA_HI3_INSTALLATION"] {
        let fs = try ContainedFileSystem(root: URL(fileURLWithPath: directory, isDirectory: true))
        let report = try await Verifier().verify(fs: fs, files: plan.files.map(ManifestFile.init))
        print("Verified \(report.checkedFiles) files and \(report.checkedBytes) bytes")
        #expect(report.problems.isEmpty)
    }
}
