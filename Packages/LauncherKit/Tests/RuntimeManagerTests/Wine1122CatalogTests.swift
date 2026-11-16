// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager

@Suite struct Wine1122CatalogTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private var currentMetadata: Data {
        get throws { try Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json")) }
    }
    private var baseline: RuntimeManifest {
        get throws { try RuntimeManifest.load(from: root.appendingPathComponent("App/Resources/runtime-manifest.json")) }
    }

    @Test func previousAppRejectsNewProfilesWithoutChangingInstalledSelections() async throws {
        let old = try JSONDecoder().decode(RuntimeManifest.self, from: fixture("manifest-0.3.1"))
        let service = RuntimeCatalogService(baseline: old)
        let previous = try await service.accept(metadata: fixture("catalog-r3"))
        await #expect(throws: (any Error).self) { try await service.accept(metadata: currentMetadata) }
        #expect(try await service.snapshot().selections == previous.selections)
        #expect(try await service.snapshot().catalog.revision == 3)
    }

    @Test func revisionFourPreservesHistoryPinsAndExplicitRollback() async throws {
        let service = try RuntimeCatalogService(baseline: baseline)
        _ = try await service.accept(metadata: fixture("catalog-r3"))
        let old = try SafeIdentifier("d3dmetal-wine11.20mg1.0-gptk4.0b3")
        let pinned = try await service.selectBundle(id: old, pinned: true, installedBundleIDs: [old])
        let updated = try await service.accept(metadata: currentMetadata)
        #expect(updated.catalog.revision == 4)
        #expect(updated.selections == pinned.selections)
        let newer = try SafeIdentifier("d3dmetal-wine11.22mg1.0-gptk4.0b3")
        _ = try await service.selectBundle(id: newer, pinned: false, installedBundleIDs: [old, newer])
        let rollback = try await service.selectBundle(id: old, pinned: true, installedBundleIDs: [old, newer])
        #expect(rollback.selectedBundle(for: .d3dmetal)?.id == old)
        #expect(rollback.selections.bundles[.d3dmetal]?.pinned == true)
        #expect(rollback.helper(kind: .crypt32Fix, for: old)?.id.rawValue == Crypt32Fix.componentID)
        #expect(rollback.helper(kind: .surroundAudio, for: old)?.id.rawValue == SurroundAudio.componentID)
    }

    @Test(arguments: [RuntimeBackend.dxmt, .d3dmetal])
    func newProfilesRetainGenericHelpersAndExcludeWine1120Overlays(backend: RuntimeBackend) async throws {
        let service = try RuntimeCatalogService(baseline: baseline)
        let snapshot = try await service.accept(metadata: currentMetadata)
        let bundle = try #require(snapshot.recommendedBundle(for: backend))
        #expect(bundle.components.contains(try SafeIdentifier("wine-11.22-macgacha-1.0")))
        #expect(snapshot.profile(for: bundle.id) == bundle.id)
        for kind in [ComponentKind.jadeite, .steamShim, .genshinFps] {
            #expect(snapshot.helper(kind: kind, for: bundle.id) != nil)
        }
        #expect(snapshot.helper(kind: .crypt32Fix, for: bundle.id) == nil)
        #expect(snapshot.helper(kind: .surroundAudio, for: bundle.id)?.id.rawValue == (backend == .d3dmetal ? SurroundAudio.wine1122ComponentID : nil))
        for game in GameDefinition.all {
            #expect(!Crypt32Fix.applies(game: game.id, backend: backend, bundleID: bundle.id.rawValue))
            #expect(SurroundAudio.applies(game: game.id, backend: backend, bundleID: bundle.id.rawValue) ==
                (backend == .d3dmetal && (game.family == .genshin || game.family == .zzz)))
        }
    }
}
