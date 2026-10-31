// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Launch
import Foundation
import Synchronization
import Testing
import LauncherCore
import Launch
import GameLibrary
import DownloadEngine
import RuntimeManager
@testable import MacGacha

@Suite(.serialized) @MainActor
struct AppModelLaunchTests {
    @Test(arguments: ["starrail", "starrail-cn"]) func starRailUnlockTargetIsValidatedBeforeSaving(game: String) throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let original = fixture.model.launchSettings(for: game)
        var settings = original; settings.unlockFPS = true; settings.unlockTarget = 90
        #expect(throws: LauncherError.self) { try fixture.model.saveLaunchSettings(settings, for: game) }
        #expect(fixture.model.launchSettings(for: game) == original)
    }

    @Test func frameRateNoteDoesNotFailLaunchAndClearsOnNextPlay() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        fixture.model.launchStates["starrail"] = .running
        await fixture.model.handleLaunch(.note(.starRailSettingsMissing), id: "starrail")
        #expect(fixture.model.launchNotes["starrail"] == .starRailSettingsMissing)
        #expect(fixture.model.launchState(for: "starrail") == .running && fixture.model.lastError == nil)
        #expect(fixture.makeModel().launchNotes.isEmpty)
        fixture.model.play("starrail")
        #expect(fixture.model.launchNotes["starrail"] == nil)
        await fixture.model.launchTasks["starrail"]?.value
    }

    @Test func unresolvedStartupRetainsReservationQuitProtectionAndRetries() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.services.setUnresolved(true)
        await fixture.model.reattachOnStart()
        #expect(fixture.model.launchSlotOwner == "genshin")
        #expect(fixture.model.liveSessionGameName == String(localized: "Genshin Impact"))
        guard case .recoveryNeeded = fixture.model.launchState(for: "genshin") else { Issue.record("Missing unresolved recovery"); return }
        await fixture.services.failRecovery(1)
        fixture.model.retryRecovery("genshin")
        await fixture.model.recoveryInFlight["genshin"]?.value
        #expect(fixture.model.launchSlotOwner == "genshin")
        #expect(fixture.model.liveSessionGameName != nil)
        await fixture.retryClock.waitForRequests(1)
        await fixture.retryClock.tick()
        await launchModelEventually { fixture.model.launchSlotOwner == nil }
        #expect(fixture.model.liveSessionGameName == nil)
        #expect(await fixture.services.recoveryCalls == 2)
    }

    @Test func settingsSaveOnlyTheirGame() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.reattachOnStart()
        let original = fixture.model.launchSettings(for: "genshin")
        var zzz = fixture.model.launchSettings(for: "zzz"); zzz.directX12 = false
        try fixture.model.saveLaunchSettings(zzz, for: "zzz")
        try await fixture.model.flushLaunchSettings()
        #expect(fixture.model.launchSettings(for: "genshin") == original)
        let saved = try await BlockingIO.run { try LaunchSettingsStore(paths: fixture.paths).load("zzz") }
        #expect(saved == zzz)
        let other = try await BlockingIO.run { try LaunchSettingsStore(paths: fixture.paths).load("genshin") }
        #expect(other == original)
    }

    @Test func surroundFallbackNoteIsExposedForTheFooter() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.handleLaunch(.note(.surroundUnavailable), id: "genshin")
        #expect(fixture.model.launchNotes["genshin"] == .surroundUnavailable)
        #expect(fixture.model.launchNotes["zzz"] == nil)
    }

    @Test func surroundPreferencePersistsOnlyForItsEdition() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let model = fixture.model
        #expect(!model.surroundSound(for: "genshin"))
        try model.setSurroundSound(true, for: "genshin")
        try await model.flushLaunchSettings()
        #expect(model.surroundSound(for: "genshin"))
        #expect(!model.surroundSound(for: "genshin-cn"))
        let persisted = try await BlockingIO.run { try LaunchSettingsStore(paths: fixture.paths).load("genshin") }
        #expect(persisted.surroundSound)
        #expect(persisted.backend == .d3dmetal)
        try model.setSurroundSound(false, for: "genshin")
        try await model.flushLaunchSettings()
        #expect(!model.surroundSound(for: "genshin"))
    }

    @Test func gameModeDefaultOnPersistsWithoutChangingOtherLaunchSettings() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.reattachOnStart()
        #expect(fixture.model.gameModeEnabled)
        fixture.model.gameModeEnabled = false
        fixture.model.sessionLogsEnabled = false
        try await fixture.model.flushLaunchSettings()
        let next = fixture.makeModel()
        await next.reattachOnStart()
        #expect(!next.gameModeEnabled)
        #expect(!next.sessionLogsEnabled)
        #expect(next.launchSettings(for: "genshin") == .defaults(for: "genshin"))
    }

    @Test func sessionLogsDefaultOnAndRoundTrip() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.reattachOnStart()
        #expect(fixture.model.sessionLogsEnabled)
        fixture.model.sessionLogsEnabled = false
        try await fixture.model.flushLaunchSettings()
        let next = fixture.makeModel()
        await next.reattachOnStart()
        #expect(!next.sessionLogsEnabled)
        #expect(next.launchSettings(for: "genshin") == .defaults(for: "genshin"))
    }

    @Test func recoveryNoticeAcknowledgmentRefreshesSnapshot() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let notice = try fixture.notice()
        await fixture.services.setNotices([notice])
        await fixture.model.reattachOnStart()
        #expect(fixture.model.recoveryNotices == [notice])
        fixture.model.acknowledge(notice)
        await fixture.services.waitForAcknowledgment()
        await launchModelEventually { fixture.model.recoveryNotices.isEmpty }
        #expect(await fixture.services.acknowledged == [notice.id])
    }

    @Test func runningReadyAndEndAreObservable() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.handleLaunch(.running, id: "genshin")
        #expect(fixture.model.launchState(for: "genshin") == .running)
        #expect(fixture.model.liveSessionGameName == String(localized: "Genshin Impact"))
        await fixture.model.handleLaunch(.ready, id: "genshin")
        #expect(fixture.model.launchState(for: "genshin") == .ready)
        await fixture.model.handleLaunch(.running, id: "genshin")
        #expect(fixture.model.launchState(for: "genshin") == .ready)
        await fixture.model.handleLaunch(.ended(normal: true), id: "genshin")
        #expect(fixture.model.liveSessionGameName == nil)
        #expect(fixture.model.launchState(for: "genshin") == nil)
    }

    @Test func failurePayloadIsNeverUserVisible() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.handleLaunch(.failed(LaunchFailure(stage: .spawn,
            message: "secret@example.test /Users/private/token", logURL: nil, unverifiedBuild: true)), id: "zzz")
        guard case .failed(let failure) = fixture.model.launchState(for: "zzz") else { Issue.record("Missing failure"); return }
        #expect(failure.stage == .spawn)
        #expect(!failure.message.contains("secret"))
        #expect(!failure.hasLog)
        #expect(failure.unverifiedBuild)
    }

    @Test func recoveryPendingIsRecoveryNeeded() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.handleLaunch(.restored(.pending(reason: "private payload")), id: "genshin")
        guard case .recoveryNeeded(let message) = fixture.model.launchState(for: "genshin") else { Issue.record("Missing recovery state"); return }
        #expect(!message.contains("private"))
    }

    @Test func queuedFailuresRollbackToDurableSettingsAndRemainVisibleAfterOtherSuccess() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let store = FailingLaunchPreferences()
        let model = AppModel(paths: fixture.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            launchServices: fixture.services, launchPreferences: store)
        await model.reattachOnStart()
        var first = model.launchSettings(for: "zzz"); first.retina = true
        var second = first; second.frameLimit = 120
        try model.saveLaunchSettings(first, for: "zzz")
        try model.saveLaunchSettings(second, for: "zzz")
        var other = model.launchSettings(for: "genshin"); other.retina = true
        try model.saveLaunchSettings(other, for: "genshin")
        await #expect(throws: LauncherError.self) { try await model.flushLaunchSettings() }
        #expect(model.launchSettings(for: "zzz") == .defaults(for: "zzz"))
        #expect(model.launchSettings(for: "genshin") == other)
        #expect(model.lastError != nil)
    }

    @Test func failureRetainsAuthoritativeLogAfterCoreContextIsGone() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let log = fixture.paths.logs.appendingPathComponent("genshin-session.log")
        await fixture.model.handleLaunch(.failed(LaunchFailure(stage: .spawn, message: "payload", logURL: log, unverifiedBuild: false)), id: "genshin")
        guard case .failed(let failure) = fixture.model.launchState(for: "genshin") else { Issue.record("Missing failure"); return }
        #expect(failure.hasLog)
        #expect(fixture.model.launchLogURLs["genshin"] == log)
        fixture.model.sessionLogsEnabled = false
        await fixture.model.handleLaunch(.failed(LaunchFailure(stage: .spawn, message: "payload", logURL: log, unverifiedBuild: false)), id: "genshin")
        #expect(fixture.model.launchLogURLs["genshin"] == nil)
        try await fixture.model.flushLaunchSettings()
    }

    @Test func missingCNWineFixBlocksPlayAndClearsAfterInstallation() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let manifest = try await BundledRuntimeManifest.load()
        let bundle = try #require(manifest.defaultBundle(for: .d3dmetal))
        let fix = try #require(manifest.components.first { $0.id.rawValue == Crypt32Fix.componentID })
        let runtimes = PreviewRuntimeServices()
        for try await _ in runtimes.install(bundle, manifest: manifest, from: nil) {}
        let model = AppModel(paths: fixture.paths, manifest: manifest, services: runtimes, defaults: nil, launchServices: fixture.services)
        await model.reattachOnStart()
        await model.refreshRuntimes()
        var settings = model.launchSettings(for: "zzz-cn"); settings.compatibilityPatches = false
        try model.saveLaunchSettings(settings, for: "zzz-cn")
        #expect(model.missingComponents(for: "zzz-cn"))
        #expect(PrimaryAction.resolve(GameState(status: .installed(tag: "1")), runtimesReady: true,
            missingComponents: model.missingComponents(for: "zzz-cn")) == .setUpRuntimes)
        for try await _ in runtimes.install(fix, from: nil) {}
        await model.refreshRuntimes()
        #expect(!model.missingComponents(for: "zzz-cn"))
        #expect(PrimaryAction.resolve(GameState(status: .installed(tag: "1")), runtimesReady: true,
            missingComponents: model.missingComponents(for: "zzz-cn")) == .play)
        try await model.flushLaunchSettings()
    }

    @Test func missingShimIsSetUpRuntimes() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.model.reattachOnStart()
        let manifest = try await BundledRuntimeManifest.load()
        let bundle = try #require(manifest.defaultBundle(for: .d3dmetal))
        let runtimes = PreviewRuntimeServices()
        for try await _ in runtimes.install(bundle, manifest: manifest, from: nil) {}
        let model = AppModel(paths: fixture.paths, manifest: manifest, services: runtimes, defaults: nil, launchServices: fixture.services)
        await model.reattachOnStart()
        await model.refreshRuntimes()
        let state = GameState(status: .installed(tag: "1"))
        #expect(model.missingComponents(for: "zzz"))
        #expect(PrimaryAction.resolve(state, runtimesReady: model.runtimesReady,
            missingComponents: model.missingComponents(for: "zzz")) == .setUpRuntimes)
        var settings = model.launchSettings(for: "zzz"); settings.compatibilityPatches = false
        try model.saveLaunchSettings(settings, for: "zzz")
        #expect(!model.missingComponents(for: "zzz"))
        #expect(PrimaryAction.resolve(state, runtimesReady: model.runtimesReady,
            missingComponents: model.missingComponents(for: "zzz")) == .play)
        try await model.flushLaunchSettings()
    }

    @Test func guardBlocksVerifyWhilePlaying() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.services.setBusy(true)
        let games = LiveGameServices(paths: fixture.paths, guard: fixture.services)
        let stream = await games.verify("genshin", mode: .full)
        await #expect(throws: LauncherError.busy("Playing")) { for try await _ in stream {} }
        #expect(await fixture.services.guardCalls == ["genshin"])
        let fs = try ContainedFileSystem(root: fixture.paths.root)
        #expect(try fs.itemType(at: SafeRelativePath("Games/genshin/operation.json")) == nil)
    }

    @Test func reattachCompletesBeforeAnyGameServiceOperation() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let gate = LaunchStartupGate(), games = StartupGameServices()
        let services = LaunchModelServices(gate: gate)
        let model = AppModel(paths: fixture.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, gameServices: games, launchServices: services)
        let estimate = Task { try await model.estimate("genshin", voices: [], at: fixture.paths.games) }
        await gate.waitUntilEntered()
        #expect(games.calls == [])
        await gate.release()
        _ = try await estimate.value
        #expect(games.calls == ["start", "estimate"])
    }

    @Test func completeLaunchEventStreamReturnsToPlay() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let records = PreviewGameServices(states: ["genshin": GameState(status: .installed(tag: "1"))])
        fixture.model.setGameRecord("genshin", try await records.record("genshin"))
        await fixture.services.script([.stage(.preflight), .running, .ready, .ended(normal: true),
            .stage(.restore), .restored(.clean), .stage(.report)])
        fixture.model.play("genshin")
        await fixture.model.launchTasks["genshin"]?.value
        #expect(fixture.model.launchState(for: "genshin") == nil)
        #expect(fixture.model.liveSessionGameName == nil)
        #expect(fixture.model.launchTasks.isEmpty)
    }

    @Test func pendingRecoverySurvivesReportAndFailureEvents() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let records = PreviewGameServices(states: ["genshin": GameState(status: .installed(tag: "1"))])
        fixture.model.setGameRecord("genshin", try await records.record("genshin"))
        await fixture.services.setLaunchSession(try fixture.session(state: .recoveryPending))
        await fixture.services.script([.running, .ended(normal: false), .stage(.restore),
            .restored(.pending(reason: "private")), .stage(.report),
            .failed(LaunchFailure(stage: .restore, message: "private", logURL: nil, unverifiedBuild: false))])
        fixture.model.play("genshin")
        await fixture.model.launchTasks["genshin"]?.value
        guard case .recoveryNeeded(let message) = fixture.model.launchState(for: "genshin") else { Issue.record("Recovery state was lost"); return }
        #expect(!message.contains("private"))
    }

    @Test func uncertaintyClearsWhenSupervisionResumesWithoutAnotherRunningEvent() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let clock = LaunchPollClock()
        let model = AppModel(paths: fixture.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: fixture.services, launchSleep: { try await clock.sleep() })
        var snapshot = try fixture.session(state: .recoveryPending)
        await fixture.services.setSession(snapshot)
        await model.handleLaunch(.restored(.pending(reason: "uncertain")), id: "genshin")
        await clock.waitForSleep()
        snapshot.state = .running
        await fixture.services.setSession(snapshot)
        await clock.tick()
        await launchModelEventually { model.launchState(for: "genshin") == .running }
        #expect(model.liveSessionGameName != nil)
        await model.handleLaunch(.ended(normal: true), id: "genshin")
    }

    @Test func startupFindingAnotherLiveGameClearsAbandonedPlayState() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.services.setSession(try fixture.session(state: .running))
        fixture.model.play("zzz")
        let requested = fixture.model.launchTasks["zzz"]
        await requested?.value
        #expect(fixture.model.launchState(for: "zzz") == nil)
        #expect(fixture.model.launchState(for: "genshin") == .running)
        #expect(fixture.model.liveSessionGameName != nil)
        let monitor = fixture.model.launchTasks["genshin"]
        monitor?.cancel(); await monitor?.value
    }

    @Test func fileRecoveryAfterKnownEndDoesNotClaimTheGameIsRunning() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        await fixture.services.setSession(try fixture.session(state: .recoveryPending))
        await fixture.model.handleLaunch(.running, id: "genshin")
        await fixture.model.handleLaunch(.ended(normal: true), id: "genshin")
        await fixture.model.handleLaunch(.restored(.pending(reason: "volume unavailable")), id: "genshin")
        #expect(fixture.model.liveSessionGameName == nil)
        guard case .recoveryNeeded = fixture.model.launchState(for: "genshin") else { Issue.record("Missing recovery state"); return }
        let poll = fixture.model.launchRecoveryPolls["genshin"]
        poll?.cancel(); await poll?.value
    }

    @Test func recoveryPollingObservesLaterGuardFinalizationAndRefreshesNotices() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        let clock = LaunchPollClock()
        let model = AppModel(paths: fixture.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: fixture.services, launchSleep: { try await clock.sleep() })
        await fixture.services.setSession(try fixture.session(state: .recoveryPending))
        await model.handleLaunch(.restored(.pending(reason: "uncertain")), id: "genshin")
        await clock.waitForSleep()
        let poll = model.launchRecoveryPolls["genshin"]
        let notice = try fixture.notice()
        await fixture.services.setNotices([notice])
        await fixture.services.setSession(nil)
        await clock.tick(); await poll?.value
        #expect(model.launchState(for: "genshin") == nil)
        #expect(model.liveSessionGameName == nil)
        #expect(model.recoveryNotices == [notice])
    }

    @Test func invalidSettingsAreRejectedBeforePersistence() async throws {
        let fixture = try LaunchModelFixture(); defer { fixture.remove() }
        var settings = LaunchSettings.defaults(for: "zzz"); settings.frameLimit = 144
        #expect(throws: LauncherError.self) { try fixture.model.saveLaunchSettings(settings, for: "zzz") }
        #expect(fixture.model.launchSettings(for: "zzz") == .defaults(for: "zzz"))
    }
}

@MainActor private struct LaunchModelFixture {
    let paths: AppPaths
    let services: LaunchModelServices
    let model: AppModel
    let retryClock: ReviewRecoveryClock
    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGacha-LaunchModel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root); services = LaunchModelServices(); retryClock = ReviewRecoveryClock()
        model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            launchServices: services, recoverySleep: { [retryClock] in try await retryClock.sleep($0) })
    }
    func makeModel() -> AppModel {
        AppModel(paths: paths, manifest: try? RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            launchServices: services, recoverySleep: { [retryClock] in try await retryClock.sleep($0) })
    }
    func session(state: LaunchSession.State) throws -> LaunchSession {
        LaunchSession(sessionID: UUID(), game: "genshin", installRoot: paths.games,
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1), prefix: paths.prefixes,
            bundleID: "test", runtimeDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
            wineBinary: paths.runtimes.appendingPathComponent("wine"), wineserver: paths.runtimes.appendingPathComponent("wineserver"),
            componentIDs: [], recipeVersion: 1, settings: .defaults(for: "genshin"), state: state)
    }
    func notice() throws -> RecoveryNotice {
        let id = UUID()
        let url = paths.games.appendingPathComponent("genshin/recovery/\(id)/file.exe")
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "game": "genshin", "movedTo": [url.absoluteString]])
        return try JSONDecoder().decode(RecoveryNotice.self, from: data)
    }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private actor LaunchModelServices: LaunchServices, GameOperationGuard {
    var unresolved = false
    func setUnresolved(_ value: Bool) { unresolved = value }
    func startupReattachment() async throws -> LaunchStartupResult {
        LaunchStartupResult(sessions: try await reattach(), unresolved: unresolved ? ["genshin"] : [])
    }
    let gate: LaunchStartupGate?
    var busy = false
    var guardCalls: [String] = []
    init(gate: LaunchStartupGate? = nil) { self.gate = gate }
    func setBusy(_ value: Bool) { busy = value }
    func willOperate(on game: String) async throws { guardCalls.append(game); if busy { throw LauncherError.busy("Playing") } }

    private var currentSession: LaunchSession?
    func setSession(_ session: LaunchSession?) { currentSession = session }
    private var launchSession: LaunchSession?
    func setLaunchSession(_ session: LaunchSession) { launchSession = session }
    private var scriptedEvents: [LaunchEvent] = []
    func script(_ events: [LaunchEvent]) { scriptedEvents = events }
    var acknowledged: [UUID] = []
    private var recovery: [RecoveryNotice] = []
    private var acknowledgmentWaiters: [CheckedContinuation<Void, Never>] = []
    func setNotices(_ notices: [RecoveryNotice]) { recovery = notices }
    func reattach() async throws -> [String: LaunchSession] {
        await gate?.pause(); return currentSession.map { [$0.game: $0] } ?? [:]
    }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        currentSession = launchSession
        let events = scriptedEvents
        return AsyncStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish() }
    }
    var ended = false
    var recoveryCalls = 0
    var recoveryFailures = 0
    func setEnded(_ value: Bool) { ended = value }
    func failRecovery(_ count: Int) { recoveryFailures = count }
    func recover(_ id: String) async throws {
        recoveryCalls += 1
        if recoveryCalls <= recoveryFailures { throw LauncherError.busy("Injected recovery barrier") }
        currentSession = nil; unresolved = false
    }
    private var observationGate: LaunchStartupGate?
    func delayNextObservation(_ gate: LaunchStartupGate) { observationGate = gate }
    func observation(_ id: String) async throws -> LaunchObservation? {
        if unresolved { throw LauncherError.busy("Unreadable launch journal") }
        let snapshot = currentSession.map { LaunchObservation(session: $0, hasEnded: ended) }
        if let gate = observationGate { observationGate = nil; await gate.pause() }
        return snapshot
    }
    func session(_ id: String) async -> LaunchSession? { currentSession }
    func gameProcessIDs(_ id: String) async -> [Int32] { [] }
    func markReady(_ id: String) async {}
    func notices() async throws -> [RecoveryNotice] { recovery }
    func acknowledge(_ id: UUID) async throws {
        acknowledged.append(id); recovery.removeAll { $0.id == id }
        let waiters = acknowledgmentWaiters; acknowledgmentWaiters = []; waiters.forEach { $0.resume() }
    }
    func waitForAcknowledgment() async {
        if !acknowledged.isEmpty { return }
        await withCheckedContinuation { acknowledgmentWaiters.append($0) }
    }
}
@MainActor private func launchModelEventually(_ predicate: () -> Bool) async {
    for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
    Issue.record("Model state did not settle")
}

private final class FailingLaunchPreferences: LaunchPreferencesPersistence, Sendable {
    private let games = Mutex<[String: LaunchSettings]>([:])
    func loadGames() throws -> [String: LaunchSettings] { games.withLock { $0 } }
    func loadGlobal() throws -> GlobalLaunchSettings { GlobalLaunchSettings() }
    func save(_ settings: LaunchSettings, game: String) throws {
        if game == "zzz" { throw LauncherError.io("Injected write failure") }
        games.withLock { $0[game] = settings }
    }
    func saveGlobal(_ settings: GlobalLaunchSettings) throws {}
}

private actor LaunchStartupGate {
    var entered = false
    var released = false
    var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        if !released { await withCheckedContinuation { paused = $0 } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func release() { released = true; paused?.resume(); paused = nil }
}
private final class StartupGameServices: GameServices, Sendable {
    let backend = PreviewGameServices()
    private let observed = Mutex<[String]>([])
    var calls: [String] { observed.withLock { $0 } }
    func start() async { observed.withLock { $0.append("start") }
    }
    func waitUntilIdle(_ id: String) async throws {}
    func checkForUpdate(_ id: String) async throws -> GameStatus { await status(id) }
    func status(_ id: String) async -> GameStatus { await backend.status(id) }
    func record(_ id: String) async throws -> GameRecord? { try await backend.record(id) }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        observed.withLock { $0.append("estimate") }; return try await backend.estimate(id, voices: voices, at: location)
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { await backend.install(id, voices: voices, at: location, approved: approved) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await backend.adopt(id, folder: folder, voices: voices) }
    func update(_ id: String, approved: Bool) async -> GameEventStream { await backend.update(id, approved: approved) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { await backend.resume(id, approved: approved) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await backend.verify(id, mode: mode) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await backend.setVoices(id, voices) }
    func uninstall(_ id: String) async throws { try await backend.uninstall(id) }
}

private actor LaunchPollClock {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [CheckedContinuation<Void, Never>] = []
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = continuation
                observers.forEach { $0.resume() }; observers = []
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForSleep() async { if waiters.isEmpty { await withCheckedContinuation { observers.append($0) } } }
    func tick() { let current = waiters; waiters = [:]; current.values.forEach { $0.resume() } }
}


extension AppModelLaunchTests {
    @Test func startupFailureSurvivesRetainedDoneContextAndRecoveryFinalization() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let log = f.paths.logs.appendingPathComponent("genshin-current.log")
        await f.services.setSession(try f.session(state: .done)); await f.services.setEnded(true)
        await f.model.handleLaunch(.restored(.clean), id: "genshin")
        guard case .recoveryNeeded = f.model.launchState(for: "genshin") else {
            Issue.record("Expected retained finalization"); return
        }
        await f.model.handleLaunch(.failed(LaunchFailure(stage: .watch,
            message: "private@example.test /Users/private/token", logURL: log, unverifiedBuild: true)), id: "genshin")
        guard case .recoveryNeeded = f.model.launchState(for: "genshin") else {
            Issue.record("Recovery must finish before showing the failure"); return
        }
        await f.services.setSession(nil)
        _ = await f.model.refreshLaunchSession("genshin")
        guard case .failed(let failure) = f.model.launchState(for: "genshin") else {
            Issue.record("Startup failure was swallowed by finalization"); return
        }
        #expect(failure.stage == .watch)
        #expect(!failure.message.contains("private"))
        #expect(failure.hasLog); #expect(failure.unverifiedBuild)
        #expect(f.model.launchLogURLs["genshin"] == log)
        #expect(f.model.launchSlotOwner == nil)
    }

    @Test func delayedRunningObservationCannotUndoVerifiedEnd() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let clock = NativeWindowClock(), actions = NativeWindowActions(), poll = LaunchPollClock()
        let model = AppModel(paths: f.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: f.services,
            launchWindows: LaunchWindowCoordinator(detector: NativeWindowProvider(), actions: actions, clock: clock),
            launchSleep: { try await poll.sleep() }, recoverySleep: { [retryClock = f.retryClock] in try await retryClock.sleep($0) })
        await f.services.setSession(try f.session(state: .running))
        await model.handleLaunch(.running, id: "genshin")
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20))
        let gate = LaunchStartupGate(); await f.services.delayNextObservation(gate)
        let runningRead = Task { await model.refreshLaunchSession("genshin") }
        await gate.waitUntilEntered()
        await f.services.setSession(try f.session(state: .recoveryPending)); await f.services.setEnded(true)
        _ = await model.refreshLaunchSession("genshin")
        await clock.waitForCancellations(2)
        #expect(actions.restorations == 1)
        #expect(model.recoveryRetryTasks["genshin"] != nil)
        await gate.release(); _ = await runningRead.value
        guard case .recoveryNeeded = model.launchState(for: "genshin") else {
            Issue.record("Older running observation undid verified end"); return
        }
        #expect(model.liveSessionGameName == nil)
        #expect(model.launchSlotOwner == "genshin")
        #expect(model.recoveryRetryTasks["genshin"] != nil)
        #expect(clock.activeSleeps == 0)
        clock.advance(by: .seconds(20))
        #expect(actions.minimizations == 0)
    }

    @Test func newLaunchDiscardsPreviousLogButKeepsCurrentAttemptFallback() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let previousLog = f.paths.logs.appendingPathComponent("genshin-previous.log")
        await f.model.handleLaunch(.failed(LaunchFailure(stage: .watch,
            message: "startup", logURL: previousLog, unverifiedBuild: false)), id: "genshin")
        #expect(f.model.launchLogURLs["genshin"] == previousLog)
        let records = PreviewGameServices(states: ["genshin": GameState(status: .installed(tag: "1"))])
        f.model.setGameRecord("genshin", try await records.record("genshin"))
        await f.services.script([.stage(.preflight), .failed(LaunchFailure(stage: .preflight,
            message: "preflight", logURL: nil, unverifiedBuild: false))])
        f.model.play("genshin")
        #expect(f.model.launchLogURLs["genshin"] == nil)
        await f.model.launchTasks["genshin"]?.value
        guard case .failed(let failure) = f.model.launchState(for: "genshin") else { Issue.record("Missing preflight failure"); return }
        #expect(!failure.hasLog)
        #expect(f.model.launchLogURLs["genshin"] == nil)
        // A URL captured within this attempt remains a valid fallback after the
        // core removes its context, even when the failure carries no URL.
        let currentLog = f.paths.logs.appendingPathComponent("genshin-current.log")
        var snapshot = try f.session(state: .preparing); snapshot.sessionLogURL = currentLog
        await f.services.setSession(snapshot)
        await f.model.handleLaunch(.stage(.snapshot), id: "genshin")
        await f.services.setSession(nil)
        await f.model.handleLaunch(.failed(LaunchFailure(stage: .spawn,
            message: "spawn", logURL: nil, unverifiedBuild: false)), id: "genshin")
        guard case .failed(let currentFailure) = f.model.launchState(for: "genshin") else { Issue.record("Missing current failure"); return }
        #expect(currentFailure.hasLog)
        #expect(f.model.launchLogURLs["genshin"] == currentLog)
    }

    @Test func pendingRecoveryRetriesWithBackoffUntilDurablyFinalized() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let clock = ReviewRecoveryClock()
        let model = AppModel(paths: f.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: f.services, recoverySleep: { try await clock.sleep($0) })
        await f.services.setSession(try f.session(state: .recoveryPending))
        await f.services.setEnded(true); await f.services.failRecovery(3)
        await model.handleLaunch(.restored(.pending(reason: "disk full")), id: "genshin")
        for count in 1...4 {
            await clock.waitForRequests(count)
            #expect(model.launchSlotOwner == "genshin")
            await clock.tick()
            if count < 4 { await clock.waitForRequests(count + 1) }
        }
        await launchModelEventually { model.launchSlotOwner == nil }
        #expect(await clock.requests == [.seconds(5), .seconds(15), .seconds(60), .seconds(60)])
        #expect(await f.services.recoveryCalls == 4)
        #expect(model.launchState(for: "genshin") == nil)
        #expect(model.liveSessionGameName == nil)
    }

    @Test func staleObservationCannotReclaimAFinalizedSession() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        await f.services.setSession(try f.session(state: .recoveryPending)); await f.services.setEnded(true)
        await f.model.handleLaunch(.restored(.pending(reason: "disk full")), id: "genshin")
        let gate = LaunchStartupGate(); await f.services.delayNextObservation(gate)
        let oldRead = Task { await f.model.refreshLaunchSession("genshin") }
        await gate.waitUntilEntered()
        f.model.retryRecovery("genshin"); await f.model.recoveryInFlight["genshin"]?.value
        #expect(f.model.launchSlotOwner == nil)
        await gate.release(); _ = await oldRead.value
        #expect(f.model.launchSlotOwner == nil)
        #expect(f.model.launchState(for: "genshin") == nil)
        #expect(f.model.liveSessionGameName == nil)
    }

    @Test func explicitAndActivationRetriesUseGuardedRecovery() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        await f.services.setSession(try f.session(state: .recoveryPending)); await f.services.failRecovery(1)
        await f.model.handleLaunch(.restored(.pending(reason: "uncertain")), id: "genshin")
        f.model.retryRecovery("genshin")
        await f.model.recoveryInFlight["genshin"]?.value
        #expect(await f.services.recoveryCalls == 1)
        #expect(f.model.launchSlotOwner == "genshin")
        #expect(f.model.liveSessionGameName != nil) // uncertainty does not declare the game dead
        let delegate = LauncherAppDelegate(); delegate.bind(f.model)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        await f.model.recoveryInFlight["genshin"]?.value
        #expect(await f.services.recoveryCalls == 2)
        #expect(f.model.launchSlotOwner == nil)
    }

    @Test func unresolvedConflictKeepsRecoveryAndReservationUntilManagerFinalizes() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        await f.services.setSession(try f.session(state: .recoveryConflict)); await f.services.setEnded(true)
        await f.services.failRecovery(1)
        let notice = try f.notice(); await f.services.setNotices([notice])
        await f.model.handleLaunch(.restored(.conflict(movedTo: notice.movedTo)), id: "genshin")
        guard case .recoveryNeeded(let message) = f.model.launchState(for: "genshin") else {
            Issue.record("Unresolved conflict was cleared"); return
        }
        #expect(message == String(localized: "Some game files aren't back yet. MacGacha keeps trying — or choose Try Restoring Again in the … menu."))
        #expect(f.model.launchSlotOwner == "genshin")
        #expect(f.model.liveSessionGameName == nil)
        f.model.play("zzz")
        #expect(f.model.launchState(for: "zzz") == nil)
        f.model.retryRecovery("genshin"); await f.model.recoveryInFlight["genshin"]?.value
        #expect(f.model.launchSlotOwner == "genshin")
        f.model.retryRecovery("genshin"); await f.model.recoveryInFlight["genshin"]?.value
        #expect(f.model.launchSlotOwner == nil)
        #expect(f.model.recoveryNotices == [notice])
    }

    @Test(arguments: [false, true]) func reattachedVerifiedEndRestoresWindowBeforeRecoveryFinishes(minimized: Bool) async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let clock = NativeWindowClock(), actions = NativeWindowActions(), poll = LaunchPollClock()
        let model = AppModel(paths: f.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: f.services,
            launchWindows: LaunchWindowCoordinator(detector: NativeWindowProvider(), actions: actions, clock: clock),
            launchSleep: { try await poll.sleep() })
        await f.services.setSession(try f.session(state: .running))
        await model.reattachOnStart()
        await clock.waitForSleep(.milliseconds(500)); await clock.waitForSleep(.seconds(20)); await poll.waitForSleep()
        if minimized { await model.handleLaunch(.ready, id: "genshin"); #expect(actions.minimizations == 1) }
        await f.services.setSession(try f.session(state: .recoveryPending)); await f.services.setEnded(true)
        await poll.tick()
        await launchModelEventually { model.liveSessionGameName == nil }
        #expect(actions.restorations == 1)
        #expect(model.launchSlotOwner == "genshin")
        clock.advance(by: .seconds(20))
        #expect(actions.minimizations == (minimized ? 1 : 0))
        let monitor = model.launchTasks["genshin"]; monitor?.cancel(); await poll.tick(); await monitor?.value
    }

    @Test func launchReservationAndQuitProtectionBeginBeforePreflightAndSurviveRecovery() async throws {
        let f = try LaunchModelFixture(); defer { f.remove() }
        let gate = LaunchStartupGate(), services = LaunchModelServices(gate: gate)
        let model = AppModel(paths: f.paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, launchServices: services)
        model.play("genshin")
        #expect(model.launchSlotOwner == "genshin")
        #expect(model.liveSessionGameName == String(localized: "Genshin Impact"))
        model.play("zzz"); #expect(model.launchState(for: "zzz") == nil)
        await gate.waitUntilEntered()
        await model.handleLaunch(.stage(.spawn), id: "genshin")
        let delegate = LauncherAppDelegate(); delegate.bind(model)
        var asked = false
        delegate.requestConfirmation = { _, completion in asked = true; completion(.terminateCancel) }
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _ in done.resume() }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        }
        #expect(asked)
        await gate.release(); await model.launchTasks["genshin"]?.value
        // No record means preflight fails with no child and releases the reservation.
        #expect(model.launchSlotOwner == nil); #expect(model.liveSessionGameName == nil)
        await services.setSession(try f.session(state: .recoveryPending)); await services.setEnded(true)
        await model.handleLaunch(.ended(normal: true), id: "genshin")
        await model.handleLaunch(.restored(.pending(reason: "disk full")), id: "genshin")
        #expect(model.launchSlotOwner == "genshin"); #expect(model.liveSessionGameName == nil)
    }
}

private actor ReviewRecoveryClock {
    private(set) var requests: [Duration] = []
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                requests.append(duration); sleepers[id] = continuation
                let ready = observers.filter { $0.0 <= requests.count }; observers.removeAll { $0.0 <= requests.count }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func waitForRequests(_ count: Int) async {
        if requests.count < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }
    func tick() { let ready = sleepers; sleepers = [:]; ready.values.forEach { $0.resume() } }
}
