// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import Observation
import Launch
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import GameLibrary
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct LanguageRestartTests {
    @Test func relaunchWaitsForLaunchSettingsWrite() async throws {
        let preferences = LanguageSettingsPreferences(holdWrite: true)
        let f = try LanguageFixture(preferences: preferences); defer { preferences.release(); f.clean() }
        await f.model.start()
        f.model.sessionLogsEnabled = false
        var writes = preferences.entered.stream.makeAsyncIterator(); _ = await writes.next()
        let reserved = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking { _ = f.model.languageRestart } onChange: { reserved.continuation.yield(()) }
        let restart = Task { await f.model.restartForLanguage() }
        var reservations = reserved.stream.makeAsyncIterator(); _ = await reservations.next()
        #expect(f.model.languageRestart != nil)
        #expect(f.launch.arguments.isEmpty && f.launch.terminations == 0)
        preferences.release(); await restart.value
        await f.model.settingsWriteTask?.value
        #expect(try preferences.loadGlobal().sessionLogsEnabled == false)
        #expect(f.launch.arguments.count == 1 && f.launch.terminations == 1)
    }
    @Test func settingsCannotChangeDuringRelaunchHandoff() async throws {
        let preferences = LanguageSettingsPreferences()
        let f = try LanguageFixture(preferences: preferences); defer { f.clean() }
        await f.model.start()
        f.launch.onOpen = {
            #expect(f.model.languageRestart != nil)
            #expect(throws: LauncherError.self) {
                try f.model.saveLaunchSettings(f.model.launchSettings(for: "genshin"), for: "genshin")
            }
            f.model.sessionLogsEnabled = false
            f.model.gameModeEnabled = false
            #expect(f.model.gameModeEnabled)
            #expect(f.model.sessionLogsEnabled)
            #expect(preferences.writeCount == 0)
        }
        await f.model.restartForLanguage()
        await f.model.settingsWriteTask?.value
        #expect(preferences.writeCount == 0 && f.launch.terminations == 1)
    }
    @Test func settingsFlushFailureAbortsLanguageRestart() async throws {
        let preferences = LanguageSettingsPreferences(failWrite: true)
        let f = try LanguageFixture(preferences: preferences); defer { f.clean() }
        await f.model.start()
        f.model.sessionLogsEnabled = false
        await f.model.settingsWriteTask?.value
        await f.model.restartForLanguage()
        #expect(f.launch.arguments.isEmpty && f.launch.terminations == 0)
        #expect(f.model.languageRestart == nil)
        #expect(f.defaults.data(forKey: LanguageRestartContinuation.defaultsKey) == nil)
        #expect(f.model.lastError == LauncherError.languageRestartFailed.userMessage)
    }
    @Test func relaunchWaitsForPipelineDrain() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        await f.model.start()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        let consumer = try #require(f.model.gameTask)
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry()
        await consumer.value
        #expect(f.model.gameOperation == nil && f.launch.arguments.isEmpty)
        #expect(f.model.languageRestart != nil && f.model.isBusyForUpdates)
        await f.game.drain.release(); await restart.value
        #expect(f.launch.arguments.count == 1 && f.launch.terminations == 1)
    }
    @Test func alreadyPausedConsumerStillDrainsWithoutBeingResumed() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        await f.model.start()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        let consumer = f.model.gameTask
        f.model.pauseGame("genshin"); await consumer?.value
        #expect(f.model.gameOperation == nil)
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry()
        #expect(f.launch.arguments.isEmpty)
        await f.game.drain.release(); await restart.value
        #expect(f.launch.arguments.count == 1)
        #expect(f.defaults.data(forKey: "languageRestartContinuation") == nil)
    }
    @Test func restartRefusesNewWorkUntilDone() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        await f.model.start()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry()
        let gate = UpdateRelaunchGate(isBusy: { f.model.isBusyForUpdates })
        var updates = 0
        #expect(gate.postponeRelaunch { updates += 1 })
        f.model.play("starrail")
        f.model.installGame("zzz", voices: [], at: URL(fileURLWithPath: "/inert/game"), approved: true)
        f.model.installRecommended(for: "zzz")
        #expect(f.model.launchSlotOwner == nil && f.model.gameOperation == nil)
        #expect(f.model.runtimeSetupProgress.isEmpty && f.game.calls.count == 1)
        gate.refresh(); #expect(updates == 0)
        await f.game.drain.release(); await restart.value
        gate.refresh(); #expect(updates == 0) // Reservation survives successful handoff until termination.
    }
    @Test func restartBlockedByGameAndRuntimeWork() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        #expect(f.model.languageRestartBlocker == .startup)
        await f.model.start()
        f.model.launchSlotOwner = "starrail"
        #expect(f.model.languageRestartBlocker == .game("starrail"))
        f.model.launchSlotOwner = nil
        // Uninstall is never resumable, even when the folder already has a pending plan.
        f.model.gameOperation = GameOperationToken(id: "genshin", generation: UUID(), isUninstall: true)
        #expect(f.model.languageRestartBlocker == .unresumableOperation("genshin"))
        f.model.gameOperation = nil
        let fake = FakeRuntimeServices()
        fake.setInstalled(try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download))
        let runtime = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/runtime")),
            manifest: try RuntimeManifest(components: []), services: fake, defaults: nil)
        await runtime.start()
        fake.state.withLock { $0.holdNextScan = true }
        let removal = Task { await runtime.remove("wine-11.0") }
        for await _ in fake.heldScanEvents.stream { break }
        #expect(runtime.languageRestartBlocker == .runtimeWork)
        fake.releaseScan(); await removal.value
    }
    @Test func verifyTurnedRepairResumesThePlan() async throws {
        let f = try LanguageFixture(pending: false); defer { f.clean() }
        await f.model.start()
        f.model.verifyGame("genshin"); await f.game.waitForOpen()
        #expect(f.model.languageRestartBlocker == nil)
        f.game.setRecord(try languageRecord(pending: true)) // Repair plan published after verification started.
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry(); await f.game.drain.release(); await restart.value
        let saved = try #require(f.defaults.data(forKey: "languageRestartContinuation"))
        let continuation = try JSONDecoder().decode(LanguageRestartContinuation.self, from: saved)
        #expect(continuation.action == .resume && continuation.planID == "language-plan")
    }
    @Test func failedRelaunchRestoresTheApp() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        f.launch.failure = true
        await f.model.start(); await f.game.drain.release()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        await f.model.restartForLanguage()
        #expect(f.model.languageRestart == nil && !f.model.isBusyForUpdates)
        #expect(f.defaults.data(forKey: "languageRestartContinuation") == nil)
        #expect(f.launch.terminations == 0 && f.model.lastError == LauncherError.languageRestartFailed.userMessage)
        #expect(f.model.canBeginGameOrRuntimeOperation())
    }
    @Test(arguments: [[], ["-MacGachaLanguageRestart", UUID().uuidString]])
    func ordinaryLaunchIgnoresLeftoverContinuation(arguments: [String]) async throws {
        let f = try LanguageFixture(arguments: arguments); defer { f.clean() }
        try f.saveContinuation()
        await f.model.start()
        #expect(f.game.calls.isEmpty && f.defaults.data(forKey: "languageRestartContinuation") == nil)
        #expect(f.model.languageRestart == nil)
    }
    @Test func otherRegionDownloadResumes() async throws {
        let id = UUID(), f = try LanguageFixture(arguments: ["-MacGachaLanguageRestart", id.uuidString]); defer { f.clean() }
        f.model.region = .mainlandChina
        try f.saveContinuation(id: id)
        await f.model.start(); await f.game.waitForOpen()
        #expect(f.game.calls == ["resume:genshin"])
        #expect(f.defaults.data(forKey: "languageRestartContinuation") == nil)
        let work = f.model.gameTask; f.model.pauseGame("genshin"); await work?.value
    }
    @Test func failedDownloadIsNotResumed() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        await f.model.start()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        let work = f.model.gameTask
        f.game.fail(); await work?.value
        await f.game.drain.release()
        await f.model.restartForLanguage()
        #expect(f.defaults.data(forKey: "languageRestartContinuation") == nil)
        #expect(f.launch.arguments.count == 1)
    }
    @Test func doubleRestartRelaunchesOnce() async throws {
        let f = try LanguageFixture(); defer { f.clean() }
        await f.model.start()
        f.model.resumeGame("genshin"); await f.game.waitForOpen()
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry()
        await f.model.restartForLanguage()
        #expect(f.launch.arguments.isEmpty)
        await f.game.drain.release(); await restart.value
        #expect(f.launch.arguments.count == 1)
    }
    @Test(arguments: [false, true]) func continuationRequiresMatchingDurablePlan(verify: Bool) async throws {
        let id = UUID(), f = try LanguageFixture(arguments: ["-MacGachaLanguageRestart", id.uuidString]); defer { f.clean() }
        let value = LanguageRestartContinuation(restartID: id, gameID: "genshin", action: verify ? .verify : .resume, planID: verify ? nil : "replaced-plan")
        f.defaults.set(try JSONEncoder().encode(value), forKey: "languageRestartContinuation")
        await f.model.start()
        #expect(f.game.calls.isEmpty) // Verify cannot replace a pending plan; resume needs its exact identity.
    }
    @Test func interruptedVerifyWithoutPlanContinuesVerification() async throws {
        let f = try LanguageFixture(pending: false); defer { f.clean() }
        await f.model.start(); f.model.verifyGame("genshin"); await f.game.waitForOpen()
        let restart = Task { await f.model.restartForLanguage() }
        await f.game.drain.waitForEntry(); await f.game.drain.release(); await restart.value
        let data = try #require(f.defaults.data(forKey: "languageRestartContinuation"))
        #expect(try JSONDecoder().decode(LanguageRestartContinuation.self, from: data).action == .verify)
    }
}

@MainActor private struct LanguageFixture {
    let domain: String
    let defaults: UserDefaults
    let game: LanguageGameServices
    let launch: LanguageRelaunch
    let model: AppModel
    init(pending: Bool = true, arguments: [String] = [], preferences: (any LaunchPreferencesPersistence)? = nil) throws {
        domain = "language-restart-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: domain))
        game = LanguageGameServices(record: try languageRecord(pending: pending)); launch = LanguageRelaunch()
        let launch = launch
        model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/language")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: defaults,
            gameServices: game, launchPreferences: preferences, relaunch: { try await launch.open($0) }, terminateAfterLanguageRestart: { launch.terminations += 1 }, launchArguments: arguments)
    }
    func saveContinuation(id: UUID = UUID()) throws {
        let value = LanguageRestartContinuation(restartID: id, gameID: "genshin", action: .resume, planID: "language-plan")
        defaults.set(try JSONEncoder().encode(value), forKey: "languageRestartContinuation")
    }
    func clean() { launch.onOpen = nil; game.finish(); defaults.removePersistentDomain(forName: domain) }
}
@MainActor private final class LanguageRelaunch {
    var arguments: [[String]] = [], terminations = 0, failure = false
    var onOpen: (() -> Void)?
    func open(_ args: [String]) async throws {
        onOpen?()
        arguments.append(args)
        if failure { throw LauncherError.io("private relaunch failure") }
    }
}
private actor LanguageDrainGate {
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { entered.continuation.yield(()); if !released { await withCheckedContinuation { continuation = $0 } } }
    func waitForEntry() async { var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private final class LanguageGameServices: GameServices, Sendable {
    private struct State { var record: GameRecord; var calls: [String] = []; var stream: GameEventStream.Continuation? }
    private let state: Mutex<State>
    private let opened = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let drain = LanguageDrainGate()
    init(record: GameRecord) { state = Mutex(State(record: record)) }
    var calls: [String] { state.withLock { $0.calls } }
    func setRecord(_ record: GameRecord) { state.withLock { $0.record = record } }
    func start() async {}
    func waitUntilIdle(_ id: String) async throws { await drain.wait() }
    func status(_ id: String) async -> GameStatus {
        state.withLock { id == "genshin" ? ($0.record.pending.map { .paused($0.kind) } ?? .installed(tag: "1.0")) : .notInstalled }
    }
    func record(_ id: String) async throws -> GameRecord? { state.withLock { id == "genshin" ? $0.record : nil } }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate { throw LauncherError.cancelled }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { open("install", id) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { open("adopt", id) }
    func update(_ id: String, approved: Bool) async -> GameEventStream { open("update", id) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { open("resume", id) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { open("verify", id) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { open("voices", id) }
    func uninstall(_ id: String) async throws {}
    func waitForOpen() async { var iterator = opened.stream.makeAsyncIterator(); _ = await iterator.next() }
    func finish() { state.withLock { $0.stream }?.finish() }
    func fail() { state.withLock { $0.stream }?.finish(throwing: LauncherError.transport("injected")) }
    private func open(_ operation: String, _ id: String) -> GameEventStream {
        let pair = GameEventStream.makeStream()
        state.withLock { $0.calls.append("\(operation):\(id)"); $0.stream = pair.continuation }
        opened.continuation.yield(())
        return pair.stream
    }
}
private func languageRecord(pending: Bool) throws -> GameRecord {
    let build = InstalledBuild(tag: "1.0", buildID: "language-build", categories: [], voices: [])
    return GameRecord(installPath: URL(fileURLWithPath: "/inert/game"), ownership: .created, executable: try SafeRelativePath("Game.exe"), installed: build,
        pending: pending ? PendingOperation(kind: .repair, planID: try SafeIdentifier("language-plan"), planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), target: build) : nil,
        installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
}

private final class LanguageSettingsPreferences: LaunchPreferencesPersistence, Sendable {
    private struct State {
        var global = GlobalLaunchSettings()
        var games: [String: LaunchSettings] = [:]
        var writes = 0
    }
    private let state = Mutex(State())
    private let holdWrite: Bool, failWrite: Bool
    private let released = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    init(holdWrite: Bool = false, failWrite: Bool = false) { self.holdWrite = holdWrite; self.failWrite = failWrite }
    var writeCount: Int { state.withLock { $0.writes } }
    func release() { released.signal() }
    func loadGames() throws -> [String: LaunchSettings] { state.withLock { $0.games } }
    func loadGlobal() throws -> GlobalLaunchSettings { state.withLock { $0.global } }
    func save(_ settings: LaunchSettings, game: String) throws {
        state.withLock { $0.writes += 1; $0.games[game] = settings }
    }
    func saveGlobal(_ settings: GlobalLaunchSettings) throws {
        state.withLock { $0.writes += 1 }
        if holdWrite {
            // Called on BlockingIO, never on a cooperative worker. Time is only a failure bound.
            entered.continuation.yield(())
            guard released.wait(timeout: .now() + 60) == .success else { throw LauncherError.io("Settings write release deadline") }
        }
        if failWrite { throw LauncherError.io("Injected settings write failure") }
        state.withLock { $0.global = settings }
    }
}
