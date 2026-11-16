// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager

@Suite struct SurroundABIUpdateTests {
    let old = try! SafeIdentifier("d3dmetal-wine11.20mg1.0-gptk4.0b3")
    let new = try! SafeIdentifier("d3dmetal-wine11.22mg1.0-gptk4.0b3")
    let oldHelper = try! SafeIdentifier("surround-audio-wine-11.20-3")
    let newHelper = try! SafeIdentifier("surround-audio-wine-11.22-1")

    private func snapshot() async throws -> RuntimeCatalogSnapshot {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let manifest = try RuntimeManifest.load(from: root.appendingPathComponent("App/Resources/runtime-manifest.json"))
        return try await RuntimeCatalogService(baseline: manifest).snapshot()
    }

    @Test func baselineScopesAndAutomaticUpgradeAreABIMatched() async throws {
        let baseline = try await snapshot()
        #expect(baseline.selectedHelper(for: .surroundAudio)?.id == newHelper)
        #expect(baseline.helper(kind: .surroundAudio, for: new)?.id == newHelper)
        #expect(baseline.helper(kind: .surroundAudio, for: old) == nil)
        let legacy = try baseline.selectingBundle(id: old, pinned: false)
        #expect(legacy.selectedHelper(for: .surroundAudio)?.id == oldHelper)
        let updates = RuntimeAutomaticUpdate.candidates(in: legacy, installedBundleIDs: [old], installedComponentIDs: [oldHelper])
        let upgrade = try #require(updates.first { $0.backend == .d3dmetal })
        #expect(upgrade.helperUpdates.map(\.targetID) == [newHelper])
        let target = try legacy.replacingSelections(upgrade.selections(in: legacy))
        #expect(target.selectedBundle(for: .d3dmetal)?.id == new)
        #expect(target.helper(kind: .surroundAudio, for: new)?.id == newHelper)
        #expect(try target.selectingBundle(id: old, pinned: true).helper(kind: .surroundAudio, for: old)?.id == oldHelper)
    }

    @Test func pinnedOrChangedSourceHelperRejectsPairedUpgrade() async throws {
        let baseline = try await snapshot()
        let legacy = try baseline.selectingBundle(id: old, pinned: false)
        let update = try #require(RuntimeAutomaticUpdate.candidates(in: legacy,
            installedBundleIDs: [old], installedComponentIDs: [oldHelper]).first { $0.backend == .d3dmetal })
        var selections = legacy.selections
        selections.helpers[.surroundAudio] = .init(id: oldHelper, pinned: true)
        let pinned = try legacy.replacingSelections(selections)
        #expect(throws: (any Error).self) { try pinned.selectingBundle(id: new, pinned: false) }
        #expect(throws: (any Error).self) { try update.selections(in: pinned) }
        #expect(RuntimeAutomaticUpdate.candidates(in: pinned, installedBundleIDs: [old], installedComponentIDs: [oldHelper]).isEmpty)
    }

    @Test(arguments: ["genshin", "genshin-cn", "zzz", "zzz-cn"])
    func surroundIsOfferedOnNewProfile(game: String) {
        #expect(SurroundAudio.applies(game: game, backend: .d3dmetal, bundleID: new.rawValue))
        #expect(!SurroundAudio.applies(game: game, backend: .dxmt, bundleID: new.rawValue))
    }

    @Test func firstScanRetainsInstalledLegacyBundleWithoutOptionalHelper() async throws {
        let baseline = try await snapshot()
        let service = RuntimeCatalogService(baseline: baseline.catalog.manifest, installedBundleIDs: [old])
        let adopted = try await service.snapshot()
        #expect(adopted.selectedBundle(for: .d3dmetal)?.id == old)
        #expect(adopted.helper(kind: .surroundAudio, for: old)?.id == oldHelper)
    }

    @Test func dxmtUpgradeRetainsSurroundPreferenceForUnchangedLegacyD3DMetal() async throws {
        let baseline = try await snapshot()
        let oldDXMT = try SafeIdentifier("dxmt-wine11.0cx-dxmt0.80")
        let legacy = try baseline.selectingBundle(id: old, pinned: false).selectingBundle(id: oldDXMT, pinned: false)
        let update = try #require(RuntimeAutomaticUpdate.candidates(in: legacy,
            installedBundleIDs: [oldDXMT], installedComponentIDs: []).first { $0.backend == .dxmt })
        let target = try legacy.replacingSelections(update.selections(in: legacy))
        #expect(target.selectedBundle(for: .d3dmetal)?.id == old)
        #expect(target.helper(kind: .surroundAudio, for: old)?.id == oldHelper)
    }
}
