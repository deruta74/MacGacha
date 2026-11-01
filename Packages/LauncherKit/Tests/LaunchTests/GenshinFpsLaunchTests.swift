// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct GenshinFpsLaunchTests {
    @Test func injectorWaitsForTheActualGameProcess() async throws {
        let f = try await FpsLaunchFixture.make(initialGame: false), events = ManagerEvents(), manager = f.manager()
        let consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        #expect(f.base.spawner.calls.count == 1 && f.spawner.calls.isEmpty)
        f.base.inspector.update { $0.processes = [f.base.gameProcess]; $0.alive = [f.base.gameProcess.identity] }
        f.base.clock.advance(by: .seconds(1))
        await f.base.clock.waitForSleep(2, duration: .seconds(1))
        #expect(f.spawner.calls.count == 1)
        await manager.markReady(game: f.game.id)
        try await f.end(manager); await consumer.value
    }

    @Test func injectorUsesTheSelectedGameModeMirror() async throws {
        let f = try await FpsLaunchFixture.make(gameMode: true), events = ManagerEvents()
        let helper = FpsMirror(root: f.base.paths.runtimes.appendingPathComponent("GameMode/test/Contents"))
        let manager = f.manager(gameMode: helper), consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        let call = try #require(f.spawner.calls.first)
        #expect(call.executable == helper.root.appendingPathComponent("MacOS/wine-wrapper"))
        #expect(call.environment == f.base.spawner.calls.first?.environment)
        #expect(call.environment["WINESERVER"] == helper.root.appendingPathComponent("bin/wineserver").path)
        try await f.end(manager); await consumer.value
    }
    @Test(arguments: ["genshin", "genshin-cn"], [false, true])
    func spawnedInjectorSharesRouteAndOutputAndIsPinned(game: String, logs: Bool) async throws {
        let f = try await FpsLaunchFixture.make(game: game, logs: logs)
        let manager = f.manager(), events = ManagerEvents(), consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        let call = try #require(f.spawner.calls.first), gameCall = try #require(f.base.spawner.calls.first)
        #expect(call.executable == gameCall.executable && call.environment == gameCall.environment)
        #expect(call.arguments == [WinePath.windowsPath(for: GenshinFps.injectorPath.resolved(against: f.component)), "--target", "120"])
        #expect(call.directory == f.component && call.discarded == !logs)
        let session = try #require(try await f.journal())
        #expect(session.componentIDs.contains(GenshinFps.componentID))
        #expect(session.processes.contains(FpsSpawner.identity))
        #expect(session.processGroupIDs?.contains(FpsSpawner.identity.pid) == true)
        #expect(throws: (any Error).self) { _ = try RuntimeStore.componentLocks(paths: f.base.paths, componentIDs: [GenshinFps.componentID], mode: .exclusive) }
        await manager.markReady(game: game)
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: game)
        #expect(!((await events.values).contains { if case .failed = $0 { true } else { false } }))
        _ = try RuntimeStore.componentLocks(paths: f.base.paths, componentIDs: [GenshinFps.componentID], mode: .exclusive)
    }

    @Test(arguments: [Int32(10), 11, 12, 13]) func earlyFailureReportsNoteAndCodeButGameKeepsRunning(code: Int32) async throws {
        let f = try await FpsLaunchFixture.make(); f.probe.status.withLock { $0 = .exited(code) }
        let manager = f.manager(), events = ManagerEvents(), consumer = await f.consume(manager, events)
        await events.wait { if case .note(.fpsUnlockUnavailable) = $0 { true } else { false } }
        #expect(await manager.liveSession(for: f.game.id) != nil)
        #expect((await events.values).contains { if case .running = $0 { true } else { false } })
        #expect(!((await events.values).contains { if case .failed = $0 { true } else { false } }))
        await manager.markReady(game: f.game.id)
        try await f.end(manager); await consumer.value
        #expect(!((await events.values).contains { if case .failed = $0 { true } else { false } }))
        #expect((await events.values).contains { if case .ended(normal: true) = $0 { true } else { false } })
        await manager.flushLogs()
        let log = try await f.logText()
        #expect(log.contains("FPS unlock unavailable") && log.contains("\"exitCode\":\"\(code)\""))
        #expect(!log.contains(f.component.path))
    }

    @Test(arguments: ["disabled", "unacknowledged", "missingStub", "spawnFailure"])
    func offAndFailuresNeverStartOrStopTheGameIncorrectly(mode: String) async throws {
        let f = try await FpsLaunchFixture.make(enabled: mode != "disabled", acknowledged: mode != "unacknowledged", stub: mode != "missingStub")
        if mode == "spawnFailure" { f.spawner.fails.withLock { $0 = true } }
        let manager = f.manager(), events = ManagerEvents(), consumer = await f.consume(manager, events)
        await events.waitForRunning()
        if mode != "disabled" { await events.wait { if case .note(.fpsUnlockUnavailable) = $0 { true } else { false } } }
        await f.base.clock.waitForSleep(1, duration: .seconds(3))
        #expect(f.spawner.calls.count == (mode == "spawnFailure" ? 1 : 0))
        let session = try #require(try await f.journal())
        #expect(session.componentIDs.contains(GenshinFps.componentID) == !["disabled", "unacknowledged"].contains(mode))
        #expect(f.base.spawner.calls.count == 1)
        try await f.end(manager); await consumer.value
    }

    @Test func exitAfterGameIsGoneDoesNotPostFailure() async throws {
        let f = try await FpsLaunchFixture.make(), events = ManagerEvents(), manager = f.manager()
        let consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        await f.base.clock.waitForSleep(1, duration: .seconds(3))
        f.base.inspector.update { $0.processes = []; $0.alive = [] }
        f.probe.status.withLock { $0 = .exited(11) }
        f.base.clock.advance(by: .seconds(3)); await consumer.value
        #expect(!((await events.values).contains { if case .note(.fpsUnlockUnavailable) = $0 { true } else { false } }))
    }

    @Test func pinsRemainUntilTheOwnedInjectorHasExitedAndBeenReaped() async throws {
        let f = try await FpsLaunchFixture.make(), events = ManagerEvents(), manager = f.manager()
        let consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        await f.base.clock.waitForSleep(1, duration: .seconds(3))
        f.base.inspector.update { $0.processes = []; $0.alive = [] }
        f.base.clock.advance(by: .seconds(3))
        await f.base.clock.waitForSleep(2, duration: .seconds(3))
        #expect(await manager.liveSession(for: f.game.id) != nil)
        #expect(throws: (any Error).self) { _ = try RuntimeStore.componentLocks(paths: f.base.paths, componentIDs: [GenshinFps.componentID], mode: .exclusive) }
        f.probe.status.withLock { $0 = .exited(0) }
        f.base.clock.advance(by: .seconds(3)); await consumer.value
        await manager.waitForSupervision(game: f.game.id)
        _ = try RuntimeStore.componentLocks(paths: f.base.paths, componentIDs: [GenshinFps.componentID], mode: .exclusive)
    }

    @Test func observerCancellationDoesNotCancelInjectionSupervision() async throws {
        let f = try await FpsLaunchFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events)
        await f.base.clock.waitForSleep(1, duration: .seconds(1))
        consumer.cancel(); await consumer.value
        f.probe.status.withLock { $0 = .exited(12) }; f.base.clock.advance(by: .seconds(1))
        await manager.waitForFpsInjector(game: f.game.id)
        await manager.flushLogs()
        #expect(try await f.logText().contains("FPS unlock unavailable"))
        #expect(await manager.liveSession(for: f.game.id) != nil)
        try await f.end(manager); await manager.waitForSupervision(game: f.game.id)
    }

    @Test func reattachmentKeepsPinsAndNeverRunsOrReapsAnInjector() async throws {
        let f = try await FpsLaunchFixture.make()
        try await BlockingIO.run {
            let session = LaunchSession(sessionID: UUID(), game: f.game.id, installRoot: f.base.installRoot,
                installIdentity: try ContainedFileSystem(root: f.base.installRoot).rootIdentity(), prefix: f.base.prefix,
                bundleID: f.base.bundle.id.rawValue, runtimeDigest: f.base.bundle.digest, wineBinary: f.base.bundle.wineBinary,
                wineserver: f.base.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"),
                componentIDs: ["wine-a", GenshinFps.componentID], recipeVersion: 1,
                settings: try LaunchSettingsStore(paths: f.base.paths).load(f.game.id), state: .running,
                processes: [f.base.gameProcess.identity], gameExecutable: try SafeRelativePath("StarRail.exe"))
            try LaunchJournal(paths: f.base.paths).write(session)
        }
        let manager = f.manager()
        #expect(await manager.reattachAll().count == 1)
        await f.base.clock.waitForSleep(1, duration: .seconds(3))
        #expect(f.spawner.calls.isEmpty && f.probe.polls.withLock { $0 } == 0)
        #expect(throws: (any Error).self) { _ = try RuntimeStore.componentLocks(paths: f.base.paths, componentIDs: [GenshinFps.componentID], mode: .exclusive) }
        try await f.end(manager); await manager.waitForSupervision(game: f.game.id)
    }
}

private final class FpsProbe: Sendable {
    let status = Mutex(SessionChildStatus.running)
    let polls = Mutex(0)
    func poll(_ identity: ProcessIdentity) -> SessionChildStatus {
        #expect(identity == FpsSpawner.identity)
        polls.withLock { $0 += 1 }
        return status.withLock { $0 }
    }
}
private final class FpsSpawner: ProcessSpawner, Sendable {
    static let identity = ProcessIdentity(pid: 34568, startTime: 300)
    struct Call: Sendable { let executable: URL; let arguments: [String]; let environment: [String: String]; let directory: URL; let discarded: Bool }
    let base: ManagerSpawner
    let fails = Mutex(false)
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }
    init(_ base: ManagerSpawner) { self.base = base }
    func spawn(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL, output: ProcessOutput) throws -> ProcessIdentity {
        guard arguments.first?.hasSuffix("\\fpsinject.exe") == true else {
            return try base.spawn(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, output: output)
        }
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments, environment: environment, directory: currentDirectory,
            discarded: { if case .discard = output { true } else { false } }())) }
        if fails.withLock({ $0 }) { throw LauncherError.io("Synthetic private spawn path") }
        return Self.identity
    }
}
private struct FpsLaunchFixture: Sendable {
    let base: ManagerFixture, game: GameDefinition, component: URL, spawner: FpsSpawner
    let probe = FpsProbe()
    static func make(game: String = "genshin", logs: Bool = false, enabled: Bool = true, acknowledged: Bool = true, stub: Bool = true,
        initialGame: Bool = true, gameMode: Bool = false) async throws -> Self {
        let base = try await ManagerFixture.make(logsEnabled: logs, initialGame: initialGame)
        let root = base.paths.runtimes.appendingPathComponent("genshinFps/1")
        try await BlockingIO.run {
            var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = enabled; settings.compatibilityPatches = false
            try LaunchSettingsStore(paths: base.paths).save(settings, for: game)
            try GlobalLaunchSettingsStore(paths: base.paths).save(GlobalLaunchSettings(sessionLogsEnabled: logs,
                gameModeEnabled: gameMode, genshinFpsRiskAcknowledged: acknowledged))
            let fs = try ContainedFileSystem(root: root); try fs.createRootDurably()
            try fs.writeAtomically(Data("fake injector".utf8), to: GenshinFps.injectorPath)
            if stub { try fs.writeAtomically(Data("fake stub".utf8), to: GenshinFps.stubPath) }
        }
        return Self(base: base, game: GameDefinition.find(game)!, component: root, spawner: FpsSpawner(base.spawner))
    }
    func manager(gameMode: (any GameModeProviding)? = nil) -> LaunchManager {
        let recipe = LaunchRecipe(game: game.id, recipeVersion: 1, verifiedBuilds: [], executable: try! SafeRelativePath("StarRail.exe"),
            wrapper: .none, blockedHosts: [], hidden: [], copyIfPresent: [], timeoutFix: false, supportsDirectX12: false)
        return LaunchManager(paths: base.paths, runtimes: ManagerRuntimeProvider(selected: LaunchRuntimeSelection(bundle: base.bundle,
            componentIDs: ["wine-a"], componentRoots: [.genshinFps: component], compatibilityComponentIDs: [.genshinFps: GenshinFps.componentID])),
            prefixes: base.prefixes, preparation: base.preparation, spawner: spawner, inspector: base.inspector,
            runner: base.runner, clock: base.clock, gameMode: gameMode, proxyFactory: { [proxy = base.proxy] _, log in proxy.start(log: log); return proxy },
            recipeOverrides: [game.id: recipe], sessionProvenance: { (ManagerFixture.bootSessionUUID, ManagerFixture.sessionStartTime) },
            fpsInjectorStatus: { [probe] in probe.poll($0) })
    }
    func consume(_ manager: LaunchManager, _ events: ManagerEvents) async -> Task<Void, Never> {
        let stream = await manager.launch(game: game, installRoot: base.installRoot, gameBuild: "test")
        return Task { for await event in stream { await events.append(event) } }
    }
    func journal() async throws -> LaunchSession? { try await BlockingIO.run { try LaunchJournal(paths: base.paths).read(game: game.id) } }
    func end(_ manager: LaunchManager) async throws { probe.status.withLock { $0 = .exited(0) }; try await base.end(manager) }
    func logText() async throws -> String {
        try await BlockingIO.run { try String(decoding: ContainedFileSystem(root: base.paths.root).readFile(at: SafeRelativePath("Logs/macgacha.log"), maxBytes: 1 << 20), as: UTF8.self) }
    }
}

private struct FpsMirror: GameModeProviding {
    let root: URL
    func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String], options: GameModeOptions) async throws -> GameModeRuntime {
        GameModeRuntime(game: game, root: root, wineBinary: root.appendingPathComponent("MacOS/wine-wrapper"), wineserver: root.appendingPathComponent("bin/wineserver"))
    }
    func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws {}
}
