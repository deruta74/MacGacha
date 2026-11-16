// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct SurroundMatchedUpgradeTests {
    @Test(arguments: ["starrail", "genshin", "genshin-cn", "zzz", "zzz-cn"], ["success", "failure", "cancel"])
    func consentDrivenSetupIncludesPairedHelperWithoutGameOptIn(game: String, outcome: String) async throws {
        let f = try await MatchedSurroundFixture.make()
        var settings = f.model.launchSettings(for: game)
        settings.backend = .d3dmetal; settings.surroundSound = false; settings.compatibilityPatches = false
        f.model.launchSettingsCache[game] = settings
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        let previous = try #require(f.model.runtimeCatalog)
        let target = try #require(f.model.dependencySetupTarget(for: game))
        // Neither the retired crypt32 correction nor the disabled FPS option
        // changes selection with this Wine upgrade.
        for kind in [ComponentKind.crypt32Fix, .genshinFps] {
            #expect(target.selections.helpers[kind] == previous.selections.helpers[kind])
        }
        let plan = try #require(f.model.runtimeSetupPlan(for: game))
        try #require(plan.items.map(\.id) == [f.new, SurroundAudio.wine1122ComponentID])
        #expect(plan.needsAppleTerms)
        let helper = try #require(f.manifest.components.first { $0.id.rawValue == SurroundAudio.wine1122ComponentID })
        #expect(plan.items.last?.size == helper.size)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.installRecommended(for: game)
        try await waitForCatalogModel { f.model.consentRequest != nil }
        f.model.respondToConsent(accept: true)
        #expect(await events.next() == f.new)
        try f.publishBundle(f.new); f.services.emit(.phase(.completed))
        #expect(await events.next() == SurroundAudio.wine1122ComponentID)
        #expect(f.model.runtimeCatalog?.selections == previous.selections)
        if outcome == "success" {
            try f.publishHelper(SurroundAudio.wine1122ComponentID); f.services.emit(.phase(.completed))
        } else if outcome == "failure" { f.services.fail(.io("Synthetic helper failure")) }
        else { f.model.cancelRuntimeSetup(for: game); f.services.emit(.phase(.cancelled)) }
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        let persisted = try await f.model.catalogAccess?.snapshot()
        #expect(persisted?.selections == (outcome == "success" ? target.selections : previous.selections))
        #expect(f.services.snapshot.installs.count == 1)
        if outcome == "success" { #expect(f.model.lastError == nil) }
    }

    @Test(arguments: [false, true])
    func consentDrivenSetupDeduplicatesAndOmitsVerifiedPairedHelper(alreadyInstalled: Bool) async throws {
        let f = try await MatchedSurroundFixture.make()
        if alreadyInstalled { try f.publishHelper(SurroundAudio.wine1122ComponentID) }
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        let plan = try #require(f.model.runtimeSetupPlan(for: "genshin"))
        let helperItems = plan.items.filter { $0.id == SurroundAudio.wine1122ComponentID }
        #expect(helperItems.count == (alreadyInstalled ? 0 : 1))
    }

    @Test func consentDrivenSetupDoesNotInstallUnusedHelperPreferences() async throws {
        let f = try await MatchedSurroundFixture.make()
        var settings = f.model.launchSettings(for: "starrail")
        settings.backend = .d3dmetal; settings.compatibilityPatches = false
        f.model.launchSettingsCache["starrail"] = settings
        f.services.state.withLock { $0.accepted = false; $0.components = [] }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        let target = try #require(f.model.dependencySetupTarget(for: "starrail"))
        #expect(target.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.wine1122ComponentID)
        #expect(f.model.runtimeSetupPlan(for: "starrail")?.items.map(\.id) == [f.new])
    }

    @Test(arguments: ["genshin", "genshin-cn", "zzz", "zzz-cn"])
    func enabledSurroundUpgradesWithMatchedModule(game: String) async throws {
        let f = try await MatchedSurroundFixture.make(game: game)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publishBundle(f.new); f.services.emit(.phase(.completed))
        #expect(await events.next() == SurroundAudio.wine1122ComponentID)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        try f.publishHelper(SurroundAudio.wine1122ComponentID); f.services.emit(.phase(.completed))
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.wine1122ComponentID)
        #expect(f.model.offersSurround(for: game) && f.model.surroundSound(for: game))
        let retained = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: f.paths).load() }
        #expect(Set(retained.replacements.map(\.previousID)) == [f.old, SurroundAudio.componentID])
        f.model.autoUpdateDependencies = false
        f.model.useRuntimeVersion(f.old)
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeIsPinned(f.old))
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.componentID)
        #expect(f.model.offersSurround(for: game))
    }

    @Test(arguments: ["failure", "cancel", "missing-receipt"])
    func unfinishedHelperNeverActivatesBundle(outcome: String) async throws {
        let f = try await MatchedSurroundFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publishBundle(f.new); f.services.emit(.phase(.completed))
        #expect(await events.next() == SurroundAudio.wine1122ComponentID)
        if outcome == "failure" { f.services.fail(.io("Synthetic helper failure")) }
        else if outcome == "cancel" { f.model.dependencyAutoUpdateTask?.cancel(); f.services.emit(.phase(.cancelled)) }
        else { f.services.emit(.phase(.completed)) }
        await f.model.dependencyAutoUpdateTask?.value
        let persisted = try await f.model.catalogAccess?.snapshot()
        #expect(persisted?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(persisted?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.componentID)
        #expect(f.model.runtimeCatalogMutationID == nil)
    }

    @Test func installedBundleStillInstallsMissingPairedHelperBeforeManualActivation() async throws {
        let f = try await MatchedSurroundFixture.make()
        try f.publishBundle(f.new); try await f.model.scanAndApply()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.new)
        #expect(await events.next() == SurroundAudio.wine1122ComponentID)
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        try f.publishHelper(SurroundAudio.wine1122ComponentID); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.wine1122ComponentID)
    }

    @Test(arguments: [false, true])
    func cancellingPairedSetupKeepsPreviousSelection(afterReceipt: Bool) async throws {
        let f = try await MatchedSurroundFixture.make()
        try f.publishBundle(f.new); try await f.model.scanAndApply()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.new)
        #expect(await events.next() == SurroundAudio.wine1122ComponentID)
        if afterReceipt {
            try f.publishHelper(SurroundAudio.wine1122ComponentID)
            f.services.state.withLock { $0.holdNextScan = true }
            var scans = f.services.heldScanEvents.stream.makeAsyncIterator()
            f.services.emit(.phase(.completed))
            _ = await scans.next()
            f.model.cancel(SurroundAudio.wine1122ComponentID)
            f.services.releaseScan()
        } else {
            f.model.cancel(SurroundAudio.wine1122ComponentID)
            f.services.emit(.phase(.cancelled))
        }
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(try await f.model.catalogAccess?.snapshot().selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.componentID)
    }

    @Test func importedBundleSetupCapturesMatchedHelperAndCanDecline() async throws {
        let f = try await MatchedSurroundFixture.make()
        f.services.state.withLock { $0.accepted = false }
        f.model.importGPTK(f.new)
        #expect(f.model.runtimeSetupChains["catalog-" + f.new]?.plan.items.map(\.id) == [f.new, SurroundAudio.wine1122ComponentID])
        try await waitForCatalogModel { f.model.consentRequest != nil }
        f.model.respondToConsent(accept: false)
        try await waitForCatalogModel { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
    }

    @Test func pairedStagingFailureDiscardsPreparedBundle() async throws {
        let f = try await MatchedSurroundFixture.make()
        let current = try #require(f.model.runtimeCatalog)
        let update = try #require(RuntimeAutomaticUpdate.candidates(in: current,
            installedBundleIDs: [try SafeIdentifier(f.old)], installedComponentIDs: [try SafeIdentifier(SurroundAudio.componentID)]).first)
        let discarded = Mutex<[String]>([])
        await #expect(throws: (any Error).self) {
            _ = try await DependencyStagingHandle.staging(update) { item in
                if item.kind == .surroundAudio { throw LauncherError.io("Synthetic helper failure") }
                return DependencyStagingHandle(publish: {}, discard: { discarded.withLock { $0.append(item.targetID.rawValue) } })
            }
        }
        #expect(discarded.withLock { $0 } == [f.new])
    }

    @Test func cancellationDuringPairedStagingDiscardsAllPreparedItems() async throws {
        let f = try await MatchedSurroundFixture.make()
        let current = try #require(f.model.runtimeCatalog)
        let update = try #require(RuntimeAutomaticUpdate.candidates(in: current,
            installedBundleIDs: [try SafeIdentifier(f.old)], installedComponentIDs: [try SafeIdentifier(SurroundAudio.componentID)]).first)
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let discarded = Mutex<[String]>([])
        let task = Task {
            try await DependencyStagingHandle.staging(update) { item in
                if item.kind == .surroundAudio {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                }
                return DependencyStagingHandle(publish: {}, discard: {
                    #expect(!Task.isCancelled)
                    discarded.withLock { $0.append(item.targetID.rawValue) }
                })
            }
        }
        for await _ in entered.stream { break }
        task.cancel(); release.continuation.finish()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(discarded.withLock { $0 } == [f.new, SurroundAudio.wine1122ComponentID])
    }
}

@MainActor private struct MatchedSurroundFixture {
    let paths: AppPaths
    let model: AppModel
    let services: FakeRuntimeServices
    let manifest: RuntimeManifest
    let old = "d3dmetal-wine11.20mg1.0-gptk4.0b3"
    let new = SurroundAudio.wine1122BundleID

    static func make(game: String = "genshin") async throws -> Self {
        let baseline = try await BundledRuntimeManifest.load()
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("surround-matched-\(UUID().uuidString)"))
        let services = FakeRuntimeServices()
        services.state.withLock { $0.accepted = true }
        let store = RuntimeCatalogStore(root: paths.root)
        let service = RuntimeCatalogService(baseline: baseline, store: store)
        let old = try SafeIdentifier("d3dmetal-wine11.20mg1.0-gptk4.0b3")
        _ = try await service.selectBundle(id: old, pinned: false, installedBundleIDs: [old])
        let metadata = try JSONEncoder().encode(RuntimeCatalog.bundled(baseline))
        let access = LiveRuntimeCatalogAccess(signatureVerifier: nil, paths: paths, services: services, baseline: baseline,
            store: store, fetch: { metadata })
        let model = AppModel(paths: paths, manifest: baseline, services: services, catalogAccess: access,
            defaults: nil, rosettaProbe: UnknownRosettaProbe())
        model.autoUpdateDependencies = false
        var settings = model.launchSettings(for: game)
        settings.backend = .d3dmetal; settings.surroundSound = true
        try model.saveLaunchSettings(settings, for: game)
        try await model.flushLaunchSettings()
        let result = Self(paths: paths, model: model, services: services, manifest: baseline)
        try result.publishBundle(result.old); try result.publishHelper(SurroundAudio.componentID)
        await model.start(); await model.catalogRefreshTask?.value
        return result
    }

    func publishHelper(_ id: String) throws {
        let component = try #require(manifest.components.first { $0.id.rawValue == id })
        let installed = try InstalledComponent(kind: component.kind, version: component.version.rawValue, installedAt: .now, source: .download)
        services.state.withLock { $0.components.append(installed) }
    }

    func publishBundle(_ id: String) throws {
        let root = paths.runtimes.appendingPathComponent("bundles/\(id)")
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(id), root: root, wineBinary: root.appendingPathComponent("bin/wine"),
            digest: try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64)), source: .download)
        services.state.withLock { $0.bundles[id] = bundle }
    }
}
