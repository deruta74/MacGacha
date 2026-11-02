// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Sophon
import TestSupport
@testable import DownloadEngine

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_PREDOWNLOAD_FIXTURES"] != nil), .timeLimit(.minutes(1)))
func recordedPatchBatchBudgetsWithoutNetwork() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_PREDOWNLOAD_FIXTURES"]))
    try await BlockingIO.run {
        let evidence = try ContainedFileSystem(root: root), temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        let http = MockCDN(), api = DeliveryAPI(http: http)
        http.serve("hyp/hyp-connect/api/getGameBranches", data: try evidence.readFile(at: SafeRelativePath("global-branches.json"), maxBytes: 2 << 20))
        let branches = try await api.branches(biz: "hk4e_global"), targetBranch = try #require(branches.preDownload)
        http.serve("downloader/sophon_chunk/api/getBuild", data: try evidence.readFile(at: SafeRelativePath("chunk-route/source-build.json"), maxBytes: 2 << 20))
        let sourceBuild = try await api.build(branches.main)
        http.serve("downloader/sophon_chunk/api/getBuild", data: try evidence.readFile(at: SafeRelativePath("chunk-route/target-build.json"), maxBytes: 2 << 20))
        let targetBuild = try await api.build(targetBranch)
        var source: [PlannedCategory] = [], target: [PlannedCategory] = []
        for (name, build) in [("source", sourceBuild), ("target", targetBuild)] {
            for category in build.categories where ["game", "en-us"].contains(category.matchingField) {
                let bytes = try evidence.readFile(at: SafeRelativePath("chunk-route/\(name)-\(category.id).zst"), maxBytes: 32 << 20)
                http.serve(String(try category.manifestURL.path.dropFirst()), data: bytes)
                let planned = PlannedCategory(category: category, manifest: try await api.manifest(category).manifest)
                if name == "source" { source.append(planned) } else { target.append(planned) }
            }
        }
        http.serve("downloader/sophon_chunk/api/getPatchBuild", data: try evidence.readFile(at: SafeRelativePath("builder-check/patch-build.json"), maxBytes: 2 << 20))
        let patchBuild = try await api.patchBuild(targetBranch)
        var patch: [PlannedPatchCategory] = []
        for category in patchBuild.categories where ["game", "en-us"].contains(category.matchingField) {
            http.serve(String(try category.manifestURL.path.dropFirst()), data: try evidence.readFile(at: SafeRelativePath("builder-check/patch-\(category.id).zst"), maxBytes: 8 << 20))
            patch.append(PlannedPatchCategory(category: category, manifest: try await api.patchManifest(category).manifest))
        }
        let snapshot = InstalledSnapshot(categories: source), id = try SafeIdentifier("recorded-patch-budget")
        let chunk = try SophonPlanner.plan(id: id, target: target, installed: snapshot)
        let plan = try SophonPlanner.patchPlan(id: id, target: target, patch: patch, installed: snapshot, sourceTag: "7.1.0")
        for (name, candidate) in [("chunk", chunk), ("patch", plan)] {
            let whole = try SpaceBudget.required(plan: candidate, state: JournalState(), fs: fs).disk
            let batched = try SpaceBudget.batchedPreflight(plan: candidate, state: JournalState(), fs: fs, available: 12_000_000_000)
            if name == "patch" {
                #expect(batched.batches.count == candidate.files.count)
                #expect(batched.required < 12_000_000_000)
            }
            print("Recorded \(name): files=\(candidate.files.count), outputs=\(candidate.files.reduce(Int64(0)) { $0 + $1.size }), whole=\(whole), batched=\(batched.required), batches=\(batched.batches.count)")
        }
        #expect(plan.files.count == 1_214)
        #expect(plan.files.allSatisfy { file in
            guard case .patch(let source, _, _, _, _, _) = file.recipe else { return true }
            return source == file.path
        })
    }
}
