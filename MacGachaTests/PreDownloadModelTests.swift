// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import Launch
import GameLibrary
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct PreDownloadModelTests {
    @Test func transferProgressAndReadyAreSeparateFromInstalledState() async throws {
        let (model, service) = try fixture(); defer { service.finish() }
        await model.start()
        #expect(model.preDownloadState(for: "genshin").state == .available(version: "2.0", bytes: 100))
        model.startPreDownload("genshin")
        #expect(model.gameOperation?.isPreDownload == true)
        #expect(model.games["genshin"] == GameState(status: .installed(tag: "1.0")))
        #expect(model.isBusyForUpdates)
        await service.waitForOpen()
        let worker = try #require(model.gameTask)
        service.emit(.progress(downloaded: 25, totalNetwork: 100, staged: 0, totalStaged: 0))
        await waitFor(model) { if case .downloading(let value) = $0.state { value.downloaded == 25 } else { false } }
        #expect(model.preDownloadState(for: "genshin").progress?.fraction == 0.25)
        service.setInfo(try info(.ready, downloaded: 100)); service.emit(.phase(.completed)); service.finish()
        await worker.value
        #expect(model.preDownloadState(for: "genshin").state == .ready(version: "2.0"))
        #expect(model.games["genshin"] == GameState(status: .installed(tag: "1.0")))
        #expect(model.gameRecord("genshin")?.pending == nil)
        #expect(model.gameOperation == nil)
        #expect(!model.isBusyForUpdates)
    }

    @Test func pauseRetainsReservationUntilPipelineDrains() async throws {
        let gate = PreDownloadModelGate()
        let (model, service) = try fixture(drain: gate); defer { service.finish() }
        await model.start(); model.startPreDownload("genshin"); await service.waitForOpen()
        let worker = try #require(model.gameTask)
        service.setInfo(try info(.paused, downloaded: 25))
        model.pausePreDownload("genshin")
        await gate.waitForEntry()
        #expect(model.gameOperation?.isPreDownload == true)
        #expect(model.isBusyForUpdates)
        await gate.release(); await worker.value
        #expect(model.preDownloadState(for: "genshin").state == .paused)
        #expect(model.preDownloadState(for: "genshin").canDelete)
        #expect(model.gameOperation == nil)
        model.resumePreDownload("genshin"); await service.waitForOpen()
        #expect(service.calls.last == "resume:cache-plan")
        model.pausePreDownload("genshin"); await model.gameTask?.value
    }

    @Test func activeOverlaySurvivesOrdinaryRefresh() async throws {
        let (model, service) = try fixture(); defer { service.finish() }
        await model.start(); model.startPreDownload("genshin"); await service.waitForOpen()
        service.emit(.progress(downloaded: 50, totalNetwork: 100, staged: 0, totalStaged: 0))
        await waitFor(model) { $0.progress?.downloaded == 50 }
        model.gameLastRefresh = [:]
        await model.refreshGames()
        #expect(model.preDownloadState(for: "genshin").progress?.downloaded == 50)
        model.pausePreDownload("genshin"); await model.gameTask?.value
    }

    @Test func staleRefreshCannotReplaceNewTransferProgress() async throws {
        let gate = PreDownloadModelGate()
        let service = try PreDownloadModelServices(infoRead: gate)
        let model = try makeModel(service, defaults: nil)
        let refresh = Task { await model.refreshGames() }
        await gate.waitForEntry()
        model.startPreDownload("genshin"); await service.waitForOpen()
        service.emit(.progress(downloaded: 50, totalNetwork: 100, staged: 0, totalStaged: 0))
        await waitFor(model) { $0.progress?.downloaded == 50 }
        await gate.release(); await refresh.value
        #expect(model.preDownloadState(for: "genshin").progress?.downloaded == 50)
        model.pausePreDownload("genshin"); await model.gameTask?.value
    }

    @Test func languageRestartDoesNotResumeAUserPausedPreDownload() async throws {
        let domain = "PreDownloadPausedRestart-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var handoffs = 0
        let service = try PreDownloadModelServices()
        let model = try makeModel(service, defaults: defaults, relaunch: { _ in handoffs += 1 })
        await model.start()
        model.startPreDownload("genshin"); await service.waitForOpen()
        model.pausePreDownload("genshin"); await model.gameTask?.value
        await model.restartForLanguage()
        #expect(handoffs == 1)
        #expect(defaults.data(forKey: LanguageRestartContinuation.defaultsKey) == nil)
        #expect(service.calls == ["start"])
    }

    @Test func playReservesBeforePausingAndWaitsForDrain() async throws {
        let gate = PreDownloadModelGate(), launch = PreDownloadModelLaunchServices()
        let service = try PreDownloadModelServices(drain: gate)
        let model = try makeModel(service, defaults: nil, launchServices: launch)
        defer { service.finish() }
        await model.start(); model.startPreDownload("genshin"); await service.waitForOpen()
        service.setInfo(try info(.paused, downloaded: 25))
        model.play("genshin")
        #expect(model.launchSlotOwner == "genshin")
        await gate.waitForEntry()
        #expect(model.launchSlotOwner == "genshin")
        #expect(model.gameOperation?.isPreDownload == true)
        #expect(model.launchStates["genshin"] == .starting(.preflight))
        #expect(launch.count == 0)
        await gate.release(); await model.launchTasks["genshin"]?.value
        #expect(model.gameOperation == nil)
        #expect(model.preDownloadState(for: "genshin").state == .paused)
        #expect(service.calls == ["start"])
        #expect(launch.count == 1)
    }

    @Test func restartContinuationRequiresBothExactPlanAndDigest() async throws {
        let domain = "PreDownloadModelTests-\(UUID())", restartID = UUID()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let (model, service) = try fixture(defaults: defaults); defer { service.finish() }
        let current = try info(.paused, downloaded: 25)
        service.setInfo(current)
        let continuation = LanguageRestartContinuation(restartID: restartID, gameID: "genshin", action: .preDownload,
            planID: current.planID?.rawValue, planDigest: current.planDigest)
        defaults.set(try JSONEncoder().encode(continuation), forKey: LanguageRestartContinuation.defaultsKey)
        await model.continueLanguageRestart(arguments: [LanguageRestartContinuation.argument, restartID.uuidString])
        await service.waitForOpen()
        #expect(service.calls == ["resume:cache-plan"])
        model.pausePreDownload("genshin"); await model.gameTask?.value
        #expect(defaults.data(forKey: LanguageRestartContinuation.defaultsKey) == nil)
        let mismatch = LanguageRestartContinuation(restartID: restartID, gameID: "genshin", action: .preDownload,
            planID: current.planID?.rawValue, planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64)))
        defaults.set(try JSONEncoder().encode(mismatch), forKey: LanguageRestartContinuation.defaultsKey)
        await model.continueLanguageRestart(arguments: [LanguageRestartContinuation.argument, restartID.uuidString])
        #expect(service.calls.count == 1)
        #expect(defaults.data(forKey: LanguageRestartContinuation.defaultsKey) == nil)
    }

    @Test func restartWhileResolvingSavesOnlySeparatePreDownloadContinuation() async throws {
        let domain = "PreDownloadRestart-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = PreDownloadModelGate()
        let service = try PreDownloadModelServices(resolve: gate)
        var handoffs = 0
        let model = try makeModel(service, defaults: defaults, relaunch: { _ in handoffs += 1 })
        await model.start()
        model.startPreDownload("genshin"); await gate.waitForEntry()
        #expect(model.languageRestartBlocker == nil)
        let restart = Task { await model.restartForLanguage() }
        for await reservation in Observations({ model.languageRestart }) {
            if reservation != nil { break }
        }
        await gate.release(); await restart.value
        let data = try #require(defaults.data(forKey: LanguageRestartContinuation.defaultsKey))
        let continuation = try JSONDecoder().decode(LanguageRestartContinuation.self, from: data)
        #expect(continuation.action == .preDownload)
        #expect(continuation.planID == "cache-plan")
        #expect(continuation.planDigest == service.currentInfo.planDigest)
        #expect(handoffs == 1)
        #expect(model.gameRecord("genshin")?.pending == nil)
    }

    @Test func deleteRefreshesOverlayWithoutChangingInstalledRecord() async throws {
        let (model, service) = try fixture(); defer { service.finish() }
        service.setInfo(try info(.ready, downloaded: 100))
        await model.refreshGames()
        await model.deletePreDownload("genshin")
        #expect(model.preDownloadState(for: "genshin").state == .unavailable)
        #expect(model.games["genshin"]?.status == .installed(tag: "1.0"))
        #expect(model.gameRecord("genshin")?.pending == nil)
    }

    #if DEBUG
    @Test(arguments: ["predownloadAvailable", "predownloading", "predownloadReady"])
    func screenshotHooksAreInstalledAndInert(_ name: String) throws {
        let domain = "PreDownloadPreview-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(name, forKey: "MacGachaDebugGameState")
        defaults.set("cn", forKey: "MacGachaDebugRegion")
        let model = try #require(AppModel.debugPreview(defaults: defaults))
        #expect(model.region == .mainlandChina)
        #expect(model.gameServices is PreviewGameServices)
        #expect(model.gameTask == nil && model.launchTasks.isEmpty)
        for game in GameDefinition.inRegion(.mainlandChina) {
            #expect(model.games[game.id]?.status == .installed(tag: "7.1.0"))
            #expect(model.games[game.id]?.activity == nil)
            #expect(model.preDownloadState(for: game.id).state != .unavailable)
        }
    }
    #endif

    private func info(_ state: PreDownloadInfo.State, downloaded: Int64 = 0) throws -> PreDownloadInfo {
        try preDownloadModelInfo(state, downloaded: downloaded)
    }
    private func fixture(drain: PreDownloadModelGate? = nil, defaults: UserDefaults? = nil) throws -> (AppModel, PreDownloadModelServices) {
        let service = try PreDownloadModelServices(drain: drain)
        return (try makeModel(service, defaults: defaults), service)
    }
    private func makeModel(_ service: PreDownloadModelServices, defaults: UserDefaults?,
        launchServices: any LaunchServices = PreviewLaunchServices(),
        relaunch: @escaping @MainActor ([String]) async throws -> Void = { _ in }) throws -> AppModel {
        AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/predownload")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: defaults,
            gameServices: service, launchServices: launchServices, launchPreferences: PreDownloadModelPreferences(), relaunch: relaunch)
    }
    private func waitFor(_ model: AppModel, _ condition: (PreDownloadOverlay) -> Bool) async {
        for await overlay in Observations({ model.preDownloadState(for: "genshin") }) {
            if condition(overlay) { return }
        }
    }
}

private func preDownloadModelInfo(_ state: PreDownloadInfo.State, downloaded: Int64 = 0) throws -> PreDownloadInfo {
    PreDownloadInfo(state: state, version: "2.0", bytes: 100, downloaded: downloaded,
        planID: try SafeIdentifier("cache-plan"), planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), canDelete: state != .available)
}
private actor PreDownloadModelGate {
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
private final class PreDownloadModelServices: GameServices, Sendable {
    private struct State {
        var info: PreDownloadInfo
        var calls: [String] = []
        var continuation: GameEventStream.Continuation?
        var paused: PreDownloadInfo
        var infoReads = 0
    }
    private let state: Mutex<State>
    private let base = PreviewGameServices(states: ["genshin": GameState(status: .installed(tag: "1.0"))])
    private let opened = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let drain: PreDownloadModelGate?, resolve: PreDownloadModelGate?, infoRead: PreDownloadModelGate?
    init(drain: PreDownloadModelGate? = nil, resolve: PreDownloadModelGate? = nil, infoRead: PreDownloadModelGate? = nil) throws {
        self.drain = drain; self.resolve = resolve; self.infoRead = infoRead
        state = Mutex(State(info: try preDownloadModelInfo(.available), paused: try preDownloadModelInfo(.paused, downloaded: 25)))
    }
    var calls: [String] { state.withLock { $0.calls } }
    var currentInfo: PreDownloadInfo { state.withLock { $0.info } }
    func setInfo(_ info: PreDownloadInfo) { state.withLock { $0.info = info } }
    func emit(_ event: OperationEvent) { state.withLock { $0.continuation }?.yield(event) }
    func finish() { state.withLock { $0.continuation }?.finish() }
    func waitForOpen() async { var iterator = opened.stream.makeAsyncIterator(); _ = await iterator.next() }
    func start() async {}
    func waitUntilIdle(_ id: String) async throws { await drain?.wait() }
    func status(_ id: String) async -> GameStatus { await base.status(id) }
    func checkForUpdate(_ id: String) async throws -> GameStatus { await base.status(id) }
    func record(_ id: String) async throws -> GameRecord? { try await base.record(id) }
    func preDownloadInfo(_ id: String, refresh: Bool) async throws -> PreDownloadInfo {
        guard id == "genshin" else { return .unavailable }
        let (info, hold) = state.withLock {
            let hold = refresh && $0.infoReads == 0
            $0.infoReads += 1
            return ($0.info, hold)
        }
        if hold { await infoRead?.wait() }
        return info
    }
    func preDownload(_ id: String) async -> GameEventStream { await open("start") }
    func resumePreDownload(_ id: String, expectedPlanID: String?) async -> GameEventStream { await open("resume:\(expectedPlanID ?? "nil")") }
    func deletePreDownload(_ id: String) async throws { setInfo(.unavailable) }
    private func open(_ action: String) async -> GameEventStream {
        await resolve?.wait()
        let stream = GameEventStream.makeStream()
        state.withLock { $0.calls.append(action); $0.continuation = stream.continuation; $0.info = $0.paused }
        opened.continuation.yield(())
        return stream.stream
    }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate { try await base.estimate(id, voices: voices, at: location) }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { await base.install(id, voices: voices, at: location, approved: approved) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await base.adopt(id, folder: folder, voices: voices) }
    func update(_ id: String, approved: Bool) async -> GameEventStream { await base.update(id, approved: approved) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { await base.resume(id, approved: approved) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await base.verify(id, mode: mode) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await base.setVoices(id, voices) }
    func uninstall(_ id: String) async throws { try await base.uninstall(id) }
}
private struct PreDownloadModelPreferences: LaunchPreferencesPersistence {
    func loadGames() throws -> [String: LaunchSettings] { [:] }
    func loadGlobal() throws -> GlobalLaunchSettings { GlobalLaunchSettings() }
    func save(_ settings: LaunchSettings, game: String) throws {}
    func saveGlobal(_ settings: GlobalLaunchSettings) throws {}
}

private final class PreDownloadModelLaunchServices: LaunchServices, Sendable {
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
