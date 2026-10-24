// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Dispatch
import Foundation
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct SessionWatcherTests {
    @Test func ownedWrapperReaperNeverWaitsOnRetiredPIDAgain() async throws {
        let calls = Mutex(0)
        let reaper = OwnedWrapperReaper(identity: .init(pid: 4321, startTime: 1)) { pid in
            #expect(pid == 4321)
            return calls.withLock { calls in calls += 1; return calls == 2 }
        }
        #expect(try await !reaper.poll())
        #expect(try await reaper.poll())
        #expect(try await reaper.poll())
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func retriesShareTheOwnedReaperWithoutRevisitingRetiredPID() async throws {
        let calls = Mutex(0)
        let identity = ProcessIdentity(pid: 4321, startTime: 1)
        let reaper = OwnedWrapperReaper(identity: identity) { _ in
            calls.withLock { $0 += 1 }; return true
        }
        let watcher = SessionWatcher(inspector: WatchInspector { throw ProcessInspectionError.incompleteScan },
            runner: WatchRunner(), clock: WatchClock())
        for _ in 0..<2 {
            await #expect(throws: ProcessInspectionError.incompleteScan) {
                try await watcher.watch(session: watchSession(), executable: "StarRail.exe",
                    ownedWrapper: identity, ownedReaper: reaper) { _ in }
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func delayedWineserverDoesNotEndSpawning() async throws {
        let clock = WatchClock()
        let game = watchProcess(2, "C:\\Games\\StarRail.EXE")
        let inspector = WatchInspector { clock.elapsed >= .seconds(40) && clock.elapsed < .seconds(43) ? [game] : [] }
        let observations = Mutex([[ProcessIdentity]]())
        try await SessionWatcher(inspector: inspector, runner: WatchRunner(), clock: clock)
            .watch(session: watchSession(), executable: "StarRail.exe") { ids in observations.withLock { $0.append(ids) } }
        #expect(clock.elapsed == .seconds(43))
        #expect(observations.withLock { $0.first } == [game.identity])
    }

    @Test func noGameProcessFor60sIsStartupFailure() async throws {
        let clock = WatchClock()
        do {
            try await SessionWatcher(inspector: WatchInspector { [] }, runner: WatchRunner(), clock: clock)
                .watch(session: watchSession(), executable: "StarRail.exe") { _ in Issue.record("Unexpected running") }
            Issue.record("Missing startup failure")
        } catch SessionWatchError.startup { #expect(clock.elapsed == .seconds(60)) }
    }

    @Test func selfRestartGapKeepsSession() async throws {
        let clock = WatchClock()
        let first = watchProcess(2, "/games/StarRail.exe"), second = watchProcess(3, "/games/StarRail.exe")
        let server = watchProcess(4, "/runtime/bin/wineserver")
        let inspector = WatchInspector {
            if clock.elapsed < .seconds(3) { return [first] }
            if clock.elapsed < .seconds(6) { return [second, server] }
            return []
        }
        let observed = Mutex([[ProcessIdentity]]())
        let runner = WatchRunner()
        try await SessionWatcher(inspector: inspector, runner: runner, clock: clock)
            .watch(session: watchSession(), executable: "StarRail.exe") { ids in observed.withLock { $0.append(ids) } }
        #expect(clock.elapsed == .seconds(6))
        #expect(runner.calls.withLock { $0 } == 2)
        #expect(observed.withLock { $0.contains([second.identity]) })
    }

    @Test func lingeringHelperKeepsSessionUntilWineserverExits() async throws {
        let clock = WatchClock()
        let server = watchProcess(4, "/runtime/bin/wineserver")
        let inspector = WatchInspector { clock.elapsed < .seconds(9) ? [server] : [] }
        let runner = WatchRunner()
        try await SessionWatcher(inspector: inspector, runner: runner, clock: clock)
            .watch(session: watchSession(state: .running), executable: "StarRail.exe") { _ in }
        #expect(clock.elapsed == .seconds(9))
        #expect(runner.calls.withLock { $0 } == 3)
    }

    @Test func wineserverPresenceResetsContinuousStartupGrace() async throws {
        let clock = WatchClock()
        let server = watchProcess(4, "/runtime/bin/wineserver")
        let inspector = WatchInspector { clock.elapsed == .seconds(59) ? [server] : [] }
        do {
            try await SessionWatcher(inspector: inspector, runner: WatchRunner(), clock: clock)
                .watch(session: watchSession(), executable: "StarRail.exe") { _ in }
            Issue.record("Missing startup failure")
        } catch SessionWatchError.startup { #expect(clock.elapsed == .seconds(120)) }
    }

    @Test func failedWineserverWaitDoesNotConfirmSessionEnd() async throws {
        let clock = WatchClock()
        let runner = FailedWatchRunner()
        await #expect(throws: LauncherError.processFailed(executable: "wineserver", exitCode: 7, stderrTail: "")) {
            try await SessionWatcher(inspector: WatchInspector { [] }, runner: runner, clock: clock)
                .watch(session: watchSession(state: .running), executable: "StarRail.exe") { _ in }
        }
        #expect(clock.elapsed == .zero)
    }

    @Test func synchronousWineserverStartupDoesNotBlockCooperativeWorker() async throws {
        let runner = BlockingStartupWatchRunner()
        let task = Task {
            try await SessionWatcher(inspector: WatchInspector { [] }, runner: runner, clock: WatchClock())
                .watch(session: watchSession(state: .running), executable: "StarRail.exe") { _ in }
        }
        defer { runner.release.signal(); task.cancel() }
        try await runner.entered.wait()
        // Reaching this continuation with a width-one cooperative pool proves
        // synchronous Process.run startup occupies the blocking I/O executor.
        runner.release.signal()
        try await task.value
    }

    @Test func cancellationJoinsTheWineserverWait() async throws {
        let runner = WaitingWatchRunner()
        let task = Task {
            try await SessionWatcher(inspector: WatchInspector { [] }, runner: runner, clock: WatchClock())
                .watch(session: watchSession(state: .running), executable: "StarRail.exe") { _ in }
        }
        try await runner.entered.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.cancelled.withLock { $0 })
    }

    @Test func inspectorFailurePropagatesWithoutConfirmingEnd() async throws {
        let clock = WatchClock()
        let inspector = WatchInspector { throw LauncherError.io("inspection unavailable") }
        await #expect(throws: LauncherError.io("inspection unavailable")) {
            try await SessionWatcher(inspector: inspector, runner: WatchRunner(), clock: clock)
                .watch(session: watchSession(), executable: "StarRail.exe") { _ in }
        }
        #expect(clock.elapsed == .zero)
    }

    @Test func wineLoaderUsesExecutableArgumentButNotArbitraryArguments() async throws {
        let clock = WatchClock()
        let game = InspectedProcess(identity: .init(pid: 2, startTime: 2), executablePath: "/runtime/bin/wine64-preloader",
            arguments: ["C:\\Games\\StarRail.exe", "argument"])
        let other = InspectedProcess(identity: .init(pid: 3, startTime: 3), executablePath: "/runtime/bin/wine64-preloader",
            arguments: ["helper.exe", "StarRail.exe"])
        let observations = Mutex([[ProcessIdentity]]())
        try await SessionWatcher(inspector: WatchInspector { clock.elapsed < .seconds(3) ? [game, other] : [] },
            runner: WatchRunner(), clock: clock).watch(session: watchSession(), executable: "StarRail.exe") {
                ids in observations.withLock { $0.append(ids) }
            }
        #expect(observations.withLock { $0.first } == [game.identity])
    }
}

private struct WatchInspector: ProcessInspector {
    var scan: @Sendable () throws -> [InspectedProcess]
    init(_ scan: @escaping @Sendable () throws -> [InspectedProcess]) { self.scan = scan }
    func isAlive(_ id: ProcessIdentity) -> Bool { false }
    func processes(environmentContains key: String, value: String) throws -> [InspectedProcess] {
        #expect(key == "WINEPREFIX"); #expect(value == "/prefix")
        return try scan()
    }
}

private final class WatchRunner: ProcessRunner, Sendable {
    let calls = Mutex(0)
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        #expect(executable.path == "/runtime/bin/wineserver")
        #expect(arguments == ["-w"])
        #expect(environment == ["WINEPREFIX": "/prefix", "WINEDEBUG": "-all"])
        calls.withLock { $0 += 1 }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private final class WatchClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant
    private let epoch = ContinuousClock().now
    private let offset = Mutex(Duration.zero)
    var elapsed: Duration { offset.withLock { $0 } }
    var now: Instant { epoch.advanced(by: elapsed) }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        offset.withLock { $0 = max($0, epoch.duration(to: deadline)) }
    }
}

private func watchProcess(_ pid: Int32, _ path: String) -> InspectedProcess {
    .init(identity: .init(pid: pid, startTime: UInt64(pid)), executablePath: path, arguments: [path])
}

private func watchSession(state: LaunchSession.State = .spawning) throws -> LaunchSession {
    LaunchSession(sessionID: UUID(), game: "starrail", installRoot: URL(fileURLWithPath: "/game"),
        installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 2), prefix: URL(fileURLWithPath: "/prefix"),
        bundleID: "bundle", runtimeDigest: try Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)),
        wineBinary: URL(fileURLWithPath: "/runtime/bin/wine"), wineserver: URL(fileURLWithPath: "/runtime/bin/wineserver"),
        componentIDs: [], recipeVersion: 1, settings: .defaults(for: "starrail"), state: state,
        processes: [.init(pid: 1, startTime: 1)])
}

private struct FailedWatchRunner: ProcessRunner {
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("/Users/private".utf8))
    }
}

private final class WaitingWatchRunner: ProcessRunner, Sendable {
    let entered = TestEvent()
    let cancelled = Mutex(false)
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        entered.signal()
        do { try await TestEvent().wait() }
        catch { cancelled.withLock { $0 = true }; throw error }
        throw LauncherError.io("Unexpected wait completion")
    }
}

private final class BlockingStartupWatchRunner: ProcessRunner, Sendable {
    let entered = TestEvent()
    let release = DispatchSemaphore(value: 0)
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        try blockStartup()
        try Task.checkCancellation()
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    private func blockStartup() throws {
        entered.signal()
        guard release.wait(timeout: .now() + 30) == .success else {
            throw LauncherError.io("Wineserver startup test timed out")
        }
    }
}
