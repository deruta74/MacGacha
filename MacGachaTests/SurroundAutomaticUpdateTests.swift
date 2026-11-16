// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Dispatch
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct SurroundAutomaticUpdateTests {
    @Test(arguments: ["genshin", "genshin-cn", "zzz", "zzz-cn"])
    func enabledSurroundKeepsCompatibleWineUntilDisabled(game: String) async throws {
        let f = try await SurroundUpgradeFixture.make()
        try f.setSurround(true, game: game)
        try await f.model.flushLaunchSettings()
        f.model.autoUpdateDependencies = true
        try await waitForCatalogModel {
            !f.model.dependencyAutoUpdateReservation || f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") != nil
        }
        if f.model.dependencyAutoUpdateReservation {
            f.model.dependencyAutoUpdateTask?.cancel()
            f.services.emit(.phase(.cancelled))
        }
        await f.model.dependencyAutoUpdateTask?.value
        try #require(f.services.snapshot.bundleInstalls.isEmpty)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.offersSurround(for: game))
        #expect(!f.model.runtimeIsPinned(f.old))

        try f.setSurround(false, game: game)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.scheduleDependencyAutoUpdates()
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
    }

    @Test(arguments: ["staging", "waiting"])
    func enablingSurroundAfterPlanningKeepsWorkingWine(phase: String) async throws {
        let f = try await SurroundUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        if phase == "waiting" { f.model.launchSlotOwner = "genshin" }
        try f.publish(f.new); f.services.emit(.phase(.completed))
        if phase == "waiting" {
            try await waitForCatalogModel {
                f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .waitingToActivate(id: f.new)
            }
        }
        try f.setSurround(true, game: "genshin")
        f.model.launchSlotOwner = nil
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(try await f.model.catalogAccess?.snapshot().selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.runtimeCatalogMutationID == nil)
        #expect(try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: f.paths).load().replacements.isEmpty })
    }

    @Test(arguments: ["dxmt", "starrail"])
    func unrelatedSurroundPreferenceDoesNotBlockD3DMetalUpgrade(preference: String) async throws {
        let f = try await SurroundUpgradeFixture.make()
        try f.setSurround(true, game: preference == "starrail" ? "starrail" : "genshin",
            backend: preference == "dxmt" ? .dxmt : .d3dmetal)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
    }

    @Test(arguments: [false, true])
    func enablingSurroundDuringSelectionWriteRestoresCompatibleWine(failAfterWrite: Bool) async throws {
        let bytes = Mutex<Data?>(nil), armed = Mutex(false)
        let entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let f = try await SurroundUpgradeFixture.make(storeFactory: { _ in
            RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
                bytes.withLock { $0 = data }
                if armed.withLock({ value in let previous = value; value = false; return previous }) {
                    entered.continuation.yield(())
                    guard release.wait(timeout: .now() + 30) == .success else { throw LauncherError.io("Test deadline") }
                    if failAfterWrite { throw LauncherError.io("Failure after replacement") }
                }
            })
        })
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        armed.withLock { $0 = true }
        try f.publish(f.new); f.services.emit(.phase(.completed))
        for await _ in entered.stream { break }
        try f.setSurround(true, game: "genshin")
        release.signal()
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(try await f.model.catalogAccess?.snapshot().selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.offersSurround(for: "genshin"))
        #expect(f.model.runtimeCatalogMutationID == nil)
    }

    @Test func enablingSurroundDuringAutomaticConsentSetupKeepsCompatibleWine() async throws {
        let f = try await SurroundUpgradeFixture.make()
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        var settings = f.model.launchSettings(for: "genshin")
        settings.backend = .d3dmetal
        settings.compatibilityPatches = false
        try f.model.saveLaunchSettings(settings, for: "genshin")
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.installRecommended(for: "genshin")
        try await waitForCatalogModel { f.model.consentRequest != nil }
        f.model.respondToConsent(accept: true)
        #expect(await events.next() == f.new)
        try f.setSurround(true, game: "genshin")
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(try await f.model.catalogAccess?.snapshot().selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
    }

    @Test func explicitVersionSelectionRemainsAvailableWithoutForeignSurroundOverlay() async throws {
        let f = try await SurroundUpgradeFixture.make()
        try f.setSurround(true, game: "genshin")
        try f.publish(f.new)
        try await f.model.scanAndApply()
        f.model.useRuntimeVersion(f.new)
        await f.model.catalogMutationTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        #expect(!f.model.offersSurround(for: "genshin"))
        let target = try #require(f.model.runtimeCatalog)
        #expect(target.helper(kind: .surroundAudio, for: try SafeIdentifier(f.new)) == nil)
        #expect(f.model.surroundSound(for: "genshin"))
    }
}

@MainActor private struct SurroundUpgradeFixture {
    let paths: AppPaths
    let model: AppModel
    let services: FakeRuntimeServices
    let old = "d3dmetal-wine11.20mg1.0-gptk4.0b3"
    let new = "d3dmetal-future-without-surround"

    static func make(storeFactory: ((AppPaths) -> RuntimeCatalogStore)? = nil) async throws -> Self {
        let resources = Bundle(for: SurroundUpgradeResources.self)
        let bytes = try Data(contentsOf: #require(resources.url(forResource: "runtime-catalog-r3", withExtension: "json")))
        let previous = try JSONDecoder().decode(RuntimeCatalog.self, from: bytes)
        let template = try #require(previous.manifest.bundles.first { $0.id.rawValue == "d3dmetal-wine11.20mg1.0-gptk4.0b3" })
        let target = try RuntimeBundle(id: SafeIdentifier("d3dmetal-future-without-surround"), displayName: "Wine test candidate",
            backend: .d3dmetal, components: template.components, environment: template.environment)
        // Only the profile changes. No foreign Wine ABI is claimed for the 11.20 helper.
        let baseline = try RuntimeManifest(components: previous.manifest.components,
            bundles: previous.manifest.bundles.filter { $0.id != target.id } + [target])
        var recommendations = previous.recommendedBundles
        recommendations[.d3dmetal] = target.id
        let catalog = RuntimeCatalog(revision: previous.revision + 1, manifest: baseline,
            bundleBindings: previous.bundleBindings.filter { $0.bundleID != target.id } + [.init(bundleID: target.id, profileID: target.id)],
            helperBindings: previous.helperBindings, recommendedBundles: recommendations,
            recommendedHelpers: previous.recommendedHelpers)
        let metadata = try JSONEncoder().encode(catalog)
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("surround-upgrade-\(UUID().uuidString)"))
        let store = storeFactory?(paths) ?? RuntimeCatalogStore(root: paths.root)
        let service = RuntimeCatalogService(baseline: baseline, store: store)
        let old = try SafeIdentifier("d3dmetal-wine11.20mg1.0-gptk4.0b3")
        _ = try await service.selectBundle(id: old, pinned: false, installedBundleIDs: [old])
        let services = FakeRuntimeServices()
        let helpers = try baseline.components.filter { [Crypt32Fix.componentID, SurroundAudio.componentID].contains($0.id.rawValue) }.map {
            try InstalledComponent(kind: $0.kind, version: $0.version.rawValue, installedAt: .now, source: .download)
        }
        services.state.withLock { $0.accepted = true; $0.components = helpers }
        let access = LiveRuntimeCatalogAccess(signatureVerifier: nil, paths: paths, services: services, baseline: baseline,
            store: store, fetch: { metadata })
        let model = AppModel(paths: paths, manifest: baseline, services: services, catalogAccess: access,
            defaults: nil, rosettaProbe: UnknownRosettaProbe())
        model.autoUpdateDependencies = false
        try await model.flushLaunchSettings()
        let result = Self(paths: paths, model: model, services: services)
        try result.publish(result.old)
        await model.start()
        await model.catalogRefreshTask?.value
        try #require(model.runtimeCatalog?.catalog.revision == previous.revision + 1)
        return result
    }

    func setSurround(_ enabled: Bool, game: String, backend: RuntimeBackend = .d3dmetal) throws {
        var settings = model.launchSettings(for: game)
        settings.backend = backend; settings.surroundSound = enabled
        try model.saveLaunchSettings(settings, for: game)
    }

    func publish(_ id: String) throws {
        let root = paths.runtimes.appendingPathComponent("bundles/\(id)")
        let digest = try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64))
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(id), root: root,
            wineBinary: root.appendingPathComponent("bin/wine"), digest: digest, source: .download)
        services.state.withLock { $0.bundles[id] = bundle }
    }
}

private final class SurroundUpgradeResources {}
