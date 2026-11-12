// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Dispatch
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct DependencyAutoUpdateModelTests {
    @Test func disablingUpdatesRollsBackUncertainPublishedActivation() async throws {
        let bytes = Mutex<Data?>(nil), armed = Mutex(false)
        let entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let f = try await BundleUpgradeFixture.make(storeFactory: { _ in
            RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
                bytes.withLock { $0 = data }
                if armed.withLock({ value in let old = value; value = false; return old }) {
                    entered.continuation.yield(())
                    guard release.wait(timeout: .now() + 30) == .success else { throw LauncherError.io("Test deadline") }
                    throw LauncherError.io("Failure after replacement")
                }
            })
        })
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        armed.withLock { $0 = true }
        try f.publish(f.new); f.services.emit(.phase(.completed))
        for await _ in entered.stream { break }
        f.model.autoUpdateDependencies = false
        #expect(f.model.runtimeCatalogMutationID != nil)
        release.signal()
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(try await f.model.catalogAccess?.snapshot().selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.runtimeCatalogMutationID == nil)
    }

    @Test func absentLegacyHelpersDoNotBlockBundleUpgrade() async throws {
        let f = try await BundleUpgradeFixture.make(installHelpers: false)
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        #expect(f.services.snapshot.installs.isEmpty)
        #expect(f.services.snapshot.components.isEmpty)
        #expect(f.model.runtimeCatalog?.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.componentID)
    }

    @Test(arguments: [false, true]) func setupRosettaExitReleasesCapturedReservation(cancel: Bool) async throws {
        let probe = HeldSetupRosettaProbe()
        let f = try await BundleUpgradeFixture.make(rosettaProbe: probe)
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        var settings = f.model.launchSettings(for: "genshin"); settings.backend = .d3dmetal
        f.model.launchSettingsCache["genshin"] = settings
        f.model.refreshDependencyConsentGames()
        await probe.begin()
        f.model.installRecommended(for: "genshin")
        let check = try #require(f.model.runtimeSetupRosettaChecks["genshin"]?.task)
        for await _ in probe.entered.stream { break }
        #expect(f.model.runtimeCatalogMutationID != nil)
        if cancel { f.model.cancelRuntimeSetup(for: "genshin") }
        #expect(f.model.runtimeCatalogMutationID != nil)
        await probe.finish(.missing)
        await check.value
        #expect(f.model.runtimeCatalogMutationID == nil)
        #expect(f.model.catalogActivationTargets["genshin"] == nil)
        #expect(f.model.runtimeSetupRosettaChecks["genshin"] == nil)
        #expect(f.model.canBeginGameOrRuntimeOperation())
    }

    @Test func cleanupNeedsNormalProofAndKeepsSharedGraphicsEvenWhenUpdatesAreOff() async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        _ = await events.next()
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        f.model.autoUpdateDependencies = false
        let store = RuntimeAutomaticUpdateStore(paths: f.paths)
        #expect(try await BlockingIO.run { try store.load().replacements.first?.verified } == false)
        f.model.scheduleDependencyAutoUpdates()
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundles[f.old] != nil)
        let shared = try InstalledComponent(kind: .d3dmetal, version: "4.0b3", installedAt: .now, source: .download)
        f.services.state.withLock { $0.components.append(shared) }
        try await f.model.scanAndApply()
        try await BlockingIO.run { try store.recordVerifiedSession(bundleID: f.new, componentIDs: [], confirmedRunningSeconds: 120, sessionID: UUID()) }
        f.model.scheduleDependencyAutoUpdates()
        await f.model.dependencyAutoUpdateTask?.value
        #expect(f.services.snapshot.bundles[f.old] == nil)
        #expect(f.services.snapshot.bundles[f.new] != nil)
        #expect(f.services.snapshot.components.contains(shared))
        #expect(try await BlockingIO.run { try store.load().replacements.isEmpty })
    }

    @Test func pinningTheOldVersionCancelsDurableCleanup() async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true; _ = await events.next()
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        f.model.useRuntimeVersion(f.old)
        await f.model.catalogMutationTask?.value
        #expect(f.model.runtimeIsPinned(f.old))
        let store = RuntimeAutomaticUpdateStore(paths: f.paths)
        #expect(try await BlockingIO.run { try store.load().replacements.isEmpty })
    }
    @Test func backgroundInstallLeavesPlayAvailableAndActivationWaitsForDrainage() async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.canBeginGameOrRuntimeOperation())
        #expect(!f.model.isRuntimeOperationRunning)
        #expect(f.model.isBusyForUpdates)
        f.model.launchSlotOwner = "genshin"
        try f.publish(f.new); f.services.emit(.phase(.completed))
        try await waitForCatalogModel { f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .waitingToActivate(id: f.new) }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        f.model.launchSlotOwner = nil
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.new)
        // The panel names the replaced version as the one awaiting removal.
        #expect(f.model.dependencyAutoUpdate(for: "bundle-d3dmetal") == .keepingPrevious(id: f.old))
    }

    @Test(arguments: ["off", "cancel", "failure"])
    func cancellationAndFailureKeepTheWorkingSelection(reason: String) async throws {
        let f = try await BundleUpgradeFixture.make()
        var events = f.services.installEvents.stream.makeAsyncIterator()
        f.model.autoUpdateDependencies = true
        #expect(await events.next() == f.new)
        if reason == "off" { f.model.autoUpdateDependencies = false }
        else if reason == "cancel" { f.model.cancelDependencyAutoUpdate(for: "bundle-d3dmetal") }
        else { f.services.emit(.failed(.io("synthetic failure"))) }
        if reason != "failure" { f.services.emit(.phase(.cancelled)) }
        try await waitForCatalogModel { !f.model.dependencyAutoUpdateReservation }
        #expect(f.model.runtimeCatalog?.selectedBundle(for: .d3dmetal)?.id.rawValue == f.old)
        #expect(f.model.lastError == nil)
    }

    @Test func missingConsentUsesSetupOnlyWhileTheSettingIsOn() async throws {
        let f = try await BundleUpgradeFixture.make()
        f.services.state.withLock { $0.accepted = false }
        try await f.model.scanAndApply()
        f.model.autoUpdateDependencies = true
        await f.model.dependencyAutoUpdateTask?.value
        var settings = f.model.launchSettings(for: "genshin"); settings.backend = .d3dmetal
        f.model.launchSettingsCache["genshin"] = settings
        f.model.refreshDependencyConsentGames()
        #expect(f.model.runtimeSetupIsUpdate(for: "genshin"))
        #expect(f.model.runtimeSetupPlan(for: "genshin")?.items.first?.id == f.new)
        #expect(f.services.snapshot.bundleInstalls.isEmpty)
        f.model.autoUpdateDependencies = false
        #expect(!f.model.runtimeSetupIsUpdate(for: "genshin"))
    }
}

private actor HeldSetupRosettaProbe: RosettaProbing {
    nonisolated let entered = AsyncStream<Void>.makeStream()
    private var held = false
    private var waiter: CheckedContinuation<RosettaStatus, Never>?
    func begin() { held = true }
    func finish(_ status: RosettaStatus) { waiter?.resume(returning: status); waiter = nil }
    func status() async -> RosettaStatus {
        guard held else { return .unknown }
        entered.continuation.yield(())
        return await withCheckedContinuation { waiter = $0 }
    }
}
