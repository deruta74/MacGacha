// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct DependencyImportedUpdateTests {
    @Test func wineOnlyChangeCarriesTheOwnersImportedFramework() async throws {
        let f = try await BundleUpgradeFixture.make()
        try f.publish(f.old, source: .importFromGPTK); try await f.model.scanAndApply()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        #expect(f.services.snapshot.carriedImports[f.new] == f.old)
        try f.publish(f.new, source: .importFromGPTK); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        #expect(f.model.installedBundles[f.new]?.source == .importFromGPTK)
    }
    @Test func graphicsChangeOffersWithoutBlockingPlayAndDeclineIsPerVersion() async throws {
        let f = try await BundleUpgradeFixture.make()
        try f.publish(f.old, source: .importFromGPTK); try await f.model.scanAndApply()
        let first = try await offerGraphics("4.0b4", fixture: f)
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .graphicsUpdateOffered(id: first))
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(!f.model.runtimeSetupIsUpdate(for: "genshin"))
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        f.model.declineGraphicsUpdate(for: "bundle-d3dmetal")
        try await waitForCatalogModel { f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .graphicsUpdateDeclined(id: first) }
        let paths = f.paths
        #expect(try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load().declinedGraphicsVersions.contains("4.0b4") })
        await f.model.refreshRuntimeCatalog(force: true); await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .graphicsUpdateDeclined(id: first))
        let next = try await offerGraphics("4.0b5", fixture: f)
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .graphicsUpdateOffered(id: next))
    }

    private func offerGraphics(_ version: String, fixture f: BundleUpgradeFixture) async throws -> String {
        let current = try #require(f.model.runtimeCatalog)
        let graphics = try #require(current.catalog.manifest.components.first { $0.id.rawValue == "d3dmetal-4.0b3" })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(graphics)) as? [String: Any])
        object["id"] = "d3dmetal-" + version; object["version"] = version
        let nextGraphics = try JSONDecoder().decode(RuntimeComponent.self, from: JSONSerialization.data(withJSONObject: object))
        let id = "d3dmetal-offer-" + version
        let bundle = try RuntimeBundle(id: SafeIdentifier(id), displayName: "D3DMetal", backend: .d3dmetal,
            components: [SafeIdentifier("wine-11.20-macgacha-1.0"), nextGraphics.id])
        let old = current.catalog
        var recommended = old.recommendedBundles; recommended[.d3dmetal] = bundle.id
        let next = RuntimeCatalog(revision: old.revision + 1,
            manifest: try RuntimeManifest(components: old.manifest.components + [nextGraphics], bundles: old.manifest.bundles + [bundle]),
            bundleBindings: old.bundleBindings + [.init(bundleID: bundle.id, profileID: try SafeIdentifier(f.new))],
            helperBindings: old.helperBindings, recommendedBundles: recommended, recommendedHelpers: old.recommendedHelpers)
        let data = try JSONEncoder().encode(next)
        f.metadata.bytes.withLock { $0 = data }
        await f.model.refreshRuntimeCatalog(force: true)
        return id
    }
}
