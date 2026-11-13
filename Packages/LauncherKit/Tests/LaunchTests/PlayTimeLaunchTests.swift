// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
@testable import LauncherCore
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct PlayTimeLaunchTests {
    @Test(arguments: [false, true])
    func restartUsesRealRunningSnapshotAndBoundsRebootFallback(rebooted: Bool) async throws {
        let f = try await ManagerFixture.make(), paths = f.paths
        let wait = PlayTimeWaitingRunner(), events = ManagerEvents()
        let first = f.manager(runner: wait, now: { Date(timeIntervalSince1970: 1000) })
        let consumer = await f.consume(first, events: events)
        await events.waitForRunning()
        try await wait.entered.wait()
        // No observation callbacks run while the real supervisor awaits wineserver.
        f.clock.advance(by: .seconds(600))
        let running = try #require(try await f.journal())
        wait.released.signal()
        try await f.end(first)
        await consumer.value
        await f.waitForRestore(first)
        // Replay the actual crash-time journal after releasing the first manager's
        // ownership. Remove its later accounting so it cannot mask a lost interval.
        try await BlockingIO.run {
            try LaunchJournal(paths: paths).write(running)
            try ContainedFileSystem(root: paths.root).removeFile(at: SafeRelativePath("PlayTime/play-time.json"))
        }
        let nextClock = ManagerClock()
        nextClock.advance(by: .seconds(rebooted ? 10 : 600))
        f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] }
        let next = f.manager(clock: nextClock,
            bootSessionUUID: rebooted ? "CB1D5699-35A6-48E8-A53F-9A88C918DAE8" : ManagerFixture.bootSessionUUID,
            now: { Date(timeIntervalSince1970: 1900) })
        _ = await next.reattachAll()
        await nextClock.waitForSleep(1, duration: .seconds(3))
        f.inspector.update { $0.processes = []; $0.alive = [] }
        nextClock.advance(by: .seconds(3))
        await f.waitForRestore(next)
        let summary = try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"] }
        #expect(summary?.totalSeconds == (rebooted ? 900 : 603))
        #expect(summary?.lastPlayed == Date(timeIntervalSince1970: 1000))
    }

    @Test(arguments: [-3600.0, 360_000.0])
    func liveDurationIgnoresWallClockJumps(wallJump: Double) async throws {
        let f = try await ManagerFixture.make(), time = Mutex(Date(timeIntervalSince1970: 10_000))
        let manager = f.manager(now: { time.withLock { $0 } }), events = ManagerEvents(), paths = f.paths
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        time.withLock { $0 = Date(timeIntervalSince1970: 10_000 + wallJump) }
        f.inspector.update { $0.processes = []; $0.alive = [] }
        f.clock.advance(by: .seconds(600))
        await consumer.value
        let summary = try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"] }
        #expect(summary?.totalSeconds == 600)
        #expect(summary?.lastSessionSeconds == 600)
        #expect(summary?.lastPlayed == Date(timeIntervalSince1970: 10_000))
    }

    @Test func realRedactedLifecycleLogDoesNotDuplicateRecordedSession() async throws {
        let f = try await ManagerFixture.make(), paths = f.paths
        let log = EventLog(directory: paths.logs), manager = f.manager(log: log), events = ManagerEvents()
        let backfillFirstRoot = try ManagerTemporaryDirectory()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        let session = try #require(try await f.journal())
        try await f.end(manager)
        await consumer.value
        await log.flush()
        try await BlockingIO.run {
            let store = PlayTimeStore(paths: paths), before = try store.load()
            let fs = try ContainedFileSystem(root: paths.root), path = try SafeRelativePath("Logs/macgacha.log")
            let data = try fs.readFile(at: path, maxBytes: 8 << 20)
            var lines = Data()
            var pairs = 0
            for line in data.split(separator: 10) {
                let event = try JSONDecoder().decode(EventLog.Record.self, from: Data(line))
                guard ["Game running", "Session ended"].contains(event.message) else { continue }
                pairs += 1
                #expect(event.metadata["sessionID"] == nil)
                let playID = try #require(event.metadata["playID"])
                #expect((try? Digest(algorithm: .sha256, hex: playID)) != nil)
                // Only normalize timestamps: retain the real writer's redacted metadata.
                // This avoids sleeping for its whole-second wall-clock resolution.
                let date = Date(timeIntervalSince1970: event.message == "Game running" ? 1000 : 1003)
                let normalized = EventLog.Record(ts: ISO8601DateFormatter().string(from: date),
                    level: event.level, category: event.category, message: event.message, metadata: event.metadata)
                lines.append(try JSONEncoder().encode(normalized)); lines.append(10)
            }
            #expect(pairs == 2)
            try fs.writeAtomically(lines, to: path)
            #expect(try store.backfill()?.sessions == 0)
            #expect(try store.load() == before)
            let freshPaths = AppPaths(root: backfillFirstRoot.url)
            let fresh = PlayTimeStore(paths: freshPaths)
            try ContainedFileSystem(root: freshPaths.root).writeAtomically(lines, to: path)
            #expect(try fresh.backfill()?.sessions == 1)
            try fresh.record(sessionID: session.sessionID, game: "starrail", runningSince: session.runningSince,
                endedAt: Date(), recovered: false, supervisedSeconds: 3)
            #expect(try fresh.load()["starrail"]?.totalSeconds == 3)
        }
    }

    @Test func liveEndExcludesPreparationAndRetryUsesOriginalEnd() async throws {
        let f = try await ManagerFixture.make(initialGame: false), time = Mutex(Date(timeIntervalSince1970: 1000))
        let manager = f.manager(now: { time.withLock { $0 } }), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await f.clock.waitForSleep(1, duration: .seconds(1))
        time.withLock { $0 = Date(timeIntervalSince1970: 2000) }
        f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] }
        f.clock.advance(by: .seconds(1))
        await events.waitForRunning()
        let running = try #require(try await f.journal())
        #expect(running.runningSince == Date(timeIntervalSince1970: 2000))
        await manager.markReady(game: "starrail")
        time.withLock { $0 = Date(timeIntervalSince1970: 2600) }
        f.journalOps.armDelete()
        try await f.end(manager); await consumer.value
        let ended = try #require(try await f.journal())
        #expect(ended.verifiedEndedAt == Date(timeIntervalSince1970: 2600))
        let paths = f.paths
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 3)
        // Journal finalization retries must neither inflate nor duplicate the interval.
        time.withLock { $0 = Date(timeIntervalSince1970: 9000) }
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(try await f.journal() == nil)
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 3)
    }

    @Test(arguments: [3600.0, 86_400.0, 86_401.0])
    func recoveredEndUsesBoundedInjectedDetectionTime(seconds: Double) async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        var session = try await f.saveSnapshot(state: .running, processes: [])
        session.runningSince = Date(timeIntervalSince1970: 1000)
        let saved = session, paths = f.paths
        try await BlockingIO.run { try LaunchJournal(paths: paths).write(saved) }
        _ = await f.manager(now: { Date(timeIntervalSince1970: 1000 + seconds) }).reattachAll()
        let summary = try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"] }
        #expect(summary?.totalSeconds == (seconds <= 86_400 ? seconds : nil))
        #expect(try await f.journal() == nil)
    }

    @Test func persistedVerifiedEndSurvivesLongClosedRecovery() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        var session = try await f.saveSnapshot(state: .ending, processes: [])
        session.runningSince = Date(timeIntervalSince1970: 1000)
        session.verifiedEndedAt = Date(timeIntervalSince1970: 101_000)
        session.playTimeEndRecovered = false
        session.supervisedPlaySeconds = 100_000
        session.endLogged = true
        let saved = session, paths = f.paths
        try await BlockingIO.run { try LaunchJournal(paths: paths).write(saved) }
        _ = await f.manager(now: { Date(timeIntervalSince1970: 500_000) }).reattachAll()
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 100_000)
    }

    @Test func failedAccountingRestoresFilesAndRetriesTheCheckpointedInterval() async throws {
        let f = try await ManagerFixture.make(), time = Mutex(Date(timeIntervalSince1970: 1000))
        let manager = f.manager(now: { time.withLock { $0 } }), events = ManagerEvents(), paths = f.paths
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await BlockingIO.run {
            try ContainedFileSystem(root: paths.root).writeAtomically(Data("broken".utf8), to: SafeRelativePath("PlayTime/play-time.json"))
        }
        time.withLock { $0 = Date(timeIntervalSince1970: 1600) }
        try await f.end(manager); await consumer.value; await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
        #expect(try await f.journal()?.verifiedEndedAt == Date(timeIntervalSince1970: 1600))
        try await BlockingIO.run {
            try ContainedFileSystem(root: paths.root).removeFile(at: SafeRelativePath("PlayTime/play-time.json"))
        }
        time.withLock { $0 = Date(timeIntervalSince1970: 5000) }
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 3)
        #expect(try await f.journal() == nil)
    }

    @Test func legacySessionDoesNotUsePreparationDateAsRunningStart() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        _ = try await f.saveSnapshot(state: .running, processes: [])
        _ = await f.manager().reattachAll()
        let paths = f.paths
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load().isEmpty })
        #expect(try await f.journal() == nil)
    }

    @Test(arguments: ["uncertain", "helper", "live"])
    func legacyReattachedWatcherWithoutBootInstantUsesBoundedRecovery(mode: String) async throws {
        let f = try await ManagerFixture.make(initialGame: mode == "live")
        var session = try await f.saveSnapshot(state: .running, processes: [])
        session.runningSince = Date(timeIntervalSince1970: 0)
        session.supervisedPlaySeconds = 120
        let saved = session, paths = f.paths
        try await BlockingIO.run { try LaunchJournal(paths: paths).write(saved) }
        if mode == "uncertain" { f.inspector.update { $0.failuresRemaining = 1 } }
        if mode == "helper" { f.inspector.update { $0.processes = [f.serverProcess] } }
        let manager = f.manager(now: { Date(timeIntervalSince1970: 200_000) })
        _ = await manager.reattachAll()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        f.inspector.update { $0.processes = []; $0.alive = [] }
        f.clock.advance(by: .seconds(3))
        await f.waitForRestore(manager)
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == nil)
    }

    @Test(arguments: [false, true])
    func firstEndCheckpointFailureKeepsOriginalDetectionTime(recovered: Bool) async throws {
        let f = try await ManagerFixture.make(initialGame: !recovered), time = Mutex(Date(timeIntervalSince1970: 2000))
        let ops = PlayTimeEndCheckpointOps { time.withLock { $0 = Date(timeIntervalSince1970: 9000) } }
        let manager = f.manager(now: { time.withLock { $0 } }, journalFileOps: ops), paths = f.paths
        if recovered {
            var session = try await f.saveSnapshot(state: .running, processes: [])
            session.runningSince = Date(timeIntervalSince1970: 2000)
            let saved = session
            try await BlockingIO.run { try LaunchJournal(paths: paths).write(saved) }
            time.withLock { $0 = Date(timeIntervalSince1970: 2600) }
            _ = await manager.reattachAll()
            try await ops.failed.wait()
            try await manager.recoverIfNeeded(game: "starrail")
        } else {
            let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
            await events.waitForRunning()
            time.withLock { $0 = Date(timeIntervalSince1970: 2600) }
            try await f.end(manager)
            try await ops.failed.wait()
            await f.clock.waitForSleep(1, duration: .seconds(1))
            f.clock.advance(by: .seconds(1))
            await f.clock.waitForSleep(2, duration: .seconds(3))
            f.clock.advance(by: .seconds(3))
            await consumer.value
        }
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == (recovered ? 600 : 3))
        #expect(try await f.journal() == nil)
    }

    @Test func failedLaunchWithoutRunningAddsNothing() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await f.clock.waitForSleep(1, duration: .seconds(1))
        f.clock.advance(by: .seconds(60))
        await consumer.value
        let paths = f.paths
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load().isEmpty })
        #expect(try await f.journal() == nil)
    }
}

private final class PlayTimeEndCheckpointOps: FileOps, Sendable {
    private struct State { var containsEnd = false; var fail = true }
    private let state = Mutex(State())
    let failed = TestEvent()
    let afterFailure: @Sendable () -> Void
    init(afterFailure: @escaping @Sendable () -> Void) { self.afterFailure = afterFailure }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if let snapshot = try? JSONDecoder().decode(LaunchSession.self, from: Data(bytes)) {
            state.withLock { $0.containsEnd = snapshot.verifiedEndedAt != nil }
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        let fail = state.withLock { state in
            guard destination == "launch-session.json", state.containsEnd, state.fail else { return false }
            state.fail = false
            return true
        }
        if fail {
            afterFailure(); failed.signal()
            throw LauncherError.io("injected first end checkpoint failure")
        }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

private struct PlayTimeWaitingRunner: ProcessRunner {
    let entered = TestEvent()
    let released = TestEvent()
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        if arguments == ["-w"] {
            entered.signal()
            try await released.wait()
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}
