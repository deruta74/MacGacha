// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct RuntimeCatalogBundleUpgradeTests {
    @Test(arguments: ["success", "failure", "cancel"])
    func manualUpgradePreservesOldUntilVerifiedAndRollbackNeedsNoDownload(outcome: String) async throws {
        let f = try await BundleUpgradeFixture.make()
        #expect(f.model.runtimeCatalog?.catalog.revision == 3)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.new, pinned: false)
        #expect(await events.next() == f.new)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.runtimeInstallContexts[f.new]?.component.kind == .d3dmetal)
        if outcome == "success" { try f.publish(f.new); f.services.emit(.phase(.completed)) }
        else if outcome == "cancel" { f.model.cancel(f.new); f.services.emit(.phase(.cancelled)) }
        else { f.services.emit(.failed(.io("synthetic failure"))) }
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == (outcome == "success" ? f.new : f.old))
        if outcome == "success" {
            f.model.useRuntimeVersion(f.old)
            await f.model.catalogMutationTask?.value
            #expect(f.model.runtimeIsPinned(f.old))
            #expect(f.services.snapshot.bundleInstalls == [f.new])
        }
    }
    @Test func pinnedOldBundleSurvivesRefresh() async throws {
        let f = try await BundleUpgradeFixture.make(pinned: true)
        await f.model.refreshRuntimeCatalog(force: true)
        #expect(f.model.runtimeIsPinned(f.old))
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
    }
}

@MainActor func waitForCatalogModel(_ condition: () -> Bool) async throws {
    while !condition() {
        let changed = TestEvent()
        let ready = withObservationTracking { condition() } onChange: { changed.signal() }
        if ready { return }
        try await changed.wait()
    }
}

@MainActor struct BundleUpgradeFixture {
    let paths: AppPaths
    let model: AppModel
    let services: FakeRuntimeServices
    let old = "d3dmetal-wine11.20-gptk4.0b3"
    let new = "d3dmetal-wine11.20mg1.0-gptk4.0b3"
    static func make(pinned: Bool = false) async throws -> Self {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let oldManifest = try RuntimeManifest.load(from: root.appendingPathComponent("Packages/LauncherKit/Tests/RuntimeManagerTests/Fixtures/manifest-0.2.6.json"))
        let baseline = try await BundledRuntimeManifest.load()
        let metadata = try Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json"))
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("bundle-upgrade-\(UUID().uuidString)"))
        let store = RuntimeCatalogStore(root: paths.root)
        let service = RuntimeCatalogService(baseline: oldManifest, store: store)
        let old = try SafeIdentifier("d3dmetal-wine11.20-gptk4.0b3")
        _ = try await service.selectBundle(id: old, pinned: pinned, installedBundleIDs: [old])
        let services = FakeRuntimeServices()
        services.state.withLock { $0.accepted = true }
        let access = LiveRuntimeCatalogAccess(paths: paths, services: services, baseline: baseline, fetch: { metadata })
        let model = AppModel(paths: paths, manifest: baseline, services: services, catalogAccess: access, defaults: nil)
        model.autoUpdateDependencies = false
        try await model.flushLaunchSettings()
        let result = Self(paths: paths, model: model, services: services)
        try result.publish(result.old)
        await model.start(); await model.catalogRefreshTask?.value
        return result
    }
    func publish(_ id: String) throws {
        let root = paths.runtimes.appendingPathComponent("bundles/\(id)")
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(id), root: root, wineBinary: root.appendingPathComponent("bin/wine"),
            digest: try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64)), source: .download)
        services.state.withLock { $0.bundles[id] = bundle }
    }
}
