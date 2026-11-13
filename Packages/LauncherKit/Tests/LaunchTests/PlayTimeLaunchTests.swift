// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct PlayTimeLaunchTests {
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
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 600)
        // Journal finalization retries must neither inflate nor duplicate the interval.
        time.withLock { $0 = Date(timeIntervalSince1970: 9000) }
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(try await f.journal() == nil)
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 600)
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
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 600)
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
    func reattachedWatcherRequiresPositiveGameObservationForUnboundedEnd(mode: String) async throws {
        let f = try await ManagerFixture.make(initialGame: mode == "live")
        var session = try await f.saveSnapshot(state: .running, processes: [])
        session.runningSince = Date(timeIntervalSince1970: 0)
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
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == (mode == "live" ? 200_000 : nil))
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
        #expect(try await BlockingIO.run { try PlayTimeStore(paths: paths).load()["starrail"]?.totalSeconds } == 600)
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
