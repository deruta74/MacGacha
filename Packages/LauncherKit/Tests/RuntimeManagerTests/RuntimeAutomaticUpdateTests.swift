// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager

@Suite struct RuntimeAutomaticUpdateTests {
    private func snapshot(pinned: Bool = false) async throws -> RuntimeCatalogSnapshot {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let baseline = try RuntimeManifest.load(from: root.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let service = RuntimeCatalogService(baseline: baseline)
        let old = try SafeIdentifier("d3dmetal-wine11.20-gptk4.0b3")
        return try await service.selectBundle(id: old, pinned: pinned, installedBundleIDs: [old])
    }
    @Test func updatesOnlyInstalledUnpinnedSelections() async throws {
        let current = try await snapshot()
        let old = try #require(current.selectedBundle(for: .d3dmetal))
        #expect(RuntimeAutomaticUpdate.candidates(in: current, installedBundleIDs: [], installedComponentIDs: []).isEmpty)
        let candidates = RuntimeAutomaticUpdate.candidates(in: current, installedBundleIDs: [old.id], installedComponentIDs: [])
        #expect(candidates.count == 1)
        #expect(candidates.first?.previousID == old.id)
        #expect(candidates.first?.targetID.rawValue == "d3dmetal-wine11.20mg1.0-gptk4.0b3")
        let pinned = try await snapshot(pinned: true)
        #expect(RuntimeAutomaticUpdate.candidates(in: pinned, installedBundleIDs: [old.id], installedComponentIDs: []).isEmpty)
    }
    @Test func absentLegacyHelpersMigrateWithoutInstallation() async throws {
        let current = try await snapshot()
        var selections = current.selections
        selections.helpers[.surroundAudio] = .init(id: try SafeIdentifier("surround-audio-wine-11.20-1"))
        selections.helpers[.crypt32Fix] = .init(id: try SafeIdentifier("crypt32-fix-wine-11.20-1"))
        let legacy = try current.replacingSelections(selections)
        let old = try #require(legacy.selectedBundle(for: .d3dmetal))
        let candidates = RuntimeAutomaticUpdate.candidates(in: legacy, installedBundleIDs: [old.id], installedComponentIDs: [])
        let bundleUpdate = try #require(candidates.first { $0.backend == .d3dmetal })
        let target = try bundleUpdate.selections(in: legacy)
        #expect(target.helpers[.surroundAudio]?.id.rawValue == SurroundAudio.componentID)
        #expect(target.helpers[.crypt32Fix]?.id.rawValue == Crypt32Fix.componentID)
        #expect(candidates.count == 1)
    }

    @Test func incompatiblePinnedHelperPreventsBundleUpdate() async throws {
        let current = try await snapshot()
        var selections = current.selections
        selections.helpers[.surroundAudio] = .init(id: try SafeIdentifier("surround-audio-wine-11.20-1"), pinned: true)
        let pinned = try current.replacingSelections(selections)
        let old = try #require(current.selectedBundle(for: .d3dmetal))
        #expect(RuntimeAutomaticUpdate.candidates(in: pinned, installedBundleIDs: [old.id], installedComponentIDs: []).isEmpty)
    }
}
