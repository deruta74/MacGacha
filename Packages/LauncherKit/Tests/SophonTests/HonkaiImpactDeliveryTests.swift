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

@Test(arguments: HonkaiImpactServer.allCases)
func honkaiImpactDeliveryHostsAreExactAndGlobalOnly(server: HonkaiImpactServer) throws {
    let host = server.deliveryHost
    #expect(DeliveryHostPolicy.allows(try #require(URL(string: "https://\(host)/manifest"))))
    #expect(!DeliveryHostPolicy.allows(try #require(URL(string: "https://\(host)/manifest")), region: .mainlandChina))
    for address in ["https://sub.\(host)/", "https://\(host).example.invalid/", "http://\(host)/",
         "https://user@\(host)/", "https://\(host):8443/"] {
        #expect(!DeliveryHostPolicy.allows(try #require(URL(string: address))))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_HI3"] == "1"), .timeLimit(.minutes(10)))
func honkaiImpactGlobalWindowsManifests() async throws {
    let http = DeliveryHostPolicy.makeHTTPClient()
    defer { http.invalidate() }
    let api = DeliveryAPI(http: http)
    let areaPath = try SafeRelativePath("pkg_area_name")
    var areaDigests: Set<Digest> = []
    for server in HonkaiImpactServer.allCases {
        let definition = try #require(GameDefinition.find(server.rawValue))
        let branches = try await api.branches(biz: definition.biz, gameID: server.gameID)
        let branch = branches.main
        let config = try await api.config(biz: definition.biz, gameID: server.gameID)
        #expect(branch.gameID == server.gameID)
        #expect(config.executable.description == "BH3.exe")
        #expect(!config.enableLdiff)
        let voiceCount = branch.categories.filter(\.isAudio).count
        #expect(voiceCount == 0)
        let build = try await api.build(branch)
        #expect(build.tag == branch.tag)
        let categories = try SophonPlanner.selectCategories(branch, build: build, voices: [])
        #expect(categories.count == build.categories.count)
        var target: [PlannedCategory] = []
        for category in categories {
            let manifest = try await api.manifest(category).manifest
            target.append(PlannedCategory(category: category, manifest: manifest))
        }
        let plan = try SophonPlanner.fullPlan(id: SafeIdentifier(server.rawValue), target: target)
        #expect(plan.files.contains { $0.path == config.executable })
        let marker = try #require(plan.files.first { $0.path == areaPath })
        var digest = StreamingHasher(.md5)
        digest.update(Data(server.packageName.utf8))
        #expect(marker.digest == digest.finalize())
        areaDigests.insert(marker.digest)
        print("\(server.rawValue): \(branch.tag), \(categories.count) manifests, \(voiceCount) voice categories, pkg_area_name verified, pre-download offered: \(branches.preDownload != nil)")
        if server == .europeAmericas {
            if let directory = ProcessInfo.processInfo.environment["MACGACHA_HI3_ADOPT_EVIDENCE"] {
                let fs = try ContainedFileSystem(root: URL(fileURLWithPath: directory, isDirectory: true))
                let bytes = try await BlockingIO.run { try fs.pinRoot().readFile(at: areaPath, maxBytes: 256) }
                #expect(bytes == Data(server.packageName.utf8))
                print("Local Europe & Americas area marker matches its manifest")
            }
            if let directory = ProcessInfo.processInfo.environment["MACGACHA_HI3_INSTALLATION"] {
                let fs = try ContainedFileSystem(root: URL(fileURLWithPath: directory, isDirectory: true))
                let report = try await Verifier().verify(fs: fs, files: plan.files.map(ManifestFile.init))
                print("Verified \(report.checkedFiles) files and \(report.checkedBytes) bytes")
                #expect(report.problems.isEmpty)
            }
        }
    }
    #expect(areaDigests.count == HonkaiImpactServer.allCases.count)
}
