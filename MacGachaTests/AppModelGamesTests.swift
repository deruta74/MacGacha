// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import GameLibrary
import Sophon
@testable import MacGacha

@Suite(.serialized) @MainActor
struct AppModelGamesTests {
    @Test func installEmitsWorkingThenInstalled() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        #expect(model.games["genshin"]?.activity == .resolving)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging))
        fake.emit(.progress(downloaded: 25, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.staging, fraction: 0.25, bytesPerSecond: nil)
        }
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
        #expect(model.installedVoices("genshin") == ["en-us"])
        #expect(model.lastError == nil)
        #expect(fake.calls.first == GameCall(action: "install", id: "genshin", approved: false, voices: ["en-us"]))
    }

    @Test func pauseCancelsAndShowsPaused() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging)); model.pauseGame("genshin")
        try await gamesEventually { model.games["genshin"] == GameState(status: .paused(.install)) }
        #expect(model.lastError == nil)
        #expect(fake.terminated > 0)
    }

    @Test(arguments: [true, false]) func approvalPairSurfacesAndApproveResumes(throwsAfterApproval: Bool) async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.needsBatchApproval(required: 200, available: 100))
        if throwsAfterApproval { fake.fail(.insufficientSpace(required: 200, available: 100)) } else { fake.finish() }
        try await gamesEventually {
            model.games["genshin"] == GameState(status: .paused(.install), activity: .needsApproval(required: 200, available: 100))
        }
        #expect(model.lastError == nil)
        model.approveBatches("genshin")
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.action == "resume" && fake.calls.last?.approved == true)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin"); fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
    }

    @Test func approvalWaitsForStreamDrainAndSnapshotBeforeBecomingActionable() async throws {
        let terminal = GameReadGate(), snapshot = GameReadGate()
        let fake = FakeGameServices(approvalTerminalRead: terminal, snapshotRead: snapshot)
        let (model, _, _) = try gameFixture(fake: fake)
        defer { terminal.release(); snapshot.release(); fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: false)

        try await gamesEventually { terminal.entered }
        #expect(model.games["genshin"]?.activity == .resolving)
        model.approveBatches("genshin")
        #expect(model.lastError == nil && fake.calls.count == 1)

        terminal.release()
        try await gamesEventually { snapshot.entered }
        #expect(model.games["genshin"]?.activity == .resolving)
        model.approveBatches("genshin")
        #expect(model.lastError == nil && fake.calls.count == 1)

        snapshot.release()
        try await gamesEventually {
            model.games["genshin"] == GameState(status: .paused(.install), activity: .needsApproval(required: 200, available: 100))
        }
        model.approveBatches("genshin")
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.action == "resume" && fake.calls.last?.approved == true)
        #expect(model.lastError == nil)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
    }

    @Test func failureShowsMessageAndKeepsPaused() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.fail(.transport("https://cdn.hoyoverse.com/file?password=secret"))
        try await gamesEventually { model.games["genshin"] == GameState(status: .paused(.install)) && model.lastError != nil }
        #expect(model.lastError == LauncherError.transport("").userMessage)
        #expect(model.lastError?.contains("secret") == false)
    }

    @Test func onlyOneGameOperationAtATime() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        model.installGame("starrail", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        #expect(fake.calls.first?.id == "genshin")
        #expect(model.lastError == LauncherError.busy("").userMessage)
        #expect(model.games["starrail"]?.activity == nil)
        model.pauseGame("genshin")
        try await gamesEventually { model.games["genshin"]?.activity == nil }
        model.installGame("starrail", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.id == "starrail")
    }

    @Test func refreshMapsStatuses() async throws {
        let (model, fake, _) = try gameFixture()
        fake.setStatus(.updateAvailable(from: "1", to: "2"), for: "genshin")
        fake.setStatus(.paused(.repair), for: "starrail")
        fake.setStatus(.locationUnavailable(gameLocation), for: "zzz")
        await model.refreshGames()
        #expect(model.games["genshin"] == GameState(status: .updateAvailable(from: "1", to: "2")))
        #expect(model.games["starrail"] == GameState(status: .paused(.repair)))
        #expect(model.games["zzz"] == GameState(status: .locationUnavailable(gameLocation)))
        #expect(fake.startCount == 1)
        #expect(model.installedVoices("genshin") == ["en-us"])
        #expect(model.installedVoices("missing").isEmpty)
    }

    @Test func startAndActivationRefreshAreThrottledForTenMinutes() async throws {
        let (model, fake, clock) = try gameFixture()
        await model.start()
        #expect(fake.startCount == 1 && fake.statusCount == 3)
        await model.start(); await model.refreshGames()
        #expect(fake.startCount == 1 && fake.statusCount == 3)
        clock.advance(.seconds(599)); await model.refreshGames(); #expect(fake.statusCount == 3)
        clock.advance(.seconds(1))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await gamesEventually { fake.statusCount == 6 }
    }

    @Test func progressKeepsPhaseThrottlesAndUsesFiveSecondSpeed() async throws {
        let (model, fake, clock) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.verifying)); fake.progress(0)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0, bytesPerSecond: nil) }
        clock.advance(.milliseconds(100)); fake.progress(100)
        // A later phase event acts as a barrier after the throttled progress.
        fake.emit(.phase(.verifying))
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: nil, bytesPerSecond: nil) }
        clock.advance(.milliseconds(3900)); fake.progress(400)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.4, bytesPerSecond: 100) }
        clock.advance(.seconds(2)); fake.progress(600)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.6, bytesPerSecond: 100) }
        clock.advance(.seconds(4)); fake.progress(700)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.7, bytesPerSecond: 40) }
    }

    @Test func operationEntryPointsUseTheirCoreOperations() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        let actions: [(String, () -> Void)] = [
            ("adopt", { model.adoptGame("genshin", folder: gameLocation, voices: ["en-us"]) }),
            ("update", { model.updateGame("genshin") }), ("resume", { model.resumeGame("genshin") }),
            ("verify", { model.verifyGame("genshin") }), ("voices", { model.setVoices("genshin", ["ja-jp"]) }),
        ]
        for (index, item) in actions.enumerated() {
            item.1(); try await gamesEventually { fake.calls.count == index + 1 }
            #expect(fake.calls.last?.action == item.0)
            if item.0 == "update" || item.0 == "resume" { #expect(fake.calls.last?.approved == false) }
            fake.setStatus(.installed(tag: "1.0"), for: "genshin"); fake.emit(.phase(.completed)); fake.finish()
            try await gamesEventually { model.games["genshin"]?.activity == nil }
        }
        await model.uninstallGame("genshin")
        #expect(fake.calls.last?.action == "uninstall")
        #expect(model.games["genshin"] == GameState(status: .notInstalled))
    }

    @Test func estimateForwardsSelectionAndReportsErrors() async throws {
        let (model, fake, _) = try gameFixture()
        let estimate = await model.estimate("genshin", voices: ["ja-jp"], at: gameLocation)
        #expect(estimate == GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150))
        #expect(model.games["genshin"]?.activity == nil)
        #expect(fake.estimateCalls.last == GameCall(action: "estimate", id: "genshin", voices: ["ja-jp"]))
        fake.estimateError = .unsafePath("/other-user/private?password=secret")
        #expect(await model.estimate("genshin", voices: [], at: gameLocation) == nil)
        #expect(model.lastError == LauncherError.unsafePath("").userMessage)
        #expect(model.lastError?.contains("secret") == false)
    }

    @Test func droppingModelCancelsActiveGameStream() async throws {
        let fake = FakeGameServices()
        var model: AppModel? = AppModel(manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, gameServices: fake)
        weak let reference = model
        model?.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        model = nil
        try await gamesEventually { reference == nil && fake.terminated > 0 }
    }

    @Test func progressObservesCounterResetInsideThrottleWindow() {
        var progress = GameProgress()
        let start = ContinuousClock.now
        _ = progress.update(at: start, downloaded: 100, network: 100, staged: 0, totalStaged: 0)
        #expect(progress.update(at: start.advanced(by: .milliseconds(100)), downloaded: 0, network: 1000, staged: 0, totalStaged: 0) == nil)
        let next = progress.update(at: start.advanced(by: .milliseconds(300)), downloaded: 200, network: 1000, staged: 0, totalStaged: 0)
        #expect(next?.fraction == 0.2 && next?.speed == nil)
        let steady = progress.update(at: start.advanced(by: .milliseconds(600)), downloaded: 500, network: 1000, staged: 0, totalStaged: 0)
        #expect(steady?.speed == 1000)
    }

    @Test func progressBoundaryAndCounterResetsAreSafe() {
        var progress = GameProgress()
        let start = ContinuousClock.now
        #expect(progress.update(at: start, downloaded: 0, network: 100, staged: 0, totalStaged: 0)?.fraction == 0)
        #expect(progress.update(at: start.advanced(by: .milliseconds(249)), downloaded: 50, network: 100, staged: 0, totalStaged: 0) == nil)
        let accepted = progress.update(at: start.advanced(by: .milliseconds(250)), downloaded: 50, network: 100, staged: 0, totalStaged: 0)
        #expect(accepted?.fraction == 0.5 && accepted?.speed == 200)
        let reset = progress.update(at: start.advanced(by: .seconds(1)), downloaded: 10, network: 100, staged: 0, totalStaged: 0)
        #expect(reset?.fraction == 0.1 && reset?.speed == nil)
        let local = progress.update(at: start.advanced(by: .seconds(2)), downloaded: 0, network: 0, staged: 20, totalStaged: 10)
        #expect(local?.fraction == 1 && local?.speed == nil)
        _ = progress.update(at: start.advanced(by: .seconds(3)), downloaded: 0, network: Int64.max, staged: 0, totalStaged: 0)
        let huge = progress.update(at: start.advanced(by: .milliseconds(3250)), downloaded: Int64.max, network: Int64.max, staged: 0, totalStaged: 0)
        #expect(huge?.speed == Int64.max && huge?.fraction == 1)
    }

    @Test(arguments: [LauncherError.transport("https://cdn.hoyoverse.com/private?password=planted-secret"),
        .io("https://cdn.hoyoverse.com/private?password=planted-secret")])
    func liveServicesLogSafeFieldsWithInjectedHTTP(error: LauncherError) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaGameServices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("AppSupport")), http = GameFailingHTTP(error: error)
        let live = LiveGameServices(paths: paths, http: http)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await live.start()
        #expect(await live.status("genshin") == .notInstalled)
        #expect(http.requests.isEmpty)
        // DeliveryAPI normalizes foreign transport errors before they reach the adapter.
        await #expect(throws: LauncherError.transport("delivery request failed")) { _ = try await live.estimate("genshin", voices: ["en-us"], at: root.appendingPathComponent("Game")) }
        #expect(!http.requests.isEmpty && http.requests.allSatisfy(DeliveryHostPolicy.allows))
        let log = try String(contentsOf: paths.logs.appendingPathComponent("macgacha.log"), encoding: .utf8)
        #expect(log.contains("Game operation failed") && log.contains("genshin"))
        for forbidden in ["planted-secret", "/private", "password=", "https://"] { #expect(!log.contains(forbidden)) }
    }

    @Test func hostedModelAndPreviewUseInertGameServices() async {
        let model = AppModel.forCurrentProcess()
        #expect(model.games.isEmpty)
        await model.start()
        #expect(model.games.isEmpty)
        let preview = AppModel.preview()
        #expect(Set(preview.games.keys) == ["genshin", "starrail", "zzz"])
        #expect(preview.gameArt.isEmpty)
    }
}

private let gameLocation = URL(fileURLWithPath: "/inert/Games/Genshin")
@MainActor private func gameFixture(fake: FakeGameServices = FakeGameServices()) throws -> (AppModel, FakeGameServices, GameTestClock) {
    let clock = GameTestClock()
    let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/AppSupport")),
        manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
        gameServices: fake, now: { clock.time })
    return (model, fake, clock)
}
@MainActor private func gamesEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("Game model condition did not become true"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private final class GameTestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var time: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ amount: Duration) { instant.withLock { $0 = $0.advanced(by: amount) } }
}
private struct GameCall: Sendable, Equatable {
    let action: String, id: String
    var approved: Bool? = nil
    var voices: Set<String> = []
}
private final class FakeGameServices: GameServices, Sendable {
    private let approvalTerminalRead: GameReadGate?
    private let snapshotRead: GameReadGate?
    init(approvalTerminalRead: GameReadGate? = nil, snapshotRead: GameReadGate? = nil) {
        self.approvalTerminalRead = approvalTerminalRead; self.snapshotRead = snapshotRead
    }
    private struct State: Sendable {
        var statuses: [String: GameStatus] = [:]
        var calls: [GameCall] = []
        var continuation: AsyncThrowingStream<OperationEvent, any Error>.Continuation?
        var active: String?
        var starts = 0, statusReads = 0, terminations = 0
        var estimates: [GameCall] = []
        var estimateError: LauncherError?
    }
    private let state = Mutex(State())
    var estimateError: LauncherError? {
        get { state.withLock { $0.estimateError } }
        set { state.withLock { $0.estimateError = newValue } }
    }
    var estimateCalls: [GameCall] { state.withLock { $0.estimates } }
    var calls: [GameCall] { state.withLock { $0.calls } }
    var startCount: Int { state.withLock { $0.starts } }
    var statusCount: Int { state.withLock { $0.statusReads } }
    var terminated: Int { state.withLock { $0.terminations } }
    func start() async { state.withLock { $0.starts += 1 } }
    func status(_ id: String) async -> GameStatus { state.withLock { $0.statusReads += 1; return $0.statuses[id] ?? .notInstalled } }
    func record(_ id: String) async throws -> GameRecord? {
        await snapshotRead?.wait()
        let status = state.withLock { $0.statuses[id] ?? .notInstalled }
        if status == .notInstalled || status == .unknown { return nil }
        let build = InstalledBuild(tag: "1.0", buildID: "fixture", categories: [], voices: ["en-us"])
        return GameRecord(installPath: gameLocation, ownership: .created, executable: try SafeRelativePath("Game.exe"), installed: build,
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func setStatus(_ status: GameStatus, for id: String) { state.withLock { $0.statuses[id] = status } }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        let error = state.withLock { $0.estimates.append(GameCall(action: "estimate", id: id, voices: voices)); return $0.estimateError }
        if let error { throw error }
        return GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150)
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "install", id: id, approved: approved, voices: voices), kind: .install)
    }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "adopt", id: id, voices: voices), kind: .adopt)
    }
    func update(_ id: String, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "update", id: id, approved: approved), kind: .update)
    }
    func resume(_ id: String, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "resume", id: id, approved: approved), kind: .install)
    }
    func verify(_ id: String, mode: Verifier.Mode) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "verify", id: id), kind: .repair)
    }
    func setVoices(_ id: String, _ voices: Set<String>) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "voices", id: id, voices: voices), kind: .voices)
    }
    func uninstall(_ id: String) async throws {
        state.withLock { $0.calls.append(GameCall(action: "uninstall", id: id)); $0.statuses[id] = .notInstalled }
    }
    private func open(_ call: GameCall, kind: PendingOperation.Kind) -> AsyncThrowingStream<OperationEvent, any Error> {
        let pair = AsyncThrowingStream<OperationEvent, any Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.terminations += 1 } }
        state.withLock { $0.calls.append(call); $0.active = call.id; $0.statuses[call.id] = .paused(kind); $0.continuation = pair.continuation }
        if call.action == "install", let approvalTerminalRead {
            let source = SuspendedApprovalEvents(terminal: approvalTerminalRead)
            return GameEventStream(unfolding: { try await source.next() })
        }
        return pair.stream
    }
    func emit(_ event: OperationEvent) { state.withLock { $0.continuation }?.yield(event) }
    func progress(_ count: Int64) { emit(.progress(downloaded: count, totalNetwork: 1000, staged: 0, totalStaged: 1000)) }
    func fail(_ error: LauncherError) { state.withLock { $0.continuation }?.finish(throwing: error) }
    func finish() { let continuation = state.withLock { let c = $0.continuation; $0.continuation = nil; return c }; continuation?.finish() }
}

private final class GameReadGate: Sendable {
    private struct State {
        var entered = false, released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var entered: Bool { state.withLock { $0.entered } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock {
                $0.entered = true
                if $0.released { return true }
                $0.continuation = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }
    func release() {
        let continuation = state.withLock {
            $0.released = true
            let continuation = $0.continuation; $0.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private actor SuspendedApprovalEvents {
    let terminal: GameReadGate
    private var sentApproval = false
    init(terminal: GameReadGate) { self.terminal = terminal }
    func next() async throws -> OperationEvent? {
        if !sentApproval {
            sentApproval = true
            return .needsBatchApproval(required: 200, available: 100)
        }
        await terminal.wait()
        throw LauncherError.insufficientSpace(required: 200, available: 100)
    }
}

private final class GameFailingHTTP: HTTPClient, Sendable {
    let error: LauncherError
    private let urls = Mutex<[URL]>([])
    init(error: LauncherError) { self.error = error }
    var requests: [URL] { urls.withLock { $0 } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        urls.withLock { $0.append(url) }
        throw error
    }
}
