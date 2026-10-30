// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct LaunchLifecycleLogTests {
    @Test func blockedLogWritersCannotDelaySupervisionOrRestore() async throws {
        let f = try await ManagerFixture.make(), events = ManagerEvents()
        let eventGate = BlockingTestGate(), sessionGate = BlockingTestGate()
        defer { eventGate.release(); sessionGate.release() }
        let eventLog = EventLog(directory: f.paths.logs, pendingRecords: 128, beforeWrite: { eventGate.block() })
        let manager = f.manager(log: eventLog, beforeSessionLogWrite: { sessionGate.block() })
        let consumer = await f.consume(manager, events: events)
        try await eventGate.entered.wait()
        try await sessionGate.entered.wait()
        await events.waitForRunning()
        await manager.markReady(game: "starrail")
        try await f.end(manager)
        await consumer.value; await manager.waitForSupervision(game: "starrail")
        #expect(try await f.journal() == nil)
        #expect(await manager.liveSession(for: "starrail") == nil)
        #expect(f.proxy.stops == 1)
        try await f.assertOriginalRestored()
        try await BlockingIO.run {
            let lock = try SessionLock.acquire(paths: f.paths, game: "starrail")
            let fs = try ContainedFileSystem(root: f.paths.root)
            let pins = try f.runtime.selected.componentIDs.map {
                try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\($0).lock"))
            }
            withExtendedLifetime((lock, pins)) {}
        }
        eventGate.release(); sessionGate.release()
        await manager.flushLogs()
        #expect(try await readEvents(f).contains { $0.message == "Session ended" })
    }

    @Test func failedLogWritersCannotChangeLaunchOutcome() async throws {
        let f = try await ManagerFixture.make(), events = ManagerEvents()
        let log = EventLog(directory: f.paths.logs, pendingRecords: 128,
            beforeWrite: { throw LauncherError.io("Injected event storage failure") })
        let manager = f.manager(log: log, beforeSessionLogWrite: { throw LauncherError.io("Injected session storage failure") })
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await manager.markReady(game: "starrail")
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        #expect(try await f.journal() == nil)
        #expect(await events.values.contains { if case .ended(normal: true) = $0 { true } else { false } })
        #expect(await events.values.contains { if case .restored(.clean) = $0 { true } else { false } })
        #expect(!((await events.values).contains { if case .failed = $0 { true } else { false } }))
        try await f.assertOriginalRestored()
    }

    @Test func reattachDoesNotWaitForRecoveredLogStorage() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        let log = try await BlockingIO.run { try SessionLog.create(paths: f.paths, game: "starrail", header: [:]) }
        _ = try await f.saveSnapshot(state: .running, processes: [], sessionLogURL: log.url)
        let eventGate = BlockingTestGate(), sessionGate = BlockingTestGate()
        defer { eventGate.release(); sessionGate.release() }
        let eventLog = EventLog(directory: f.paths.logs, pendingRecords: 128, beforeWrite: { eventGate.block() })
        let manager = f.manager(log: eventLog, beforeSessionLogWrite: { sessionGate.block() })
        _ = await manager.reattachAll()
        try await eventGate.entered.wait(); try await sessionGate.entered.wait()
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
        eventGate.release(); sessionGate.release()
        await manager.flushLogs()
        #expect(try await sessionText(log.url).contains("Session ended while MacGacha was closed"))
    }
    @Test func verifiedBuildsUseSophonTags() throws {
        #expect(Recipes.recipe(for: "genshin")?.verifiedBuilds == ["7.1.0"])
        #expect(Recipes.recipe(for: "zzz")?.verifiedBuilds == ["3.3.0"])
        for game in Recipes.games {
            let recipe = try #require(Recipes.recipe(for: game))
            #expect(recipe.verifiedBuilds.isEmpty == (GameDefinition.find(game)?.region == .mainlandChina))
            for build in recipe.verifiedBuilds {
                let parts = build.split(separator: ".", omittingEmptySubsequences: false)
                #expect(parts.count >= 2)
                #expect(parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
            }
        }
    }

    @Test(arguments: [true, false]) func lifecycleLoggedWithOptionalSessionOutput(logsEnabled: Bool) async throws {
        let f = try await ManagerFixture.make(logsEnabled: logsEnabled), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        let logURL = await manager.liveSession(for: "starrail")?.sessionLogURL
        await manager.markReady(game: "starrail")
        await events.waitForReady()
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        try #require(records.count == 5)
        #expect(records.map(\.message) == ["Launch started", "Game Mode skipped; using normal Wine", "Game running", "Session ended", "Restore outcome"])
        #expect(records.first?.metadata["game"] == "starrail")
        #expect(records.first?.metadata["backend"] == "d3dmetal")
        #expect(records.first?.metadata["buildVerification"] == "verified")
        #expect(records[1].metadata["reason"] == "helperUnavailable")
        #expect(records[3].metadata["outcome"] == "normal")
        #expect(records[4].metadata["outcome"] == "clean")
        #expect(records[4].metadata["resolved"] == "1")
        if logsEnabled {
            let url = try #require(logURL)
            let text = try await sessionText(url)
            for line in ["files hidden: 1", "game process detected: pid 23456", "game window ready",
                "session ended: normal", "restore outcome: clean resolved=1 pending=0 conflicts=0"] {
                #expect(text.contains(line))
            }
        } else { #expect(logURL == nil) }
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!encoded.contains(f.temp.url.path))
        #expect(!encoded.contains("WINEPREFIX"))
    }

    @Test func endedBeforeReadyAndFailureStageAreLogged() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        let url = try #require(await manager.liveSession(for: "starrail")?.sessionLogURL)
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        #expect(records.first { $0.message == "Session ended" }?.metadata["outcome"] == "before ready")
        #expect(records.last?.message == "Launch failed")
        #expect(records.last?.metadata["stage"] == "watch")
        #expect(try await sessionText(url).contains("session ended: before ready"))
        #expect(try await sessionText(url).contains("failed watch case=io"))
    }

    @Test func startupFailureIsLogged() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events, build: "untested")
        for second in 1...60 {
            await f.clock.waitForSleep(second, duration: .seconds(1)); f.clock.advance(by: .seconds(1))
        }
        await consumer.value; await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        #expect(records.first?.metadata["buildVerification"] == "unverified")
        #expect(records.first { $0.message == "Session ended" }?.metadata["outcome"] == "startup failure")
        #expect(records.last?.metadata["stage"] == "watch")
        let values = await events.values
        let url = try #require(values.compactMap { event -> URL? in
            if case .failed(let failure) = event { return failure.logURL }; return nil
        }.first)
        #expect(try await sessionText(url).contains("session ended: startup failure"))
        #expect(try await sessionText(url).contains("failed watch case=io"))
    }

    @Test(arguments: [true, false]) func restoreOutcomesIncludeCounts(conflict: Bool) async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        let url = try #require(await manager.liveSession(for: "starrail")?.sessionLogURL)
        let snapshot = try #require(try await f.journal())
        let hidden = try #require(snapshot.hides.first)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.installRoot)
            if conflict { try fs.writeAtomically(Data("new original".utf8), to: f.hiddenPath) }
            else { try fs.removeFile(at: SafeRelativePath("StarRail_Data/Plugins/x86_64/\(hidden.hiddenName)")) }
        }
        await manager.markReady(game: "starrail")
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        let outcome = try #require(records.last { $0.message == "Restore outcome" })
        #expect(outcome.metadata["outcome"] == (conflict ? "conflict" : "pending"))
        #expect(outcome.metadata["resolved"] == (conflict ? "1" : "0"))
        #expect(outcome.metadata["pending"] == (conflict ? "0" : "1"))
        #expect(outcome.metadata["conflicts"] == (conflict ? "1" : "0"))
        #expect(try await sessionText(url).contains(conflict
            ? "restore outcome: conflict resolved=1 pending=0 conflicts=1"
            : "restore outcome: pending resolved=0 pending=1 conflicts=0"))
        if !conflict {
            let report = try await BlockingIO.run {
                String(decoding: try ContainedFileSystem(root: f.paths.root).readFile(at:
                    SafeRelativePath("Games/starrail/recovery/\(snapshot.sessionID.uuidString).json"), maxBytes: 1 << 20), as: UTF8.self)
            }
            #expect(report.contains("Launch recovery is pending"))
            // Repair the injected missing copy and drain retained ownership.
            try await BlockingIO.run {
                try ContainedFileSystem(root: f.installRoot).writeAtomically(f.original, to: f.hiddenPath)
            }
            try await manager.recoverIfNeeded(game: "starrail")
            await manager.flushLogs()
            #expect(try await sessionText(url).contains("restore outcome: clean resolved=1 pending=0 conflicts=0"))
        }
    }

    @Test func preSpawnFailureIsOperationalEvenWithSessionLogsOff() async throws {
        let f = try await ManagerFixture.make(logsEnabled: false), manager = f.manager(), events = ManagerEvents()
        f.preparation.fail()
        let consumer = await f.consume(manager, events: events)
        await consumer.value; await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        #expect(records.contains { $0.message == "Launch failed" && $0.metadata["stage"] == "prepare" })
        #expect(!records.contains { $0.message == "Game running" })
    }

    @Test(arguments: [true, false])
    func spawnFailureHasPathFreeCaseAndErrno(logsEnabled: Bool) async throws {
        try await assertFailureLogged(.processSpawnFailed(errno: EBADARCH), stage: .spawn,
            expectedCase: "processSpawnFailed", reason: "EBADARCH", logsEnabled: logsEnabled)
    }

    @Test func processFailureHasOnlyExitCodeAndNoPrivatePayload() async throws {
        try await assertFailureLogged(.processFailed(executable: "/Users/private-person/private/wineboot",
            exitCode: 42, stderrTail: "private-person https://example.invalid/?token=planted-secret"),
            stage: .prepare, expectedCase: "processFailed", reason: "exit code 42")
    }

    @Test func freeFormFailurePayloadIsNeverLoggedAsAReason() async throws {
        try await assertFailureLogged(.io("EBADARCH /Users/private-person/private token=planted-secret"),
            stage: .prepare, expectedCase: "io", reason: nil)
    }

    private func assertFailureLogged(_ error: LauncherError, stage: LaunchStage, expectedCase: String,
        reason: String?, logsEnabled: Bool = true) async throws {
        let f = try await ManagerFixture.make(logsEnabled: logsEnabled), manager = f.manager(), events = ManagerEvents()
        if stage == .spawn { f.spawner.fail(error) } else { f.preparation.fail(error) }
        let consumer = await f.consume(manager, events: events)
        await consumer.value; await manager.waitForSupervision(game: "starrail"); await manager.flushLogs()
        let records = try await readEvents(f)
        let failed = try #require(records.first { $0.message == "Launch failed" })
        var expected = ["game": "starrail", "stage": stage.rawValue, "case": expectedCase]
        expected["reason"] = reason
        #expect(failed.metadata == expected)
        var output = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        if logsEnabled {
            let values = await events.values
            let url = try #require(values.compactMap { event -> URL? in
                if case .failed(let failure) = event { return failure.logURL }; return nil
            }.first)
            let text = try await sessionText(url)
            #expect(text.contains("failed \(stage.rawValue) case=\(expectedCase)" + (reason.map { " reason=\($0)" } ?? "")))
            // Session headers intentionally contain local paths; only lifecycle lines are path-free.
            output += text.split(separator: "\n").filter { $0.contains("failed ") }.joined(separator: "\n")
        }
        for privateValue in [f.temp.url.path, "/Users/", "private-person", "planted-secret", "token="] {
            #expect(!output.contains(privateValue))
        }
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func reattachAfterExitLogsEndOnceAcrossAnotherRestart() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        let log = try await BlockingIO.run { try SessionLog.create(paths: f.paths, game: "starrail", header: [:]) }
        let snapshot = try await f.saveSnapshot(state: .running, processes: [], sessionLogURL: log.url)
        f.journalOps.armDelete()
        var manager: LaunchManager? = f.manager()
        _ = await manager?.reattachAll()
        let journal = try #require(try await f.journal())
        let data = try JSONEncoder().encode(journal)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["endLogged"] as? Bool == true)
        #expect(journal.sessionID == snapshot.sessionID)
        await manager?.flushLogs()
        manager = nil
        let second = f.manager()
        _ = await second.reattachAll()
        await second.flushLogs()
        #expect(try await f.journal() == nil)
        let records = try await readEvents(f).filter { $0.message == "Session ended" }
        #expect(records.count == 1)
        #expect(records.first?.metadata["outcome"] == "while MacGacha was closed")
        let text = try await sessionText(log.url)
        #expect(text.components(separatedBy: "Session ended while MacGacha was closed").count == 2)
        try await f.assertOriginalRestored()
    }

    @Test func guardRecoveryLogsVerifiedEnd() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        let log = try await BlockingIO.run { try SessionLog.create(paths: f.paths, game: "starrail", header: [:]) }
        _ = try await f.saveSnapshot(state: .running, processes: [], sessionLogURL: log.url)
        // First recovery cannot durably record the verified end. The guard owns
        // the next retry, without a watcher, once that transient write recovers.
        f.journalOps.arm()
        let manager = f.manager()
        _ = await manager.reattachAll()
        #expect(await manager.liveSession(for: "starrail")?.state == .recoveryPending)
        try await manager.recoverIfNeeded(game: "starrail")
        await manager.flushLogs()
        let ends = try await readEvents(f).filter { $0.message == "Session ended" }
        #expect(ends.count == 1)
        #expect(ends.first?.metadata["outcome"] == "while MacGacha was closed")
        #expect(try await sessionText(log.url).contains("Session ended while MacGacha was closed"))
    }

    private struct Record: Codable, Sendable {
        let category: String
        let message: String
        let metadata: [String: String]
    }
    private func readEvents(_ f: ManagerFixture) async throws -> [Record] {
        try await BlockingIO.run {
            let bytes = try ContainedFileSystem(root: f.paths.root).readFile(at: SafeRelativePath("Logs/macgacha.log"), maxBytes: 1 << 20)
            return try bytes.split(separator: 10).map { try JSONDecoder().decode(Record.self, from: Data($0)) }.filter { $0.category == "launch" }
        }
    }
    private func sessionText(_ url: URL) async throws -> String {
        try await BlockingIO.run {
            String(decoding: try ContainedFileSystem(root: url.deletingLastPathComponent()).readFile(at: SafeRelativePath(url.lastPathComponent), maxBytes: 1 << 20), as: UTF8.self)
        }
    }
}
