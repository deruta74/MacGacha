// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import GameLibrary
import Launch
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct RuntimeSetupTests {
    @Test(arguments: SetupCase.all)
    func planMatchesBackendAndRecipe(configuration: SetupCase) throws {
        let (model, _, manifest) = try fixture(configuration.game, backend: configuration.backend, patches: configuration.patches)
        let plan = try #require(model.runtimeSetupPlan(for: configuration.game))
        let bundle = try #require(manifest.defaultBundle(for: configuration.backend))
        #expect(plan.gameID == configuration.game)
        #expect(plan.items.first?.id == bundle.id.rawValue)
        #expect(plan.items.first?.name == bundle.displayName)
        var expected = [bundle.id.rawValue]
        if configuration.backend == .d3dmetal && ["genshin-cn", "zzz-cn"].contains(configuration.game) {
            expected.append(Crypt32Fix.componentID)
        }
        if configuration.patches {
            let recipe = try #require(Recipes.recipe(for: configuration.game))
            let wrapper: ComponentKind = recipe.wrapper == .jadeite ? .jadeite : .steamShim
            expected.append(try #require(manifest.components.first { $0.kind == wrapper }).id.rawValue)
        }
        #expect(plan.items.map(\.id) == expected)
        #expect(plan.totalSize != nil)
        #expect(plan.needsAppleTerms == (configuration.backend == .d3dmetal))
        #expect(model.missingComponents(for: configuration.game) == !plan.items.isEmpty)
    }

    @Test(arguments: ["genshin-cn", "zzz-cn"], [true, false])
    func cnWineCorrectionFollowsBundleEvenWithoutGamePatches(game: String, patches: Bool) throws {
        let (model, _, manifest) = try fixture(game, backend: .d3dmetal, patches: patches)
        let plan = try #require(model.runtimeSetupPlan(for: game))
        let component = try #require(manifest.components.first { $0.id.rawValue == Crypt32Fix.componentID })
        #expect(plan.items[1] == RuntimeSetupPlan.Item(id: component.id.rawValue,
            name: String(localized: "Wine crypt32 fix", comment: "Runtime component name"), size: component.size))
        #expect(model.missingComponents(for: game))
    }

    @Test(arguments: ["genshin", "zzz", "starrail-cn"], [RuntimeBackend.dxmt, .d3dmetal])
    func unaffectedEditionsDoNotRecommendWineCorrection(game: String, backend: RuntimeBackend) throws {
        let (model, _, _) = try fixture(game, backend: backend)
        let plan = try #require(model.runtimeSetupPlan(for: game))
        #expect(!plan.items.contains { $0.id == Crypt32Fix.componentID })
    }

    @Test(arguments: ["genshin-cn", "zzz-cn"], [RuntimeBackend.dxmt, .d3dmetal])
    func installedWineCorrectionIsOmittedAndDxmtNeverNeedsIt(game: String, backend: RuntimeBackend) async throws {
        let (model, fake, manifest) = try fixture(game, backend: backend, patches: false)
        let bundle = try #require(manifest.defaultBundle(for: backend))
        try publish(bundle.id.rawValue, fake: fake, manifest: manifest)
        await model.refreshRuntimes()
        if backend == .d3dmetal {
            #expect(model.runtimeSetupPlan(for: game)?.items.map(\.id) == [Crypt32Fix.componentID])
            #expect(model.missingComponents(for: game))
        } else {
            #expect(model.runtimeSetupPlan(for: game) == nil)
            #expect(!model.missingComponents(for: game))
        }
        try publish(Crypt32Fix.componentID, fake: fake, manifest: manifest)
        await model.refreshRuntimes()
        #expect(model.runtimeSetupPlan(for: game) == nil)
        #expect(!model.missingComponents(for: game))
    }

    @Test(arguments: GameDefinition.all.map(\.id), [RuntimeBackend.dxmt, .d3dmetal])
    func surroundSetupOnlyWhenEnabledAndEligible(game: String, backend: RuntimeBackend) async throws {
        let (model, fake, manifest) = try fixture(game, backend: backend, patches: false)
        var settings = model.launchSettings(for: game); settings.surroundSound = true
        model.launchSettingsCache[game] = settings
        let bundle = try #require(manifest.defaultBundle(for: backend))
        let eligible = LaunchResolver.offersSurroundSound(game, backend: backend, runtimeBundleID: bundle.id.rawValue)
        #expect(model.offersSurround(for: game) == eligible)
        let ids = try #require(model.runtimeSetupPlan(for: game)).items.map(\.id)
        #expect(ids.contains(SurroundAudio.componentID) == eligible)
        for id in ids where id != SurroundAudio.componentID { try publish(id, fake: fake, manifest: manifest) }
        await model.refreshRuntimes()
        #expect(model.missingComponents(for: game) == eligible)
        if eligible {
            #expect(model.runtimeSetupPlan(for: game)?.items.map(\.id) == [SurroundAudio.componentID])
            var events = fake.installEvents.stream.makeAsyncIterator()
            model.installRecommended(for: game)
            #expect(await events.next() == SurroundAudio.componentID)
            try complete(SurroundAudio.componentID, fake: fake, manifest: manifest)
            try await setupWait { model.runtimeSetupProgress.isEmpty }
            #expect(!model.missingComponents(for: game))
        }
        settings.surroundSound = false; model.launchSettingsCache[game] = settings
        #expect(!model.runtimeSetupRequirements(for: game)!.contains { $0.item.id == SurroundAudio.componentID })
    }

    @Test func totalsRequireEveryKnownSizeAndDoNotOverflow() {
        func plan(_ sizes: [Int64?]) -> RuntimeSetupPlan {
            RuntimeSetupPlan(gameID: "genshin", items: sizes.enumerated().map { .init(id: "\($0.offset)", name: "fixture", size: $0.element) }, needsAppleTerms: false)
        }
        #expect(plan([10, 20]).totalSize == 30)
        #expect(plan([10, nil]).totalSize == nil)
        #expect(plan([.max, 1]).totalSize == nil)
    }

    @Test func installedItemsAreOmittedAndCompleteSetupIsNil() async throws {
        let (model, fake, manifest) = try fixture("starrail")
        let plan = try #require(model.runtimeSetupPlan(for: "starrail"))
        try publish(plan.items[0].id, fake: fake, manifest: manifest)
        await model.refreshRuntimes()
        #expect(model.runtimeSetupPlan(for: "starrail")?.items.map(\.id) == [plan.items[1].id])
        try publish(plan.items[1].id, fake: fake, manifest: manifest)
        await model.refreshRuntimes()
        #expect(model.runtimeSetupPlan(for: "starrail") == nil)
        #expect(!model.missingComponents(for: "starrail"))
        model.installRecommended(for: "starrail")
        #expect(model.runtimeSetupProgress.isEmpty)
    }

    @Test func consentCacheIsConservativeThenRefreshesWithScan() async throws {
        let (model, fake, _) = try fixture("genshin", backend: .d3dmetal)
        #expect(model.runtimeSetupPlan(for: "genshin")?.needsAppleTerms == true)
        fake.state.withLock { $0.accepted = true }
        await model.start()
        #expect(model.runtimeSetupPlan(for: "genshin")?.needsAppleTerms == false)
        fake.state.withLock { $0.accepted = false }
        await model.refreshRuntimes()
        #expect(model.runtimeSetupPlan(for: "genshin")?.needsAppleTerms == true)
    }

    @Test func chainUsesInstallOrderAndRowProgressAndSurvivesRegionSwitch() async throws {
        let (model, fake, manifest) = try fixture("genshin")
        let plan = try #require(model.runtimeSetupPlan(for: "genshin"))
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        #expect(await events.next() == plan.items[0].id)
        fake.emit(.progress(downloaded: 25, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await setupWait { model.runtimeSetupProgress["genshin"] == .installing(item: plan.items[0].name, step: 1, of: 2, fraction: 0.25) }
        #expect(model.rows.first { $0.id == plan.items[0].id }?.state == .working(phase: .staging, fraction: 0.25))
        model.region = .mainlandChina
        try complete(plan.items[0].id, fake: fake, manifest: manifest)
        #expect(await events.next() == plan.items[1].id)
        #expect(model.runtimeSetupProgress["genshin"] == .installing(item: plan.items[1].name, step: 2, of: 2, fraction: nil))
        try complete(plan.items[1].id, fake: fake, manifest: manifest)
        try await setupWait { model.runtimeSetupProgress["genshin"] == nil }
        #expect(model.runtimesReady && !model.missingComponents(for: "genshin"))
        #expect(model.runtimeSetupPlan(for: "genshin") == nil)
    }

    @Test(arguments: [true, false])
    func consentAcceptanceContinuesAndDeclineCancels(accept: Bool) async throws {
        let (model, fake, manifest) = try fixture("genshin", backend: .d3dmetal, patches: false)
        let item = try #require(model.runtimeSetupPlan(for: "genshin")?.items.first)
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        try await setupWait { model.consentRequest != nil }
        #expect(fake.snapshot.bundleInstalls.isEmpty)
        model.respondToConsent(accept: accept)
        if accept {
            #expect(await events.next() == item.id)
            #expect(model.runtimeSetupPlan(for: "genshin")?.needsAppleTerms == false)
            #expect(fake.snapshot.acceptedCount == 1)
            try complete(item.id, fake: fake, manifest: manifest)
            try await setupWait { model.runtimeSetupProgress["genshin"] == nil }
        } else {
            try await setupWait { model.runtimeSetupProgress["genshin"] == nil }
            #expect(fake.snapshot.bundleInstalls.isEmpty && fake.snapshot.acceptedCount == 0)
            #expect(model.lastError == nil)
        }
    }

    @Test func acceptanceFailureIsReportedAndStopsSetup() async throws {
        let (model, fake, _) = try fixture("genshin", backend: .d3dmetal)
        fake.state.withLock { $0.acceptError = .io("private details") }
        model.installRecommended(for: "genshin")
        try await setupWait { model.consentRequest != nil }
        model.respondToConsent(accept: true)
        try await setupWait { model.runtimeSetupProgress["genshin"] == .failed(message: LauncherError.io("").userMessage) }
        #expect(fake.snapshot.bundleInstalls.isEmpty)
    }

    @Test(arguments: [0, 1]) func failureStopsAndKeepsEarlierItems(step: Int) async throws {
        let (model, fake, manifest) = try fixture("genshin")
        let plan = try #require(model.runtimeSetupPlan(for: "genshin"))
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        #expect(await events.next() == plan.items[0].id)
        if step == 1 {
            try complete(plan.items[0].id, fake: fake, manifest: manifest)
            #expect(await events.next() == plan.items[1].id)
        }
        fake.fail(.transport("secret payload"))
        try await setupWait { model.runtimeSetupProgress["genshin"] == .failed(message: LauncherError.transport("").userMessage) }
        #expect(fake.snapshot.bundleInstalls.count == 1)
        #expect(fake.snapshot.installs.count == step)
        #expect((model.installedBundles[plan.items[0].id] != nil) == (step == 1))
        model.dismissRuntimeSetupFailure(for: "genshin")
        #expect(model.runtimeSetupProgress["genshin"] == nil)
    }

    @Test func duplicateRequestsShareTheBundleAndDoNotRestartCompleteSetup() async throws {
        let (model, fake, manifest) = try fixture("genshin")
        let plan = try #require(model.runtimeSetupPlan(for: "genshin"))
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin"); model.installRecommended(for: "genshin")
        #expect(await events.next() == plan.items[0].id)
        model.installRecommended(for: "starrail")
        try complete(plan.items[0].id, fake: fake, manifest: manifest)
        for _ in 0..<2 {
            let wrapper = try #require(await events.next())
            #expect(wrapper != plan.items[0].id)
            try complete(wrapper, fake: fake, manifest: manifest)
        }
        try await setupWait { model.runtimeSetupProgress.isEmpty }
        #expect(fake.snapshot.bundleInstalls == [plan.items[0].id])
        #expect(fake.snapshot.installs.count == 2)
        model.installRecommended(for: "genshin")
        #expect(model.runtimeSetupProgress.isEmpty && fake.snapshot.bundleInstalls.count == 1)
    }

    @Test func cancelStopsCurrentItemAndNeverStartsWrapper() async throws {
        let (model, fake, _) = try fixture("genshin")
        let item = try #require(model.runtimeSetupPlan(for: "genshin")?.items.first)
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        #expect(await events.next() == item.id)
        model.cancelRuntimeSetup(for: "genshin")
        try await setupWait { model.runtimeSetupProgress.isEmpty && model.rows.first { $0.id == item.id }?.state == .notInstalled }
        #expect(fake.snapshot.installs.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test(arguments: [false, true])
    func restartingSetupWaitsForCancelledItemToDrain(retryFails: Bool) async throws {
        let (model, fake, manifest) = try fixture("genshin", patches: false)
        let item = try #require(model.runtimeSetupPlan(for: "genshin")?.items.first)
        var installs = fake.installEvents.stream.makeAsyncIterator()
        var drainage = fake.heldScanEvents.stream.makeAsyncIterator()
        defer { fake.releaseScan(); model.cancelRuntimeSetup(for: "genshin"); fake.finish() }
        model.installRecommended(for: "genshin")
        #expect(await installs.next() == item.id)
        // Cancellation's uncancelled rescan holds the old task open, with no
        // publication. A replacement request must wait rather than join it.
        fake.state.withLock { $0.holdNextScan = true }
        model.cancelRuntimeSetup(for: "genshin")
        _ = await drainage.next()
        model.installRecommended(for: "genshin")
        #expect(fake.snapshot.bundleInstalls.count == 1)
        #expect(model.runtimeSetupProgress["genshin"] == .installing(item: item.name, step: 1, of: 1, fraction: nil))

        let outcomes = AsyncStream<SetupRestartOutcome>.makeStream()
        let installed = Task {
            var restarted = fake.installEvents.stream.makeAsyncIterator()
            let id = await restarted.next()
            if !Task.isCancelled { outcomes.continuation.yield(.installed(id)) }
        }
        let stopped = Task {
            do {
                try await setupWait { model.runtimeSetupProgress["genshin"] == nil }
                outcomes.continuation.yield(.stopped)
            } catch { }
        }
        fake.releaseScan()
        var results = outcomes.stream.makeAsyncIterator()
        let result = await results.next()
        installed.cancel(); stopped.cancel()
        await installed.value; await stopped.value
        try #require(result == .installed(item.id))
        #expect(fake.snapshot.bundleInstalls == [item.id, item.id])
        if retryFails {
            fake.fail(.transport("injected retry failure"))
            try await setupWait { model.runtimeSetupProgress["genshin"] == .failed(message: LauncherError.transport("").userMessage) }
        } else {
            try complete(item.id, fake: fake, manifest: manifest)
            try await setupWait { model.runtimeSetupProgress["genshin"] == nil }
            #expect(!model.missingComponents(for: "genshin"))
        }
    }

    @Test func standaloneBundleComponentsStillRequireBundlePublication() async throws {
        let (model, fake, manifest) = try fixture("genshin", patches: false)
        let bundle = try #require(manifest.defaultBundle(for: .dxmt))
        for id in bundle.components { try publish(id.rawValue, fake: fake, manifest: manifest) }
        await model.refreshRuntimes()
        #expect(model.runtimeSetupPlan(for: "genshin")?.items.map(\.id) == [bundle.id.rawValue])
        #expect(model.missingComponents(for: "genshin"))
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        #expect(await events.next() == bundle.id.rawValue)
        try complete(bundle.id.rawValue, fake: fake, manifest: manifest)
        try await setupWait { model.runtimeSetupProgress.isEmpty }
        #expect(!model.missingComponents(for: "genshin"))
    }

    @Test func sharedItemContinuesWhenOneGameCancels() async throws {
        let (model, fake, manifest) = try fixture("genshin")
        let first = try #require(model.runtimeSetupPlan(for: "genshin")?.items.first)
        let remaining = try #require(model.runtimeSetupPlan(for: "starrail")?.items.last)
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.installRecommended(for: "genshin")
        #expect(await events.next() == first.id)
        model.installRecommended(for: "starrail"); model.cancelRuntimeSetup(for: "genshin")
        #expect(model.runtimeSetupProgress["genshin"] == nil)
        #expect(model.runtimeSetupProgress["starrail"] != nil)
        try complete(first.id, fake: fake, manifest: manifest)
        #expect(await events.next() == remaining.id)
        try complete(remaining.id, fake: fake, manifest: manifest)
        try await setupWait { model.runtimeSetupProgress.isEmpty }
        #expect(!model.missingComponents(for: "starrail"))
        #expect(model.missingComponents(for: "genshin"))
    }

    @Test func setupJoinsAnExistingManualInstall() async throws {
        let (model, fake, manifest) = try fixture("genshin")
        let plan = try #require(model.runtimeSetupPlan(for: "genshin"))
        var events = fake.installEvents.stream.makeAsyncIterator()
        model.install(plan.items[0].id)
        #expect(await events.next() == plan.items[0].id)
        model.installRecommended(for: "genshin")
        try complete(plan.items[0].id, fake: fake, manifest: manifest)
        #expect(await events.next() == plan.items[1].id)
        try complete(plan.items[1].id, fake: fake, manifest: manifest)
        try await setupWait { model.runtimeSetupProgress.isEmpty }
        #expect(fake.snapshot.bundleInstalls == [plan.items[0].id])
    }

    /// A sheet opened before startup loads the manifest must refresh once it arrives.
    @Test func planObservesManifestArrival() throws {
        let (loaded, _, manifest) = try fixture("starrail")
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/Setup")), manifest: nil,
            services: FakeRuntimeServices(), defaults: nil)
        model.launchSettingsCache = loaded.launchSettingsCache
        #expect(model.runtimeSetupPlan(for: "starrail") == nil)
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.runtimeSetupPlan(for: "starrail")
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.manifest = manifest
        #expect(changed.withLock { $0 })
        #expect(model.runtimeSetupPlan(for: "starrail")?.items.isEmpty == false)
    }

    private func fixture(_ game: String, backend: RuntimeBackend = .dxmt, patches: Bool = true) throws -> (AppModel, FakeRuntimeServices, RuntimeManifest) {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        let manifest = try RuntimeManifest.load(from: url), fake = FakeRuntimeServices()
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/Setup")), manifest: manifest,
            services: fake, defaults: nil)
        for definition in GameDefinition.all {
            var settings = LaunchSettings.defaults(for: definition.id)
            settings.backend = backend; settings.compatibilityPatches = patches
            model.launchSettingsCache[definition.id] = settings
        }
        return (model, fake, manifest)
    }

    private func publish(_ id: String, fake: FakeRuntimeServices, manifest: RuntimeManifest) throws {
        if let bundle = manifest.bundles.first(where: { $0.id.rawValue == id }) {
            let root = URL(fileURLWithPath: "/inert/\(id)")
            let installed = InstalledRuntimeBundle(id: bundle.id, root: root, wineBinary: root.appendingPathComponent("bin/wine"),
                digest: try Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), source: .download)
            fake.state.withLock { $0.bundles[id] = installed }
        } else {
            let component = try #require(manifest.components.first { $0.id.rawValue == id })
            let installed = try InstalledComponent(kind: component.kind, version: component.version.rawValue, installedAt: Date(), source: .download)
            fake.state.withLock { $0.components.append(installed) }
        }
    }
    private func complete(_ id: String, fake: FakeRuntimeServices, manifest: RuntimeManifest) throws {
        try publish(id, fake: fake, manifest: manifest); fake.emit(.phase(.completed)); fake.finish()
    }
}

struct SetupCase: Sendable {
    let game: String, backend: RuntimeBackend, patches: Bool
    static var all: [Self] {
        GameDefinition.all.flatMap { game in
            [RuntimeBackend.dxmt, .d3dmetal].flatMap { backend in
                [true, false].map { Self(game: game.id, backend: backend, patches: $0) }
            }
        }
    }
}

private enum SetupRestartOutcome: Equatable {
    case installed(String?), stopped
}

@MainActor private func setupWait(_ condition: @escaping @MainActor () -> Bool) async throws {
    while !condition() {
        let stream = AsyncStream<Void> { continuation in
            withObservationTracking { _ = condition() } onChange: {
                continuation.yield(()); continuation.finish()
            }
        }
        for await _ in stream { break }
        try Task.checkCancellation()
    }
}
