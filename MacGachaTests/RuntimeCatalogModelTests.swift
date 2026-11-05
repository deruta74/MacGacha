// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct RuntimeCatalogModelTests {
    @Test func refreshPreservesPlayableHelperAndSuccessfulSetupActivatesOnlyRequestedVersion() async throws {
        let f = try await CatalogModelFixture.make()
        let old = try #require(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio))
        await f.model.refreshRuntimeCatalog(force: true)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == old.id)
        #expect(f.model.rows.contains { $0.id == f.revision3.id.rawValue })
        var settings = f.model.launchSettings(for: "genshin"); settings.backend = .d3dmetal
        f.model.launchSettingsCache["genshin"] = settings
        #expect(f.model.offersSurround(for: "genshin"))
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.revision3.id.rawValue)
        try #require(f.model.runtimeCatalogMutationID != nil)
        #expect(await events.next() == f.revision3.id.rawValue)
        #expect(f.model.isBusyForUpdates)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == old.id)
        try f.publish(f.revision3)
        f.services.emit(.phase(.completed))
        try await catalogWait { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == f.revision3.id)
        #expect(f.services.snapshot.components.contains { $0.kind == old.kind && $0.version == old.version.rawValue })
        #expect(f.model.canRemoveRuntime(f.revision3.id.rawValue))
        f.model.useRuntimeVersion(old.id.rawValue)
        try await catalogWait { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeIsPinned(old.id.rawValue))
        let restored = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline, fetch: { f.metadata })
        #expect(try await restored.snapshot().selections.helpers[.surroundAudio]?.id == old.id)
        #expect(try await restored.snapshot().selections.helpers[.surroundAudio]?.pinned == true)
        await f.model.remove(old.id.rawValue)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == old.id)
        #expect(f.model.runtimeIsPinned(old.id.rawValue))
        #expect(f.model.rows.first { $0.id == old.id.rawValue }?.state == .notInstalled)
        settings.surroundSound = true; f.model.launchSettingsCache["genshin"] = settings
        #expect(f.model.runtimeSetupPlan(for: "genshin")?.items.contains { $0.id == old.id.rawValue } == true)

    }

    @Test(arguments: [false, true]) func failedOrCancelledSetupKeepsOldSelection(cancel: Bool) async throws {
        let f = try await CatalogModelFixture.make()
        await f.model.refreshRuntimeCatalog(force: true)
        let old = f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.revision3.id.rawValue)
        try #require(f.model.runtimeCatalogMutationID != nil)
        #expect(await events.next() == f.revision3.id.rawValue)
        if cancel { f.model.cancel(f.revision3.id.rawValue) }
        else { f.services.emit(.failed(.io("synthetic private payload"))) }
        if cancel { f.services.emit(.phase(.cancelled)) }
        try await catalogWait { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == old)
    }

    @Test func automaticChecksAreThrottledAndInvalidFutureDatesCannotSuppressRefresh() async throws {
        let f = try await CatalogModelFixture.make()
        let calls = Mutex(0), date = Mutex(Date(timeIntervalSince1970: 1000))
        let access = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline,
            now: { date.withLock { $0 } }, fetch: { calls.withLock { $0 += 1 }; return f.metadata })
        _ = try await access.snapshot()
        #expect(calls.withLock { $0 } == 0)
        _ = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 1)
        _ = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 1)
        _ = try await access.refresh(force: true)
        #expect(calls.withLock { $0 } == 2)
        let path = f.paths.root.appendingPathComponent("RuntimeCatalog/last-check.json")
        try JSONEncoder().encode(Date(timeIntervalSince1970: 1001)).write(to: path)
        _ = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 3)
        try Data("corrupt".utf8).write(to: path)
        _ = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 4)
        date.withLock { $0 = $0.addingTimeInterval(24 * 60 * 60) }
        _ = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 5)
    }

    @Test func failedCheckRetriesWithoutLosingCachedActiveSelection() async throws {
        let f = try await CatalogModelFixture.make(), calls = Mutex(0)
        let access = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline,
            now: { Date(timeIntervalSince1970: 1000) }, fetch: {
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 { throw LauncherError.transport("private synthetic request") }
                return f.metadata
            })
        let before = try await access.snapshot()
        await #expect(throws: (any Error).self) { try await access.refresh(force: false) }
        #expect(try await access.snapshot().selections == before.selections)
        let after = try await access.refresh(force: false)
        #expect(calls.withLock { $0 } == 2)
        #expect(after.selections == before.selections)
    }

    @Test func startupPublishesLocalSnapshotBeforeBackgroundMetadataReturns() async throws {
        let f = try await CatalogModelFixture.make(), gate = CatalogFetchGate()
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("catalog-startup-\(UUID().uuidString)"))
        let access = LiveRuntimeCatalogAccess(paths: paths, services: f.services, baseline: f.baseline, fetch: {
            await gate.wait(); return f.metadata
        })
        let model = AppModel(paths: paths, services: f.services, catalogAccess: access, defaults: nil)
        await model.start()
        var started = gate.started.stream.makeAsyncIterator()
        _ = await started.next()
        #expect(!model.isStarting)
        #expect(model.runtimeCatalog?.catalog.revision == 0)
        #expect(model.runtimeCatalogRefreshing)
        #expect(model.canBeginGameOrRuntimeOperation())
        await gate.release(); await model.catalogRefreshTask?.value
        #expect(model.runtimeCatalog?.catalog.revision == 1)
    }

    @Test(arguments: [false, true]) func uncertainPublicationUsesActualStateOrBlocksUntilRecovered(unreadable: Bool) async throws {
        let f = try await CatalogModelFixture.make()
        let disk = Mutex(CatalogTestDisk())
        let store = RuntimeCatalogStore(read: {
            try disk.withLock { if $0.unreadable { throw LauncherError.io("unreadable") }; return $0.bytes }
        }, write: { bytes in
            try disk.withLock {
                $0.bytes = bytes
                if $0.fail { $0.unreadable = unreadable; throw LauncherError.io("after rename") }
            }
        })
        let access = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline, store: store, fetch: { f.metadata })
        let model = AppModel(paths: f.paths, manifest: f.baseline, services: f.services, catalogAccess: access, defaults: nil)
        await model.start(); await model.catalogRefreshTask?.value
        await model.refreshRuntimeCatalog(force: true)
        try f.publish(f.revision3); try await model.scanAndApply()
        disk.withLock { $0.fail = true }
        model.useRuntimeVersion(f.revision3.id.rawValue)
        try await catalogWait { model.runtimeCatalogMutationID == nil }
        #expect(model.runtimeCatalogUnavailable == unreadable)
        if unreadable {
            #expect(model.effectiveRuntimeManifest == nil)
            model.play("genshin"); #expect(model.launchSlotOwner == nil)
            disk.withLock { $0.unreadable = false; $0.fail = false }
            await model.reconcileRuntimeCatalog()
        }
        #expect(!model.runtimeCatalogUnavailable)
        #expect(model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == f.revision3.id)
    }

    @Test func refreshReturningAfterActivationCannotRestoreStaleSelection() async throws {
        let f = try await CatalogModelFixture.make()
        let underlying = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline, fetch: { f.metadata })
        let access = HeldCatalogRefresh(underlying)
        let model = AppModel(paths: f.paths, manifest: f.baseline, services: f.services, catalogAccess: access, defaults: nil)
        await model.start(); await model.catalogRefreshTask?.value
        await model.refreshRuntimeCatalog(force: true)
        try f.publish(f.revision3); try await model.scanAndApply()
        await access.arm()
        var started = access.started.stream.makeAsyncIterator()
        let refresh = Task { await model.refreshRuntimeCatalog(force: true) }
        _ = await started.next()
        model.useRuntimeVersion(f.revision3.id.rawValue)
        try await catalogWait { model.runtimeCatalogMutationID == nil }
        await access.release(); await refresh.value
        #expect(model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == f.revision3.id)
    }

    @Test func completionWithoutVerifiedReceiptDoesNotActivate() async throws {
        let f = try await CatalogModelFixture.make()
        let old = f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.useRuntimeVersion(f.revision3.id.rawValue)
        _ = await events.next()
        f.services.emit(.phase(.completed))
        try await catalogWait { f.model.runtimeCatalogMutationID == nil }
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id == old)
    }

    @Test(arguments: [false, true]) func consentUsesCapturedBundleAndDeclineKeepsActiveVersion(accept: Bool) async throws {
        let f = try await CatalogModelFixture.make()
        let current = try #require(f.model.runtimeCatalog)
        let metal = try #require(current.selectedBundle(for: .d3dmetal))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metal)) as? [String: Any])
        object["id"] = "d3dmetal-catalog-3"
        let alternative = try JSONDecoder().decode(RuntimeBundle.self, from: JSONSerialization.data(withJSONObject: object))
        let old = current.catalog
        var recommended = old.recommendedBundles; recommended[.d3dmetal] = alternative.id
        let catalog = RuntimeCatalog(revision: old.revision + 1,
            manifest: try RuntimeManifest(components: old.manifest.components, bundles: old.manifest.bundles + [alternative]),
            bundleBindings: old.bundleBindings + [.init(bundleID: alternative.id, profileID: metal.id)], helperBindings: old.helperBindings,
            recommendedBundles: recommended, recommendedHelpers: old.recommendedHelpers)
        let metadata = try JSONEncoder().encode(catalog)
        let access = LiveRuntimeCatalogAccess(paths: f.paths, services: f.services, baseline: f.baseline, fetch: { metadata })
        let model = AppModel(paths: f.paths, manifest: f.baseline, services: f.services, catalogAccess: access, defaults: nil)
        await model.start(); await model.catalogRefreshTask?.value
        await model.refreshRuntimeCatalog(force: true)
        f.services.state.withLock { $0.accepted = false }
        model.useRuntimeVersion(alternative.id.rawValue)
        try await catalogWait { model.consentRequest != nil }
        await model.refreshRuntimeCatalog(force: true)
        #expect(model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id == metal.id)
        #expect(model.isBusyForUpdates && model.languageRestartBlocker == .runtimeWork)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        model.respondToConsent(accept: accept)
        if accept {
            #expect(await events.next() == alternative.id.rawValue)
            let root = f.paths.runtimes.appendingPathComponent("bundles/\(alternative.id)")
            let installed = InstalledRuntimeBundle(id: alternative.id, root: root, wineBinary: root.appendingPathComponent("bin/wine"),
                digest: try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64)), source: .download)
            f.services.state.withLock { $0.bundles[alternative.id.rawValue] = installed }
            f.services.emit(.phase(.completed))
        }
        try await catalogWait { model.runtimeCatalogMutationID == nil }
        #expect(model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id == (accept ? alternative.id : metal.id))
        #expect(f.services.snapshot.bundleInstalls == (accept ? [alternative.id.rawValue] : []))
        if accept {
            model.useRuntimeVersion(alternative.id.rawValue, pinned: true)
            try await catalogWait { model.runtimeCatalogMutationID == nil }
            #expect(model.canRemoveRuntime(alternative.id.rawValue))
            await model.remove(alternative.id.rawValue)
            #expect(model.runtimeIsSelected(alternative.id.rawValue) && model.runtimeIsPinned(alternative.id.rawValue))
            #expect(model.rows.first { $0.id == alternative.id.rawValue }?.state == .notInstalled)
            #expect(model.runtimeSetupPlan(for: "genshin")?.items.first?.id == alternative.id.rawValue)
        }

    }

    @Test func busySessionRejectsSelectionAndRuntimeRemoval() async throws {
        let f = try await CatalogModelFixture.make()
        await f.model.refreshRuntimeCatalog(force: true)
        let old = try #require(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio))
        f.services.state.withLock { $0.invalid = [InvalidRuntimeEntry(kind: old.kind, rawName: old.version.rawValue, reason: "damaged", removable: true)] }
        try await f.model.scanAndApply()
        let damaged = try #require(f.model.rows.first { $0.id.hasPrefix("invalid:") })
        #expect(f.model.canRemoveRuntime(damaged.id))
        f.model.launchSlotOwner = "genshin"
        f.model.useRuntimeVersion(f.revision3.id.rawValue)
        await f.model.remove(old.id.rawValue)
        #expect(f.services.snapshot.installs.isEmpty)
        #expect(f.services.snapshot.components.contains { $0.version == old.version.rawValue && $0.kind == old.kind })
        #expect(!f.model.canChangeRuntimeCatalog)
    }
}

private struct CatalogModelFixture: Sendable {
    let paths: AppPaths
    let baseline: RuntimeManifest
    let metadata: Data
    let revision3: RuntimeComponent
    let services: FakeRuntimeServices
    let model: AppModel
    @MainActor static func make() async throws -> Self {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("catalog-model-\(UUID().uuidString)"))
        let baseline = try await BundledRuntimeManifest.load()
        let old = try #require(baseline.components.first { $0.id.rawValue == SurroundAudio.componentID })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["id"] = "surround-audio-wine-11.20-3"; object["version"] = "wine-11.20-3"
        let revision3 = try JSONDecoder().decode(RuntimeComponent.self, from: JSONSerialization.data(withJSONObject: object))
        let base = RuntimeCatalog.bundled(baseline)
        var recommended = base.recommendedHelpers; recommended[.surroundAudio] = revision3.id
        let catalog = RuntimeCatalog(revision: 1, manifest: try RuntimeManifest(components: baseline.components + [revision3], bundles: baseline.bundles),
            bundleBindings: base.bundleBindings,
            helperBindings: base.helperBindings + [.init(componentID: revision3.id, profileIDs: [try SafeIdentifier(SurroundAudio.bundleID)])],
            recommendedBundles: base.recommendedBundles, recommendedHelpers: recommended)
        let metadata = try JSONEncoder().encode(catalog), services = FakeRuntimeServices()
        services.state.withLock { $0.accepted = true }
        let record = try InstalledComponent(kind: old.kind, version: old.version.rawValue, installedAt: .now, source: .download)
        services.state.withLock { $0.components = [record] }
        let access = LiveRuntimeCatalogAccess(paths: paths, services: services, baseline: baseline, fetch: { metadata })
        let model = AppModel(paths: paths, manifest: baseline, services: services, catalogAccess: access, defaults: nil)
        await model.start()
        await model.catalogRefreshTask?.value
        return Self(paths: paths, baseline: baseline, metadata: metadata, revision3: revision3, services: services, model: model)
    }
    func publish(_ component: RuntimeComponent) throws {
        let record = try InstalledComponent(kind: component.kind, version: component.version.rawValue, installedAt: .now, source: .download)
        services.state.withLock { $0.components.append(record) }
    }
}

@MainActor private func catalogWait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
}

private struct CatalogTestDisk: Sendable { var bytes: Data?; var fail = false; var unreadable = false }

private actor HeldCatalogRefresh: RuntimeCatalogAccess {
    let base: any RuntimeCatalogAccess
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    nonisolated let started = AsyncStream<Void>.makeStream()
    init(_ base: any RuntimeCatalogAccess) { self.base = base }
    func arm() { hold = true }
    func release() { hold = false; waiter?.resume(); waiter = nil }
    func snapshot() async throws -> RuntimeCatalogSnapshot { try await base.snapshot() }
    func refresh(force: Bool) async throws -> RuntimeCatalogSnapshot {
        let captured = try await base.refresh(force: force)
        if hold { started.continuation.yield(()); await withCheckedContinuation { waiter = $0 } }
        return captured
    }
    func activate(_ selections: RuntimeCatalogSelections) async throws -> RuntimeCatalogSnapshot { try await base.activate(selections) }
}

private actor CatalogFetchGate {
    nonisolated let started = AsyncStream<Void>.makeStream()
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        started.continuation.yield(())
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
