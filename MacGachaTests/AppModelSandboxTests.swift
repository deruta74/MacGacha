// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import GameLibrary
import RuntimeManager
@testable import MacGacha

@Suite @MainActor struct AppModelSandboxTests {
    @Test func statusRefreshAndManualCheckPublishSandboxWithoutInstalling() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        #expect(model.sandboxState(for: "genshin") == .outdated(installed: "1", available: "2", size: 100))
        #expect(model.sandboxState(for: "zzz") == nil)
        #expect(fake.actions.isEmpty)
        fake.sandbox = .installed(version: "2")
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(model.sandboxState(for: "genshin") == .installed(version: "2"))
        #expect(fake.actions.isEmpty)
    }

    @Test func transientSandboxMetadataFailurePreservesKnownStateAndGameCheck() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        let previous = model.sandboxState(for: "genshin")
        fake.sandboxError = .transport("synthetic")
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(model.sandboxState(for: "genshin") == previous)
        if case .upToDate = model.gameUpdateCheck["genshin"] {} else { Issue.record("Game check failed with optional metadata") }
        #expect(model.lastError == nil)
        #expect(fake.actions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func explicitSandboxFailureUsesOrdinaryErrorAndRetainsGame() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        model.updateSandbox("genshin")
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        fake.emit(.failed(.transport("synthetic"))); fake.finish()
        await task.value
        #expect(model.lastError != nil)
        #expect(model.games["genshin"]?.status == .installed(tag: "2"))
        #expect(model.canUpdateSandbox("genshin"))
        if case .failed = model.lastGameConsumerOutcome?.outcome {} else { Issue.record("Explicit sandbox failure was lost") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["install", "update", "remove"])
    func sandboxActionsUseOrdinaryOperationAndRefreshFinalState(action: String) async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        fake.sandbox = action == "install" ? .notInstalled(size: 100) : .outdated(installed: "1", available: "2", size: 100)
        await model.refreshGames()
        switch action {
        case "install": model.installSandbox("genshin")
        case "update": model.updateSandbox("genshin")
        default: model.removeSandbox("genshin")
        }
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        #expect(model.isBusyForUpdates)
        #expect(model.languageRestartBlocker == .unresumableOperation("genshin"))
        #expect(!model.canInstallSandbox("genshin"))
        #expect(!model.canUpdateSandbox("genshin"))
        #expect(!model.canRemoveSandbox("genshin"))
        #expect(fake.actions == [action])
        fake.sandbox = action == "remove" ? .notInstalled(size: 100) : .installed(version: "2")
        fake.emit(.phase(.completed)); fake.finish()
        await task.value
        #expect(model.gameOperation == nil)
        #expect(model.sandboxState(for: "genshin") == fake.sandbox)
        #expect(model.games["genshin"]?.status == .installed(tag: "2"))
    }

    @Test(arguments: ["restart", "storage", "move", "operation", "launch", "session", "recovery", "pending", "catalog"])
    func sandboxActionsRespectReservationsAndGameExclusions(blocker: String) async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        switch blocker {
        case "restart": model.setLanguageRestart(UUID())
        case "storage": model.storageCleanupInProgress = true
        case "move": model.gameMoveRecoveryReservation = true
        case "operation": model.gameOperation = GameOperationToken(id: "zzz", generation: UUID())
        case "launch": model.launchSlotOwner = "genshin"
        case "session": model.liveLaunchGames.insert("genshin")
        case "recovery": model.launchStates["genshin"] = .recoveryNeeded("pending")
        case "catalog": model.runtimeCatalogMutationID = "catalog"
        default:
            var record = try #require(try await fake.record("genshin"))
            record.pending = PendingOperation(kind: .update, planID: try SafeIdentifier("pending"),
                planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
                target: try #require(record.installed))
            model.setGameRecord("genshin", record)
        }
        #expect(!model.canUpdateSandbox("genshin"))
        #expect(!model.canRemoveSandbox("genshin"))
        model.updateSandbox("genshin"); model.removeSandbox("genshin")
        #expect(fake.actions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func chainedFailureKeepsSuccessfulGameResultAndSeparateFailure() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        model.updateGame("genshin")
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        fake.emit(.sandboxPhase(.downloading))
        fake.emit(.progress(downloaded: 30, totalNetwork: 100, staged: 0, totalStaged: 0))
        fake.emit(.sandboxFailed(.transport("synthetic")))
        fake.emit(.phase(.completed)); fake.finish()
        await task.value
        #expect(model.sandboxFailure(for: "genshin") == .transport("synthetic"))
        #expect(model.lastError == nil)
        #expect(model.games["genshin"]?.status == .installed(tag: "2"))
        #expect(model.games["genshin"]?.activity == nil)
        #expect(model.gameOperation == nil)
        if case .completed = model.lastGameConsumerOutcome?.outcome {} else { Issue.record("Game update was not successful") }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["startup", "automatic", "manual"])
    func remoteRefreshStartsAutomaticSandboxUpdate(source: String) async throws {
        let fake = SandboxModelServices()
        let offer = fake.sandbox
        if source != "startup" { fake.sandbox = .installed(version: "1") }
        let model = try await fixture(fake, allowAutomatic: true)
        defer { fake.finish() }
        fake.sandbox = offer
        if source == "manual" {
            model.checkForGameUpdate("genshin")
            await model.gameUpdateCheckTasks["genshin"]?.value
        } else if source == "automatic" { await model.refreshGames() }
        let task = try #require(model.gameTask)
        await fake.waitForOpen()
        #expect(fake.actions == ["automatic-2"])
        #expect(model.isAutomaticallyUpdatingSandbox("genshin"))
        let game = try #require(model.games["genshin"])
        #expect(PrimaryAction.resolve(game, runtimesReady: true) == .play)
        fake.sandbox = .installed(version: "2")
        fake.emit(.sandboxPhase(.finishing)); fake.emit(.phase(.completed)); fake.finish()
        await task.value
        #expect(!model.isAutomaticallyUpdatingSandbox("genshin"))
        #expect(model.sandboxState(for: "genshin") == .installed(version: "2"))
    }

    @Test(arguments: ["restart", "sparkle", "storage", "move", "operation", "predownload", "launch", "session", "recovery", "pending", "volume", "gameUpdate", "notInstalled"])
    func automaticSandboxDefersWhileGameOrAppIsBlocked(blocker: String) async throws {
        let fake = SandboxModelServices(), updater = SandboxModelUpdater()
        let offer = fake.sandbox
        fake.sandbox = .installed(version: "1")
        let model = try await fixture(fake, allowAutomatic: true, updater: updater)
        fake.sandbox = offer
        switch blocker {
        case "restart": model.setLanguageRestart(UUID())
        case "sparkle": updater.isInstallingUpdate = true
        case "storage": model.storageCleanupInProgress = true
        case "move": model.gameMoveRecoveryReservation = true
        case "operation": model.gameOperation = GameOperationToken(id: "zzz", generation: UUID())
        case "predownload": model.gameOperation = GameOperationToken(id: "zzz", generation: UUID(), isPreDownload: true)
        case "launch": model.launchSlotOwner = "genshin"
        case "session": model.liveLaunchGames.insert("genshin")
        case "recovery": model.launchStates["genshin"] = .recoveryNeeded("pending")
        case "volume": fake.gameStatus = .locationUnavailable(URL(fileURLWithPath: "/inert/game"))
        case "gameUpdate": fake.gameStatus = .updateAvailable(from: "2", to: "3")
        case "notInstalled": fake.sandbox = .notInstalled(size: 100)
        default:
            fake.pending = true
            fake.gameStatus = .paused(.update)
        }
        await model.refreshGames()
        #expect(!model.isAutomaticallyUpdatingSandbox("genshin"))
        #expect(model.automaticSandboxAttempts["genshin"] == nil)
        #expect(fake.actions.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func automaticFailureIsQuietAndLimitedPerVersion() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake, allowAutomatic: true)
        defer { fake.finish() }
        let task = try #require(model.gameTask)
        await fake.waitForOpen()
        fake.emit(.failed(.transport("synthetic"))); fake.finish()
        await task.value
        #expect(model.sandboxFailure(for: "genshin") == .transport("synthetic"))
        #expect(model.lastError == nil)
        #expect(fake.actions == ["automatic-2"])
        await model.refreshGames()
        #expect(model.gameTask == nil)
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(model.gameTask == nil)
        model.updateSandbox("genshin")
        let manual = try #require(model.gameTask)
        await fake.waitForOpen()
        #expect(fake.actions == ["automatic-2", "update"])
        fake.emit(.phase(.completed)); fake.finish(); await manual.value
        fake.sandbox = .outdated(installed: "1", available: "3", size: 100)
        model.gameLastRefresh = [:]
        await model.refreshGames()
        let next = try #require(model.gameTask)
        await fake.waitForOpen()
        #expect(fake.actions == ["automatic-2", "update", "automatic-3"])
        fake.emit(.phase(.completed)); fake.finish(); await next.value
    }

    @Test(.timeLimit(.minutes(1))) func playCancelsAutomaticSandboxAndJoinsDrainBeforeLaunching() async throws {
        let drain = SandboxModelDrain(), launch = SandboxModelLaunchServices(), fake = SandboxModelServices(drain: drain)
        let model = try await fixture(fake, allowAutomatic: true, launch: launch)
        defer { fake.finish() }
        await fake.waitForOpen()
        model.play("genshin")
        #expect(model.launchSlotOwner == "genshin")
        await drain.waitForEntry()
        #expect(launch.count == 0)
        #expect(model.isAutomaticallyUpdatingSandbox("genshin"))
        await drain.release()
        await model.launchTasks["genshin"]?.value
        #expect(launch.count == 1)
        #expect(model.gameOperation == nil)
        #expect(model.sandboxFailure(for: "genshin") == nil)
        #expect(fake.actions == ["automatic-2"])
        await model.refreshGames()
        let retry = try #require(model.gameTask)
        await fake.waitForOpen()
        #expect(fake.actions == ["automatic-2", "automatic-2"])
        model.cancelAutomaticSandboxUpdate("genshin")
        await retry.value
        model.gameLastRefresh = [:]
        await model.refreshGames()
        #expect(model.gameTask == nil)
        #expect(fake.actions == ["automatic-2", "automatic-2"])
    }

    @Test func sandboxProgressResetsAtEachDistinctPhase() {
        let time = ContinuousClock.now
        var progress = GameProgress()
        _ = progress.update(at: time, downloaded: 90, network: 100, staged: 100, totalStaged: 100)
        progress.beginSandboxPhase(.downloading)
        let download = progress.update(at: time, downloaded: 10, network: 100, staged: 0, totalStaged: 0)
        #expect(download?.fraction == 0.1)
        #expect(progress.sandboxPhase == .downloading)
        progress.beginSandboxPhase(.extracting)
        let extraction = progress.update(at: time, downloaded: 0, network: 0, staged: 1, totalStaged: 4)
        #expect(extraction?.fraction == 0.25)
        #expect(extraction?.speed == nil)
    }

    @Test(.timeLimit(.minutes(1))) func sandboxPhaseReplacesPreviousGameTimingAndHasLocalizedLabel() async throws {
        let fake = SandboxModelServices(), model = try await fixture(fake)
        await model.refreshGames()
        model.updateGame("genshin")
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        let old = ContinuousClock.now.advanced(by: .seconds(-600))
        model.setGameState("genshin", GameState(status: .installed(tag: "2"),
            activity: .working(.staging, fraction: 0.9, bytesPerSecond: 500),
            timing: GameTiming(phaseStarted: old, lastAdvance: old, remaining: .seconds(30), hasFraction: true)))
        model.setSandboxOperationPhase("genshin", phase: .downloading)
        #expect(model.games["genshin"]?.sandboxPhase == .downloading)
        #expect(model.games["genshin"]?.timing?.phaseStarted != old)
        #expect(model.games["genshin"]?.timing?.remaining == nil)
        #expect(model.sandboxPhaseLabel(for: "genshin") != nil)
        #expect(model.languageRestartBlocker == .unresumableOperation("genshin"))
        fake.emit(.phase(.completed)); fake.finish(); await task.value
        #expect(model.sandboxPhase(for: "genshin") == nil)
    }

    private func fixture(_ fake: SandboxModelServices, allowAutomatic: Bool = false,
        launch: any LaunchServices = PreviewLaunchServices(), updater: (any AppUpdating)? = nil) async throws -> AppModel {
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/sandbox-model")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, gameServices: fake, locale: Locale(identifier: "en_US"), launchServices: launch, updater: updater ?? InertAppUpdater())
        if !allowAutomatic { model.automaticSandboxAttempts["genshin"] = ["2"] }
        await model.start()
        model.gameLastRefresh = [:]
        return model
    }
}

private final class SandboxModelServices: GameServices, Sendable {
    let opened = AsyncStream<Void>.makeStream()
    private let drain: SandboxModelDrain?
    init(drain: SandboxModelDrain? = nil) { self.drain = drain }
    private let preview = PreviewGameServices(states: ["genshin": GameState(status: .installed(tag: "2"))])
    private struct State: Sendable {
        var sandbox: SandboxState? = .outdated(installed: "1", available: "2", size: 100)
        var sandboxError: LauncherError?
        var gameStatus: GameStatus = .installed(tag: "2")
        var pending = false
        var actions: [String] = []
        var continuation: GameEventStream.Continuation?
    }
    private let state = Mutex(State())
    var sandbox: SandboxState? {
        get { state.withLock { $0.sandbox } }
        set { state.withLock { $0.sandbox = newValue } }
    }
    var actions: [String] { state.withLock { $0.actions } }
    var sandboxError: LauncherError? {
        get { state.withLock { $0.sandboxError } }
        set { state.withLock { $0.sandboxError = newValue } }
    }
    var gameStatus: GameStatus {
        get { state.withLock { $0.gameStatus } }
        set { state.withLock { $0.gameStatus = newValue } }
    }
    var pending: Bool {
        get { state.withLock { $0.pending } }
        set { state.withLock { $0.pending = newValue } }
    }
    func waitForOpen() async { var iterator = opened.stream.makeAsyncIterator(); _ = await iterator.next() }
    func start() async {}
    func waitForSandboxDrain(_ id: String) async throws { await drain?.wait() }
    func waitUntilIdle(_ id: String) async throws {}
    func status(_ id: String) async -> GameStatus { id == "genshin" ? gameStatus : .notInstalled }
    func checkForUpdate(_ id: String) async throws -> GameStatus { await status(id) }
    func record(_ id: String) async throws -> GameRecord? {
        guard var record = try await preview.record(id) else { return nil }
        if case .installed(let version) = sandbox {
            record.sandbox = try SandboxInstallation(version: version, listPath: SafeRelativePath("beyond_pkg_version"))
        }
        if pending, let target = record.installed {
            record.pending = PendingOperation(kind: .update, planID: try SafeIdentifier("pending"),
                planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)), target: target)
        }
        return record
    }
    func sandboxState(_ id: String) async throws -> SandboxState? {
        if let sandboxError { throw sandboxError }
        return id == "genshin" ? sandbox : nil
    }
    func installSandbox(_ id: String) async -> GameEventStream { open("install") }
    func updateSandbox(_ id: String) async -> GameEventStream { open("update") }
    func automaticallyUpdateSandbox(_ id: String, expectedVersion: String) async -> GameEventStream { open("automatic-" + expectedVersion) }
    func removeSandbox(_ id: String) async -> GameEventStream { open("remove") }
    func update(_ id: String, approved: Bool) async -> GameEventStream { open("game-update") }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        try await preview.estimate(id, voices: voices, at: location)
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream {
        await preview.install(id, voices: voices, at: location, approved: approved)
    }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await preview.adopt(id, folder: folder, voices: voices) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { await preview.resume(id, approved: approved) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await preview.verify(id, mode: mode) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await preview.setVoices(id, voices) }
    func uninstall(_ id: String) async throws { try await preview.uninstall(id) }
    private func open(_ action: String) -> GameEventStream {
        let pair = GameEventStream.makeStream()
        state.withLock { $0.actions.append(action); $0.continuation = pair.continuation }
        opened.continuation.yield(())
        return pair.stream
    }
    func emit(_ event: OperationEvent) { state.withLock { $0.continuation }?.yield(event) }
    func finish() {
        let continuation = state.withLock { let value = $0.continuation; $0.continuation = nil; return value }
        continuation?.finish()
    }
}

private actor SandboxModelDrain {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        entered.continuation.yield(())
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForEntry() async { var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@MainActor private final class SandboxModelUpdater: AppUpdating {
    var isInstallingUpdate = false
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    func start(isBusy: @escaping @MainActor () -> Bool) {}
    func checkForUpdates() {}
}

private final class SandboxModelLaunchServices: LaunchServices, Sendable {
    private let launches = Mutex(0)
    var count: Int { launches.withLock { $0 } }
    func reattach() async throws -> [String: LaunchSession] { [:] }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        launches.withLock { $0 += 1 }
        return AsyncStream { $0.finish() }
    }
    func observation(_ id: String) async throws -> LaunchObservation? { nil }
    func recover(_ id: String) async throws {}
    func session(_ id: String) async -> LaunchSession? { nil }
    func gameProcessIDs(_ id: String) async -> [Int32] { [] }
    func markReady(_ id: String) async {}
    func notices() async throws -> [RecoveryNotice] { [] }
    func acknowledge(_ id: UUID) async throws {}
}
