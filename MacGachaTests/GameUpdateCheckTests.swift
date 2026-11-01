// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import GameLibrary
import Launch
@testable import MacGacha

@Suite @MainActor struct GameUpdateCheckTests {
    @Test func forcedReadBypassesThrottleForOnlyRequestedGame() async throws {
        let fake = UpdateCheckServices(), model = fixture(fake)
        await model.refreshGames()
        #expect(fake.normalReads.count == 3)
        fake.result = .success(.updateAvailable(from: "1.0", to: "2.0"))
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(fake.freshReads == ["genshin"])
        #expect(model.games["genshin"]?.status == .updateAvailable(from: "1.0", to: "2.0"))
        #expect(model.gameUpdateCheck["genshin"] == .updateAvailable)
        await model.refreshGames()
        #expect(fake.normalReads.count == 3)
    }

    @Test func upToDateUsesInjectedDateAndOtherStatusApplicationsClearResult() async {
        let model = fixture(UpdateCheckServices())
        model.checkForGameUpdate("zzz")
        await model.gameUpdateCheckTasks["zzz"]?.value
        #expect(model.gameUpdateCheck["zzz"] == .upToDate(Date(timeIntervalSince1970: 1234)))
        model.setGameState("zzz", GameState(status: .installed(tag: "3.0")))
        #expect(model.gameUpdateCheck["zzz"] == nil)
    }

    @Test func duplicateTapsCoalesce() async {
        let gate = UpdateCheckGate(), fake = UpdateCheckServices(gate: gate), model = fixture(fake)
        model.checkForGameUpdate("genshin")
        let task = model.gameUpdateCheckTasks["genshin"]
        await gate.waitForEntry()
        model.checkForGameUpdate("genshin")
        #expect(model.gameUpdateCheck["genshin"] == .checking)
        #expect(fake.freshReads == ["genshin"])
        await gate.release(); await task?.value
        #expect(model.gameUpdateCheck["genshin"] == .upToDate(Date(timeIntervalSince1970: 1234)))
        #expect(model.gameUpdateCheckTasks.isEmpty)
    }

    @Test func automaticRefreshDuringCheckKeepsManualResult() async {
        let gate = UpdateCheckGate(), fake = UpdateCheckServices(gate: gate), model = fixture(fake)
        fake.result = .success(.updateAvailable(from: "1.0", to: "2.0"))
        model.checkForGameUpdate("genshin")
        let task = model.gameUpdateCheckTasks["genshin"]
        await gate.waitForEntry()
        await model.refreshGames()
        #expect(fake.normalReads.contains("genshin"))
        #expect(model.gameUpdateCheck["genshin"] == .checking)
        await gate.release(); await task?.value
        #expect(model.games["genshin"]?.status == .updateAvailable(from: "1.0", to: "2.0"))
        #expect(model.gameUpdateCheck["genshin"] == .updateAvailable)
    }

    @Test(arguments: ["operation", "approval", "launch", "session", "recovery", "pending", "restart"])
    func busyGameDoesNotCheck(kind: String) async throws {
        let fake = UpdateCheckServices(), model = fixture(fake)
        switch kind {
        case "operation": model.gameOperation = GameOperationToken(id: "genshin", generation: UUID())
        case "approval": model.setGameState("genshin", GameState(status: .paused(.update), activity: .needsApproval(required: 20, available: 10)))
        case "launch": model.launchSlotOwner = "genshin"
        case "session": model.liveLaunchGames.insert("genshin"); model.launchStates["genshin"] = .running
        case "recovery": model.launchStates["genshin"] = .recoveryNeeded("pending")
        case "pending": model.setGameRecord("genshin", try fake.pendingRecord())
        default: model.setLanguageRestart(UUID())
        }
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(fake.freshReads.isEmpty)
        #expect(model.gameUpdateCheck["genshin"] == nil)
    }

    @Test func failureKeepsPreviousStatusAndReportsTypedError() async {
        let fake = UpdateCheckServices(), model = fixture(fake)
        model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
        fake.result = .failure(.transport("injected"))
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(model.games["genshin"]?.status == .installed(tag: "1.0"))
        #expect(model.gameUpdateCheck["genshin"] == .failed(.transport("injected")))
        fake.result = .success(.installed(tag: "1.0"))
        model.checkForGameUpdate("genshin")
        await model.gameUpdateCheckTasks["genshin"]?.value
        #expect(fake.freshReads.count == 2)
        #expect(model.gameUpdateCheck["genshin"] == .upToDate(Date(timeIntervalSince1970: 1234)))
    }

    @Test func regionSwitchKeepsResultScopedToOriginalEdition() async {
        let gate = UpdateCheckGate(), fake = UpdateCheckServices(gate: gate), model = fixture(fake)
        fake.result = .success(.updateAvailable(from: "1.0", to: "2.0"))
        model.checkForGameUpdate("genshin")
        let task = model.gameUpdateCheckTasks["genshin"]
        await gate.waitForEntry()
        model.region = .mainlandChina
        await gate.release(); await task?.value
        #expect(fake.freshReads == ["genshin"])
        #expect(model.games["genshin"]?.status == .updateAvailable(from: "1.0", to: "2.0"))
        #expect(model.games["genshin-cn"]?.status == .unknown)
        #expect(model.gameUpdateCheck["genshin-cn"] == nil)
    }

    @Test func operationRevisionWinsOverLateResponseEvenAfterOperationEnds() async {
        let gate = UpdateCheckGate(), fake = UpdateCheckServices(gate: gate), model = fixture(fake)
        model.checkForGameUpdate("genshin")
        let task = model.gameUpdateCheckTasks["genshin"]
        await gate.waitForEntry()
        model.gameRevisions["genshin"] = UUID()
        model.setGameState("genshin", GameState(status: .installed(tag: "3.0")))
        await gate.release(); await task?.value
        #expect(model.games["genshin"]?.status == .installed(tag: "3.0"))
        #expect(model.gameUpdateCheck["genshin"] == nil)
    }

    @Test func sessionStartingDuringCheckDiscardsResponse() async {
        let gate = UpdateCheckGate(), fake = UpdateCheckServices(gate: gate), model = fixture(fake)
        model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
        fake.result = .success(.updateAvailable(from: "1.0", to: "2.0"))
        model.checkForGameUpdate("genshin")
        let task = model.gameUpdateCheckTasks["genshin"]
        await gate.waitForEntry()
        model.launchSlotOwner = "genshin"
        model.launchStates["genshin"] = .starting(.preflight)
        await gate.release(); await task?.value
        #expect(model.gameUpdateCheck["genshin"] == nil)
        #expect(model.games["genshin"]?.status == .installed(tag: "1.0"))
    }

    private func fixture(_ fake: UpdateCheckServices) -> AppModel {
        let instant = ContinuousClock.now
        return AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/UpdateCheck")),
            services: PreviewRuntimeServices(), defaults: nil, gameServices: fake, locale: Locale(identifier: "en_US"),
            now: { instant }, eventsNow: { Date(timeIntervalSince1970: 1234) })
    }
}

private actor UpdateCheckGate {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered.continuation.yield(())
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func waitForEntry() async { var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class UpdateCheckServices: GameServices, Sendable {
    private struct State {
        var normal: [String] = [], fresh: [String] = []
        var result: Result<GameStatus, LauncherError> = .success(.installed(tag: "1.0"))
    }
    private let state = Mutex(State())
    private let gate: UpdateCheckGate?
    private let backend = PreviewGameServices()
    init(gate: UpdateCheckGate? = nil) { self.gate = gate }
    var normalReads: [String] { state.withLock { $0.normal } }
    var freshReads: [String] { state.withLock { $0.fresh } }
    var result: Result<GameStatus, LauncherError> {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }
    func start() async {}
    func waitUntilIdle(_ id: String) async throws {}
    func status(_ id: String) async -> GameStatus { state.withLock { $0.normal.append(id) }; return .installed(tag: "1.0") }
    func checkForUpdate(_ id: String) async throws -> GameStatus {
        let result = state.withLock { $0.fresh.append(id); return $0.result }
        await gate?.wait()
        return try result.get()
    }
    func record(_ id: String) async throws -> GameRecord? { nil }
    func pendingRecord() throws -> GameRecord {
        GameRecord(installPath: URL(fileURLWithPath: "/inert/Game"), ownership: .created,
            executable: try SafeRelativePath("Game.exe"), pending: PendingOperation(kind: .update, planID: try SafeIdentifier("plan"),
                planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)),
                target: InstalledBuild(tag: "2.0", buildID: "2", categories: [], voices: [])),
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate { try await backend.estimate(id, voices: voices, at: location) }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { await backend.install(id, voices: voices, at: location, approved: approved) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await backend.adopt(id, folder: folder, voices: voices) }
    func update(_ id: String, approved: Bool) async -> GameEventStream { await backend.update(id, approved: approved) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { await backend.resume(id, approved: approved) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await backend.verify(id, mode: mode) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await backend.setVoices(id, voices) }
    func uninstall(_ id: String) async throws { try await backend.uninstall(id) }
}
