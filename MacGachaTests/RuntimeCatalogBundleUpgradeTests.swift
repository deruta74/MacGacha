// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Testing
import LauncherCore
import RuntimeManager
import Synchronization
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
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changes.continuation.finish() }
        let ready = withObservationTracking { condition() } onChange: {
            changes.continuation.yield(())
            changes.continuation.finish()
        }
        if ready { return }
        for await _ in changes.stream { break }
        try Task.checkCancellation()
    }
}

@MainActor struct BundleUpgradeFixture {
    let paths: AppPaths
    let model: AppModel
    let services: FakeRuntimeServices
    let metadata: BundleCatalogMetadata
    let old = "d3dmetal-wine11.20-gptk4.0b3"
    let new = "d3dmetal-wine11.20mg1.0-gptk4.0b3"
    static func make(pinned: Bool = false, rosettaProbe: any RosettaProbing = UnknownRosettaProbe(), installHelpers: Bool = true, storeFactory: ((AppPaths) -> RuntimeCatalogStore)? = nil) async throws -> Self {
        let resources = Bundle(for: BundleUpgradeResources.self)
        let oldManifest = try RuntimeManifest.load(from: #require(resources.url(forResource: "manifest-0.2.6", withExtension: "json")))
        let baseline = try await BundledRuntimeManifest.load()
        let metadata = try Data(contentsOf: #require(resources.url(forResource: "runtime-catalog", withExtension: "json")))
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("bundle-upgrade-\(UUID().uuidString)"))
        let store = storeFactory?(paths) ?? RuntimeCatalogStore(root: paths.root)
        let service = RuntimeCatalogService(baseline: oldManifest, store: store)
        let old = try SafeIdentifier("d3dmetal-wine11.20-gptk4.0b3")
        _ = try await service.selectBundle(id: old, pinned: pinned, installedBundleIDs: [old])
        // Wine-only upgrades require compatible helpers already selected.
        let migrated = RuntimeCatalogService(baseline: baseline, store: store)
        let helperIDs = try [Crypt32Fix.componentID, SurroundAudio.componentID].map(SafeIdentifier.init)
        for id in helperIDs where installHelpers {
            _ = try await migrated.selectHelper(id: id, pinned: false, installedComponentIDs: Set(helperIDs))
        }
        let services = FakeRuntimeServices()
        let helpers = try baseline.components.filter { helperIDs.contains($0.id) }.map {
            try InstalledComponent(kind: $0.kind, version: $0.version.rawValue, installedAt: .now, source: .download)
        }
        services.state.withLock { $0.accepted = true; $0.components = installHelpers ? helpers : [] }
        let metadataState = BundleCatalogMetadata(metadata)
        let access = LiveRuntimeCatalogAccess(signatureVerifier: nil, paths: paths, services: services, baseline: baseline, store: store, fetch: { metadataState.bytes.withLock { $0 } })
        let model = AppModel(paths: paths, manifest: baseline, services: services, catalogAccess: access, defaults: nil, rosettaProbe: rosettaProbe)
        model.autoUpdateDependencies = false
        try await model.flushLaunchSettings()
        let result = Self(paths: paths, model: model, services: services, metadata: metadataState)
        try result.publish(result.old)
        await model.start()
        await model.catalogRefreshTask?.value
        try #require(model.runtimeCatalog?.catalog.revision == 3)
        if installHelpers { _ = try model.runtimeVersionTarget(result.new, pinned: false) }
        return result
    }
    func publish(_ id: String, source: SourceMode = .download) throws {
        let root = paths.runtimes.appendingPathComponent("bundles/\(id)")
        let digest = try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64))
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(id), root: root, wineBinary: root.appendingPathComponent("bin/wine"),
            digest: digest, source: source, importedFramework: source == .importFromGPTK ? ImportedD3DMetalIdentity(version: "4.0b3", digest: digest) : nil)
        services.state.withLock { $0.bundles[id] = bundle }
    }
}

final class BundleCatalogMetadata: Sendable {
    let bytes: Mutex<Data>
    init(_ data: Data) { bytes = Mutex(data) }
}

private final class BundleUpgradeResources {}
