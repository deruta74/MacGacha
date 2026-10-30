// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct UpdaterTests {
    @Test func idleAllowsSparkleToRelaunchWithoutCallingItsBlock() {
        let gate = UpdateRelaunchGate(isBusy: { false })
        var resumes = 0
        #expect(!gate.postponeRelaunch { resumes += 1 })
        #expect(resumes == 0)
        #expect(gate.isInstallingUpdate)
        gate.installationAborted()
        #expect(!gate.isInstallingUpdate)
    }

    @Test func relaunchWaitsForEveryReservationAndResumesOnce() async {
        let activity = UpdateTestActivity(), resumed = AsyncStream<Void>.makeStream()
        let gate = UpdateRelaunchGate(isBusy: { activity.launch || activity.operation })
        var resumes = 0
        #expect(gate.postponeRelaunch { resumes += 1; resumed.continuation.yield(()) })
        activity.launch = false
        gate.refresh()
        #expect(resumes == 0)
        activity.operation = false
        for await _ in resumed.stream { break }
        #expect(resumes == 1)
        #expect(gate.isInstallingUpdate)
        gate.refresh()
        #expect(resumes == 1)
    }

    @Test func newWorkBeforeIdleDeliveryKeepsRelaunchPostponed() async {
        let activity = UpdateTestActivity(), resumed = AsyncStream<Void>.makeStream()
        let gate = UpdateRelaunchGate(isBusy: { activity.launch || activity.operation })
        var resumes = 0
        #expect(gate.postponeRelaunch { resumes += 1; resumed.continuation.yield(()) })
        activity.launch = false; activity.operation = false
        activity.launch = true
        gate.refresh()
        #expect(resumes == 0)
        activity.launch = false
        for await _ in resumed.stream { break }
        #expect(resumes == 1)
    }

    @Test func abortedPendingUpdateDiscardsItsRelaunchHandler() {
        let activity = UpdateTestActivity()
        let gate = UpdateRelaunchGate(isBusy: { activity.launch || activity.operation })
        var resumes = 0
        #expect(gate.postponeRelaunch { resumes += 1 })
        gate.installationAborted()
        activity.launch = false; activity.operation = false
        gate.refresh()
        #expect(resumes == 0 && !gate.isInstallingUpdate)
    }

    @Test func modelBridgesUpdaterAndProtectsLaunchAndRecovery() async throws {
        let updater = FakeAppUpdater()
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/updates")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil, updater: updater)
        await model.start()
        #expect(updater.started)
        #expect(!model.canCheckForUpdates)
        updater.canCheckForUpdates = true
        #expect(model.canCheckForUpdates)
        model.checkForUpdates()
        #expect(updater.checks == 1)
        model.automaticallyChecksForUpdates = true
        #expect(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        #expect(!model.automaticallyChecksForUpdates)
        #expect(!model.isBusyForUpdates)
        model.launchSlotOwner = "genshin"
        #expect(updater.isBusy?() == true)
        model.knownEndedLaunchGames.insert("genshin")
        model.launchStates["genshin"] = .recoveryNeeded("Pending recovery")
        #expect(model.isBusyForUpdates)
        model.launchSlotOwner = nil
        model.launchStates["genshin"] = nil
        model.gameOperation = GameOperationToken(id: "zzz", generation: UUID(), kind: .verifying)
        #expect(model.isBusyForUpdates)
        model.gameOperation = nil
        #expect(!model.isBusyForUpdates)
    }

    @Test func debugConfigurationNeverStartsSparkle() {
        #if DEBUG
        #expect(!SparkleUpdaterService.permitsStartup(environment: [:], testBundleLoaded: false))
        #endif
    }

    @Test func testHostsNeverStartSparkle() {
        #expect(!SparkleUpdaterService.permitsStartup(environment: ["XCTestConfigurationFilePath": "/test"], testBundleLoaded: false, debugBuild: false))
        #expect(!SparkleUpdaterService.permitsStartup(environment: ["XCTestBundlePath": "/test"], testBundleLoaded: false, debugBuild: false))
        #expect(!SparkleUpdaterService.permitsStartup(environment: [:], testBundleLoaded: true, debugBuild: false))
        #expect(SparkleUpdaterService.permitsStartup(environment: [:], testBundleLoaded: false, debugBuild: false))
        #expect(!SparkleUpdaterService.permitsStartup(environment: [:], testBundleLoaded: false, debugBuild: true))
    }

    @Test func installingUpdateRefusesNewGameAndRuntimeWork() async throws {
        let updater = FakeAppUpdater(), services = FakeRuntimeServices()
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/updates")),
            manifest: try await BundledRuntimeManifest.load(), services: services, defaults: nil, updater: updater)
        updater.isInstallingUpdate = true
        let actions: [() -> Void] = [
            { model.play("genshin") }, { model.verifyGame("genshin") },
            { model.install("jadeite-10.0.7") }, { model.installRecommended(for: "genshin") },
        ]
        for action in actions {
            model.dismissError(); action()
            #expect(model.lastError == LauncherError.busy("").userMessage)
        }
        model.dismissError(); await model.remove("wine-11.0")
        #expect(model.lastError == LauncherError.busy("").userMessage)
        #expect(model.launchSlotOwner == nil && model.gameOperation == nil)
        #expect(services.snapshot.calls.isEmpty)
        #expect(model.runtimeSetupProgress.isEmpty)
    }

    @Test func runtimeCleanupPostponesRelaunchUntilRemovalDrains() async throws {
        let fake = FakeRuntimeServices(), resumed = AsyncStream<Void>.makeStream()
        fake.setInstalled(try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download))
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/updates")),
            manifest: try RuntimeManifest(components: []), services: fake, defaults: nil)
        await model.start()
        fake.state.withLock { $0.holdNextScan = true }
        let remove = Task { await model.remove("wine-11.0") }
        for await _ in fake.heldScanEvents.stream { break }
        #expect(model.isRuntimeOperationRunning)
        let gate = UpdateRelaunchGate(isBusy: { model.isBusyForUpdates })
        #expect(gate.postponeRelaunch { resumed.continuation.yield(()) })
        fake.releaseScan()
        await remove.value
        for await _ in resumed.stream { break }
        #expect(!model.isRuntimeOperationRunning)
    }
}

@MainActor @Observable private final class UpdateTestActivity {
    var launch = true
    var operation = true
}

@MainActor @Observable private final class FakeAppUpdater: AppUpdating {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var started = false
    var checks = 0
    var isInstallingUpdate = false
    var isBusy: (@MainActor () -> Bool)?
    func start(isBusy: @escaping @MainActor () -> Bool) { started = true; self.isBusy = isBusy }
    func checkForUpdates() { checks += 1 }
}
