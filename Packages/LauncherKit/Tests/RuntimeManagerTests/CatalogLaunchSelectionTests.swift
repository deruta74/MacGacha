// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Launch
@testable import RuntimeManager

@Suite(.timeLimit(.minutes(1))) struct CatalogLaunchSelectionTests {
    @Test func liveSelectionUsesSharedSnapshotAndPinsActualInstalledVersions() async throws {
        let f = try BundleFixture()
        _ = try await f.manager.install(f.bundle)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.bundle)) as? [String: Any])
        object["id"] = "dxmt-catalog-revision3"
        let alternative = try JSONDecoder().decode(RuntimeBundle.self, from: JSONSerialization.data(withJSONObject: object))
        let manifest = try RuntimeManifest(components: f.manifest.components, bundles: [f.bundle, alternative])
        let baseline = RuntimeCatalog.bundled(f.manifest)
        let catalog = RuntimeCatalog(revision: 1, manifest: manifest,
            bundleBindings: baseline.bundleBindings + [.init(bundleID: alternative.id, profileID: f.bundle.id)],
            helperBindings: [], recommendedBundles: [.dxmt: alternative.id], recommendedHelpers: [:])
        let service = RuntimeCatalogService(baseline: f.manifest, store: RuntimeCatalogStore(root: f.temp.url), installedBundleIDs: [f.bundle.id])
        let runtimes = LiveLaunchRuntimes(paths: f.store.paths, manager: f.manager, store: f.store, snapshot: { try await service.snapshot() })
        _ = try await service.accept(metadata: JSONEncoder().encode(catalog))
        let previous = try await runtimes.selection(for: LaunchSettings(backend: .dxmt, retina: true, frameLimit: nil, directX12: false, compatibilityPatches: false))
        #expect(previous.bundle.id == f.bundle.id)
        let manager = RuntimeBundleManager(manifest: manifest, store: f.store, consent: f.consent, installer: f.installer)
        _ = try await manager.install(alternative)
        _ = try await service.selectBundle(id: alternative.id, pinned: true, installedBundleIDs: [f.bundle.id, alternative.id])
        let selected = try await runtimes.selection(for: LaunchSettings(backend: .dxmt, retina: true, frameLimit: nil, directX12: false, compatibilityPatches: false))
        #expect(selected.bundle.id == alternative.id)
        #expect(selected.runtimeProfileID == f.bundle.id.rawValue)
        #expect(selected.componentIDs == alternative.components.map(\.rawValue))
        #expect(try await f.manager.installed(f.bundle) != nil)
        let prefixes = PrefixManager(paths: f.store.paths, runner: SystemProcessRunner())
        let prefix = try await prefixes.prefixURL(game: "genshin", bundle: selected.bundle)
        #expect(prefix.lastPathComponent == "genshin-\(alternative.id)")
        let pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: selected.componentIDs)
        #expect(throws: (any Error).self) { try f.store.remove(try #require(f.store.installed().first)) }
        withExtendedLifetime(pin) {}
    }
}
