// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import GameLibrary
import Testing
@testable import MacGacha

@Suite struct UpdateQueueTests {
    @Test func dailyWindowIncludesStartExcludesEndAndWrapsMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25))!
        var queue = UpdateQueue()
        queue.scheduled = true; queue.startMinute = 22 * 60; queue.endMinute = 6 * 60
        #expect(queue.permits(at: base.addingTimeInterval(22 * 3600), calendar: calendar, onAC: true))
        #expect(queue.permits(at: base.addingTimeInterval(5 * 3600), calendar: calendar, onAC: true))
        #expect(!queue.permits(at: base.addingTimeInterval(6 * 3600), calendar: calendar, onAC: true))
        #expect(!queue.permits(at: base.addingTimeInterval(12 * 3600), calendar: calendar, onAC: true))
        queue.startMinute = 8 * 60; queue.endMinute = 10 * 60
        #expect(queue.permits(at: base.addingTimeInterval(8 * 3600), calendar: calendar, onAC: true))
        #expect(!queue.permits(at: base.addingTimeInterval(10 * 3600), calendar: calendar, onAC: true))
    }

    @Test func defaultsAreImmediateAndACUnknownFailsClosed() {
        var queue = UpdateQueue()
        #expect(queue.permits(at: Date(), onAC: nil))
        queue.requiresAC = true
        #expect(!queue.permits(at: Date(), onAC: nil))
        #expect(!queue.permits(at: Date(), onAC: false))
        #expect(queue.permits(at: Date(), onAC: true))
        queue.enabled = false
        #expect(!queue.permits(at: Date(), onAC: true))
    }

    @Test func roundTripKeepsOrderPausesAndOwnedPlan() throws {
        var queue = UpdateQueue()
        queue.entries = [.init(id: "zzz"), .init(id: "genshin-cn", paused: true, planID: "owned")]
        let restored = try JSONDecoder().decode(UpdateQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored == queue)
        #expect(restored.entries.map(\.id) == ["zzz", "genshin-cn"])
    }
}

@Suite @MainActor struct UpdateQueueModelTests {
    @Test func editingPersistsOrderAndDoesNotDuplicate() async throws {
        let defaults = UserDefaults(suiteName: "UpdateQueueTests.\(UUID())")!
        let fake = QueueGameServices()
        let model = fixture(fake, defaults: defaults)
        for id in ["genshin", "zzz", "starrail"] { model.setGameRecord(id, try await fake.record(id)); model.enqueueUpdate(id) }
        model.enqueueUpdate("genshin")
        model.moveQueuedUpdate("starrail", by: -1)
        model.removeQueuedUpdate("zzz")
        let restored = fixture(fake, defaults: defaults)
        #expect(restored.updateQueue.entries.map(\.id) == ["genshin", "starrail"])
    }

    @Test func queueStartsActualUpdateAndCompletesInOrder() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        try await enqueue("zzz", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { await fake.calls == ["update:genshin"] }
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        await fake.finish("genshin")
        try await eventually { await fake.calls == ["update:genshin", "update:zzz"] }
        #expect(model.updateQueue.entries.map(\.id) == ["zzz"])
        model.pauseGame("zzz"); await model.gameTask?.value
    }

    @Test func manualPauseDoesNotAutomaticallyResumeAndRetryUsesExactPlan() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        model.pauseGame("genshin"); await model.gameTask?.value
        model.evaluateUpdateQueue(); await model.updateQueueTask?.value
        #expect(await fake.calls == ["update:genshin"])
        #expect(model.updateQueue.entries.first?.paused == true)
        model.retryQueuedUpdate("genshin")
        try await eventually { await fake.calls == ["update:genshin", "resume:genshin"] }
        model.pauseGame("genshin"); await model.gameTask?.value
    }

    @Test func constrainedPathCancelsAndResumesOnlyQueueOwnedPlan() async throws {
        let signals = QueueSignals(), fake = QueueGameServices(), model = fixture(fake, signals: signals)
        try await enqueue("genshin", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        signals.network = false; model.evaluateUpdateQueue(); await model.gameTask?.value
        #expect(model.updateQueue.entries.first?.paused == false)
        model.evaluateUpdateQueue(); await model.updateQueueTask?.value
        #expect(await fake.calls == ["update:genshin"])
        signals.network = true; model.evaluateUpdateQueue()
        try await eventually { await fake.calls.last == "resume:genshin" }
        model.pauseGame("genshin"); await model.gameTask?.value
    }

    @Test func queueNeverResumesForeignPendingPlan() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        await fake.makePending("genshin")
        await model.start(); model.evaluateUpdateQueue(); await model.updateQueueTask?.value
        #expect(await fake.calls.isEmpty)
        #expect(model.updateQueue.entries.first?.paused == true)
    }

    @Test func automaticDiscoveryUsesChosenInstalledEditionsAndOfficialCheck() async throws {
        let fake = QueueGameServices(), signals = QueueSignals(), model = fixture(fake, signals: signals)
        model.updateQueue.automatic = true
        model.updateQueue.automaticGames = ["genshin-cn", "zzz"]
        await model.start(); model.evaluateUpdateQueue()
        await model.updateQueueTask?.value
        try await eventually { !(await fake.calls).isEmpty }
        #expect(Set(await fake.checks) == ["genshin-cn", "zzz"])
        #expect(model.updateQueue.entries.allSatisfy { $0.automatic })
        #expect(!(await fake.checks).contains("starrail"))
        model.saveUpdateQueue { $0.automatic = false }
        await model.gameTask?.value
        #expect(model.gameOperation == nil)
        #expect(model.updateQueue.entries.allSatisfy { !$0.automatic })
    }

    @Test func automaticDiscoveryWaitsForIdleNoGameAndNetwork() async throws {
        let fake = QueueGameServices(), signals = QueueSignals(), model = fixture(fake, signals: signals)
        model.updateQueue.automatic = true; model.updateQueue.automaticGames = ["genshin"]
        await model.start()
        signals.network = false; model.evaluateUpdateQueue()
        #expect(model.updateQueueTask == nil)
        signals.network = true; signals.idle = 0; model.evaluateUpdateQueue()
        #expect(model.updateQueueTask == nil)
        signals.idle = 3600; model.launchSlotOwner = "zzz"; model.evaluateUpdateQueue()
        #expect(model.updateQueueTask == nil)
        #expect(await fake.checks.isEmpty)
    }

    @Test func heldEntryDoesNotBlockLaterUpdate() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        try await enqueue("zzz", model: model, fake: fake)
        model.updateQueue.entries[0].paused = true
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { await fake.calls == ["update:zzz"] }
        model.pauseGame("zzz"); await model.gameTask?.value
        #expect(model.updateQueue.entries[0].paused)
    }

    @Test func disablingQueueDrainsCurrentTransferAndStopsBackgroundResidence() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        model.saveUpdateQueue { $0.enabled = false }
        await model.gameTask?.value
        #expect(model.gameOperation == nil)
        #expect(!model.keepsUpdateQueueRunning)
        #expect(model.updateQueueTimer == nil)
        #expect(model.updateQueue.entries.first?.paused == false)
    }

    @Test func playContinuationCannotBypassConnectionGate() async throws {
        let signals = QueueSignals(), fake = QueueGameServices(), model = fixture(fake, signals: signals)
        try await enqueue("genshin", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        let token = try #require(model.gameOperation)
        model.launchSlotOwner = "zzz"
        try await model.pauseDownloadForPlay(token)
        #expect(model.pausedDownloadForPlay?.token.isQueuedUpdate == true)
        signals.network = false; model.launchSlotOwner = nil
        model.resumeDownloadAfterPlayIfPossible()
        await Task.yield()
        #expect(await fake.calls == ["update:genshin"])
        signals.network = true; model.evaluateUpdateQueue()
        try await eventually { await fake.calls.last == "resume:genshin" }
        #expect(model.gameOperation?.isQueuedUpdate == true)
        model.pauseGame("genshin"); await model.gameTask?.value
    }

    @Test func ACTransitionPausesAndResumesOwnedPlan() async throws {
        let signals = QueueSignals(), fake = QueueGameServices(), model = fixture(fake, signals: signals)
        model.updateQueue.requiresAC = true
        try await enqueue("genshin", model: model, fake: fake)
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.updateQueue.entries.first?.pending != nil }
        signals.onAC = false; model.evaluateUpdateQueue(); await model.gameTask?.value
        #expect(model.gameOperation == nil)
        signals.onAC = true; model.evaluateUpdateQueue()
        try await eventually { await fake.calls.last == "resume:genshin" }
        model.pauseGame("genshin"); await model.gameTask?.value
    }

    @Test func automaticDiscoveryRearmsTimerForActiveUpdate() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        model.updateQueue.automatic = true; model.updateQueue.automaticGames = ["genshin"]
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { model.gameOperation?.isQueuedUpdate == true }
        #expect(model.nextUpdateQueueDelay() <= 30)
        model.pauseGame("genshin"); await model.gameTask?.value
        #expect(model.nextUpdateQueueDelay() > 3600)
    }

    @Test func heldPlayContinuationDoesNotBlockNextQueuedGame() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        try await enqueue("zzz", model: model, fake: fake)
        model.updateQueue.entries[0].paused = true
        await fake.makePending("genshin")
        let record = try #require(try await fake.record("genshin"))
        let pending = try #require(record.pending)
        model.updateQueue.entries[0].pending = pending
        let token = GameOperationToken(id: "genshin", generation: UUID(), isDownload: true, isQueuedUpdate: true)
        model.pausedDownloadForPlay = PlayPausedDownload(token: token, plan: .game(pending))
        await model.start(); model.evaluateUpdateQueue()
        try await eventually { await fake.calls == ["update:zzz"] }
        #expect(model.pausedDownloadForPlay == nil)
        #expect(model.updateQueue.entries[0].pending == pending)
        model.pauseGame("zzz"); await model.gameTask?.value
    }

    @Test func explicitManualUpdateDetachesQueueOwnership() async throws {
        let fake = QueueGameServices(), model = fixture(fake)
        try await enqueue("genshin", model: model, fake: fake)
        model.updateQueue.entries[0].paused = true
        await model.start()
        model.updateGame("genshin")
        try await eventually { await fake.calls == ["update:genshin"] }
        #expect(model.updateQueue.entries.isEmpty)
        #expect(model.gameOperation?.isQueuedUpdate == false)
        model.pauseGame("genshin"); await model.gameTask?.value
    }

    private func fixture(_ fake: QueueGameServices, defaults: UserDefaults? = nil, signals: QueueSignals = QueueSignals()) -> AppModel {
        AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/Queue")),
            services: PreviewRuntimeServices(), defaults: defaults, gameServices: fake,
            updateQueueSignals: { (signals.network, signals.onAC, signals.idle) })
    }

    private func enqueue(_ id: String, model: AppModel, fake: QueueGameServices) async throws {
        model.setGameRecord(id, try await fake.record(id)); model.enqueueUpdate(id)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("Queue condition timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class QueueSignals {
    var network = true
    var onAC: Bool? = true
    var idle: TimeInterval = 3600
}

private actor QueueGameServices: GameServices {
    var calls: [String] = []
    var checks: [String] = []
    private var records: [String: GameRecord] = [:]
    private var streams: [String: GameEventStream.Continuation] = [:]
    private let backend = PreviewGameServices()
    func start() async {}
    func waitUntilIdle(_ id: String) async throws {}
    func status(_ id: String) async -> GameStatus {
        if records[id]?.pending != nil { return .paused(.update) }
        return .installed(tag: records[id]?.installed?.tag ?? "1.0")
    }
    func checkForUpdate(_ id: String) async throws -> GameStatus {
        checks.append(id); return .updateAvailable(from: "1.0", to: "2.0")
    }
    func record(_ id: String) async throws -> GameRecord? {
        if let record = records[id] { return record }
        let record = GameRecord(installPath: URL(fileURLWithPath: "/inert/\(id)"), ownership: .created,
            executable: try SafeRelativePath("Game.exe"), installed: InstalledBuild(tag: "1.0", buildID: "1", categories: [], voices: []),
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: UInt64(records.count + 1)))
        records[id] = record; return record
    }
    func makePending(_ id: String) async {
        _ = try? await record(id)
        records[id]?.pending = try! PendingOperation(kind: .update, planID: SafeIdentifier("owned-\(id)"),
            planDigest: Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)),
            target: InstalledBuild(tag: "2.0", buildID: "2", categories: [], voices: []))
    }
    func finish(_ id: String) {
        let target = records[id]?.pending?.target
        records[id]?.installed = target
        records[id]?.pending = nil
        streams[id]?.yield(.phase(.completed)); streams[id]?.finish(); streams[id] = nil
    }
    func update(_ id: String, approved: Bool) async -> GameEventStream {
        calls.append("update:\(id)"); await makePending(id); return stream(id)
    }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { calls.append("resume:\(id)"); return stream(id) }
    private func stream(_ id: String) -> GameEventStream {
        let pair = GameEventStream.makeStream()
        streams[id] = pair.continuation
        pair.continuation.yield(.phase(.staging))
        return pair.stream
    }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate { try await backend.estimate(id, voices: voices, at: location) }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { await backend.install(id, voices: voices, at: location, approved: approved) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await backend.adopt(id, folder: folder, voices: voices) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await backend.verify(id, mode: mode) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await backend.setVoices(id, voices) }
    func uninstall(_ id: String) async throws { try await backend.uninstall(id) }
}
