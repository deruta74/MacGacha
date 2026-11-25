// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import Synchronization
import LauncherCore
import RuntimeManager
import GameLibrary
@testable import Launch

@Suite struct LaunchHistoryTests {
    @Test(arguments: [false, true], [119.0, 120.0])
    func historyRequiresReadyAndQualifiedNormalEnd(ready: Bool, seconds: Double) async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        var session = try await f.saveSnapshot(state: .running, processes: [])
        session.reachedRunning = true; session.reachedReady = ready; session.confirmedRunningSeconds = seconds
        session.configuration = try configuration()
        session.verifiedEndedAt = Date(timeIntervalSince1970: 500)
        let saved = session
        let history = try await BlockingIO.run {
            let store = LaunchHistoryStore(paths: f.paths)
            try store.recordVerifiedSession(saved, normal: true)
            return try store.load()[saved.game]
        }
        #expect((history != nil) == (ready && seconds >= 120))
    }
    @Test func unknownErrorsNeverAcquireAnInventedCause() {
        #expect(LaunchFailureReason.classify(LauncherError.io("secret path and stderr")) == .unknown)
        #expect(LaunchFailureReason.classify(LauncherError.processSpawnFailed(errno: 1)) == .process)
    }
    @Test func comparisonSeparatesBackendRuntimeAndGameChanges() throws {
        let old = try configuration()
        var settings = old.settings; settings.backend = .dxmt
        let current = try configuration(settings: settings, bundle: "different", build: "new")
        #expect(LaunchComparison(previous: old, current: current).changes == [.backend, .runtime, .game])
        #expect(LaunchComparison(previous: old, current: old).changes.isEmpty)
        let hotfix = LaunchConfiguration(gameBuild: old.gameBuild, gameBuildID: "hotfix", bundleID: old.bundleID,
            runtimeProfileID: old.runtimeProfileID, runtimeDigest: old.runtimeDigest, componentIDs: old.componentIDs,
            compatibilityComponentIDs: old.compatibilityComponentIDs, recipeVersion: old.recipeVersion, settings: old.settings)
        #expect(LaunchComparison(previous: old, current: hotfix).changes == [.game])
    }
    @Test func qualifiedBaselineSurvivesRestartAndRetryIsSingleUseWithoutPreferenceWrites() async throws {
        let f = try await ManagerFixture.make(logsEnabled: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await manager.markReady(game: f.game.id); await events.waitForReady()
        await f.clock.waitForSleep(1, duration: .seconds(3)); f.clock.advance(by: .seconds(120))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        try await f.end(manager); await consumer.value
        let baseline = try #require(try await manager.successfulLaunches()[f.game.id])
        #expect(baseline.configuration.bundleID == f.bundle.id.rawValue)
        #expect(baseline.configuration.runtimeDigest == f.bundle.digest)
        #expect(baseline.configuration.gameBuild == "4.6.0")
        let restarted = f.manager()
        #expect(try await restarted.successfulLaunches()[f.game.id] == baseline)
        var changed = baseline.configuration.settings; changed.metalHUD = true
        let saved = changed
        try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).save(saved, for: f.game.id) }
        let globalBefore = try await BlockingIO.run { try GlobalLaunchSettingsStore(paths: f.paths).load() }
        f.spawner.fail(.processSpawnFailed(errno: 1))
        let failed = ManagerEvents(), attempt = await f.consume(restarted, events: failed)
        await attempt.value
        let failure = try #require(await failed.values.compactMap { if case .failed(let value) = $0 { value } else { nil } }.last)
        #expect(failure.logURL == nil)
        #expect(failure.diagnosis?.reason == .process)
        #expect(failure.diagnosis?.comparison?.changes == [.settings])
        let token = try #require(failure.diagnosis?.retryID)
        var retried: LaunchFailure?
        for await event in try await restarted.retryLastSuccessful(game: f.game, installRoot: f.installRoot, gameBuild: "4.6.0", retryID: token) {
            if case .failed(let value) = event { retried = value }
        }
        #expect(retried?.diagnosis?.retryID == nil)
        #expect(retried?.diagnosis?.attempted?.settings == baseline.configuration.settings)
        #expect(try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).load(f.game.id) } == saved)
        #expect(try await BlockingIO.run { try GlobalLaunchSettingsStore(paths: f.paths).load() } == globalBefore)
        #expect(retried?.diagnosis?.attempted?.gameModeEnabled == baseline.configuration.gameModeEnabled)
        await #expect(throws: LaunchConfigurationError.self) {
            try await restarted.retryLastSuccessful(game: f.game, installRoot: f.installRoot, gameBuild: "4.6.0", retryID: token)
        }
        #expect(try await restarted.successfulLaunches()[f.game.id] == baseline)
        #expect(await restarted.diagnose(game: f.game.id, gameBuild: "new-build", reason: .runtime).retryID == nil)
        #expect(await restarted.diagnose(game: f.game.id, gameBuild: "4.6.0", gameBuildID: "changed-hotfix", reason: .runtime).retryID == nil)
    }

    @Test func earlyMissingRuntimeOffersPriorInstalledSelectionAndRevalidatesBeforeRetry() async throws {
        let f = try await ManagerFixture.make(logsEnabled: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await manager.markReady(game: f.game.id); await events.waitForReady()
        await f.clock.waitForSleep(1, duration: .seconds(3)); f.clock.advance(by: .seconds(120))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        try await f.end(manager); await consumer.value
        let provider = MissingCurrentRuntime(previous: f.runtime.selected), restarted = f.manager(runtimes: provider)
        let failed = ManagerEvents(), attempt = await f.consume(restarted, events: failed)
        await attempt.value
        let failure = try #require(await failed.values.compactMap { if case .failed(let value) = $0 { value } else { nil } }.last)
        #expect(failure.stage == .preflight && failure.logURL == nil)
        #expect(failure.diagnosis?.reason == .runtime)
        #expect(failure.diagnosis?.attempted == nil)
        let token = try #require(failure.diagnosis?.retryID)
        provider.removePrevious()
        var retried: LaunchFailure?
        for await event in try await restarted.retryLastSuccessful(game: f.game, installRoot: f.installRoot, gameBuild: "4.6.0", retryID: token) {
            if case .failed(let value) = event { retried = value }
        }
        #expect(retried?.diagnosis?.reason == .runtime)
        #expect(retried?.diagnosis?.retryID == nil)
        #expect(f.spawner.calls.count == 1)
    }

    @Test func previousSnapshotPairsUnusedPinnedHelpersWithoutPublishingSelection() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let manifestURL = root.appendingPathComponent("App/Resources/runtime-manifest.json")
        let manifest = try await BlockingIO.run { try RuntimeManifest.load(from: manifestURL) }
        let service = RuntimeCatalogService(baseline: manifest)
        let current = try await service.snapshot()
        var pinned = current.selections
        let surround = try #require(pinned.helpers[.surroundAudio])
        pinned.helpers[.surroundAudio] = RuntimeCatalogSelection(id: surround.id, pinned: true)
        let captured = try current.replacingSelections(pinned)
        let oldBundle = try #require(manifest.bundles.first { $0.id.rawValue == "d3dmetal-wine11.20mg1.0-gptk4.0b3" })
        let configuration = LaunchConfiguration(gameBuild: "1", bundleID: oldBundle.id.rawValue,
            runtimeProfileID: try #require(captured.profile(for: oldBundle.id)).rawValue,
            runtimeDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
            componentIDs: oldBundle.components.map(\.rawValue), compatibilityComponentIDs: [:], recipeVersion: 1,
            settings: .defaults(for: "genshin"))
        let retry = try configuration.selectingPrevious(in: captured)
        #expect(retry.selectedBundle(for: .d3dmetal)?.id == oldBundle.id)
        #expect(retry.helper(kind: .surroundAudio, for: oldBundle.id) != nil)
        #expect(retry.selectedHelper(for: .surroundAudio)?.id != surround.id)
        #expect(captured.selections.helpers[.surroundAudio]?.pinned == true)
        #expect(try await service.snapshot().selections == current.selections)
    }

    @Test func staleCapturedBuildIDIsRejectedUnderSessionExclusionBeforeSpawn() async throws {
        let f = try await ManagerFixture.make(logsEnabled: false)
        let identity = try await BlockingIO.run { try ContainedFileSystem(root: f.installRoot).rootIdentity() }
        let record = GameRecord(installPath: f.installRoot, ownership: .created, executable: Recipes.recipe(for: f.game.id)!.executable,
            installed: InstalledBuild(tag: "4.6.0", buildID: "new-hotfix", categories: [], voices: []), installIdentity: identity)
        try await GameRecordStore(directory: f.paths.games).save(record, for: f.game.id)
        let manager = f.manager()
        var failure: LaunchFailure?
        for await event in await manager.launch(game: f.game, installRoot: f.installRoot, gameBuild: "4.6.0", gameBuildID: "old-hotfix") {
            if case .failed(let value) = event { failure = value }
        }
        #expect(failure?.stage == .lock)
        #expect(failure?.diagnosis?.reason == .busy)
        #expect(f.spawner.calls.isEmpty)
        #expect(try await manager.successfulLaunches().isEmpty)
    }

    @Test func abnormalAndLegacySessionsCannotReplaceBaseline() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        var session = try await f.saveSnapshot(state: .running, processes: [])
        session.reachedRunning = true; session.reachedReady = true; session.confirmedRunningSeconds = 120
        session.configuration = try configuration(); session.verifiedEndedAt = Date(timeIntervalSince1970: 500)
        let normal = session
        try await BlockingIO.run { try LaunchHistoryStore(paths: f.paths).recordVerifiedSession(normal, normal: true) }
        session.verifiedEndedAt = Date(timeIntervalSince1970: 600)
        let abnormal = session
        session.configuration = nil
        let legacy = session
        let loaded = try await BlockingIO.run {
            let store = LaunchHistoryStore(paths: f.paths)
            try store.recordVerifiedSession(abnormal, normal: false)
            try store.recordVerifiedSession(legacy, normal: true)
            return try store.load()[normal.game]
        }
        #expect(loaded?.sessionID == normal.sessionID)
        #expect(loaded?.endedAt == normal.verifiedEndedAt)
    }

    private func configuration(settings: LaunchSettings = .defaults(for: "starrail"), bundle: String = "test-runtime", build: String = "1.0") throws -> LaunchConfiguration {
        LaunchConfiguration(gameBuild: build, bundleID: bundle, runtimeProfileID: "wine-d3dmetal",
            runtimeDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
            componentIDs: ["wine-test"], compatibilityComponentIDs: [:], recipeVersion: 1, settings: settings)
    }
}

private final class MissingCurrentRuntime: LaunchRuntimeProviding, Sendable {
    let previous: LaunchRuntimeSelection
    private let available = Mutex(true)
    init(previous: LaunchRuntimeSelection) { self.previous = previous }
    func removePrevious() { available.withLock { $0 = false } }
    func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection { throw LaunchConfigurationError.runtimeUnavailable }
    func selection(for configuration: LaunchConfiguration) async throws -> LaunchRuntimeSelection {
        guard available.withLock({ $0 }), configuration.matches(previous) else { throw LaunchConfigurationError.previousUnavailable }
        return previous
    }
}
