// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

private final class FakeGameMode: GameModeProviding, Sendable {
    let helper: GameModeRuntime
    let prepareFails: Bool
    let validationFails: Bool
    let calls = Mutex((prepare: 0, validate: 0, game: Optional<String>.none))
    init(paths: AppPaths, prepareFails: Bool = false, validationFails: Bool = false) {
        let root = paths.runtimes.appendingPathComponent("GameMode/bundle-a/starrail/Honkai: Star Rail.app/Contents")
        helper = GameModeRuntime(game: GameDefinition.find("starrail")!, root: root, wineBinary: root.appendingPathComponent("MacOS/wine-wrapper"), wineserver: root.appendingPathComponent("bin/wineserver"))
        self.prepareFails = prepareFails; self.validationFails = validationFails
    }
    func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String]) async throws -> GameModeRuntime {
        calls.withLock { $0.prepare += 1; $0.game = game.id }
        if prepareFails { throw LauncherError.io("Synthetic private path must not reach logs") }
        return helper
    }
    func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws {
        calls.withLock { $0.validate += 1 }
        if validationFails { throw LauncherError.io("Synthetic private path must not reach logs") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct GameModeLaunchTests {
    @Test(arguments: ["enabled", "disabled", "prepareFailure", "validationFailure"])
    func launchUsesVerifiedMirrorOrFallsBack(mode: String) async throws {
        let f = try await ManagerFixture.make()
        let provider = FakeGameMode(paths: f.paths, prepareFails: mode == "prepareFailure", validationFails: mode == "validationFailure")
        if mode == "disabled" {
            try await BlockingIO.run {
                try GlobalLaunchSettingsStore(paths: f.paths).save(GlobalLaunchSettings(gameModeEnabled: false))
            }
        }
        let log = EventLog(directory: f.paths.logs)
        let manager = f.manager(log: log, gameMode: provider), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        let enabled = mode == "enabled", call = try #require(f.spawner.calls.first)
        #expect(call.executable == (enabled ? provider.helper.wineBinary : f.bundle.wineBinary))
        #expect(call.environment["WINELOADER"] == (enabled ? provider.helper.loader.path : nil))
        #expect(call.environment["WINESERVER"] == (enabled ? provider.helper.wineserver.path : nil))
        let snapshot = try #require(try await f.journal())
        #expect(snapshot.wineBinary == call.executable)
        #expect(snapshot.wineserver == (enabled ? provider.helper.wineserver : f.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver")))
        #expect(provider.calls.withLock { $0.prepare } == (mode == "disabled" ? 0 : 1))
        #expect(provider.calls.withLock { $0.game } == (mode == "disabled" ? nil : f.game.id))
        #expect(provider.calls.withLock { $0.validate } == (["enabled", "validationFailure"].contains(mode) ? 1 : 0))
        #expect(f.inspector.values.scopes.allSatisfy { $0.executableRoots.contains(f.paths.runtimes) })
        try await f.end(manager); await consumer.value
        try await f.assertOriginalRestored()
        await log.log(.debug, "test", "Barrier")
        let text = try await BlockingIO.run {
            String(decoding: try ContainedFileSystem(root: f.paths.root).readFile(at: SafeRelativePath("Logs/macgacha.log"), maxBytes: 1 << 20), as: UTF8.self)
        }
        #expect(!text.contains("Synthetic private path"))
        #expect(!text.contains(provider.helper.root.path))
        let reason = ["disabled": "disabled", "prepareFailure": "helperPreparationFailed", "validationFailure": "helperValidationFailed"]
        if let reason = reason[mode] { #expect(text.contains(reason)) }
        else { #expect(text.contains("Game Mode helper selected")) }
    }

    @Test(arguments: [false, true]) func reattachmentUsesPersistedMirrorWithoutPreparingAgain(legacy: Bool) async throws {
        let f = try await ManagerFixture.make(), provider = FakeGameMode(paths: f.paths)
        let oldRoot = f.paths.runtimes.appendingPathComponent("GameMode/bundle-a/MacGacha Game.app/Contents/MacOS")
        let recordedWine = legacy ? oldRoot.appendingPathComponent("wine") : provider.helper.wineBinary
        let recordedServer = legacy ? oldRoot.appendingPathComponent("wineserver") : provider.helper.wineserver
        _ = try await f.saveSnapshot(state: .running, processes: [f.gameProcess.identity])
        try await BlockingIO.run {
            let journal = LaunchJournal(paths: f.paths), original = try #require(try journal.read(game: "starrail"))
            let mirrored = LaunchSession(sessionID: original.sessionID, game: original.game, installRoot: original.installRoot,
                installIdentity: original.installIdentity, prefix: original.prefix, bundleID: original.bundleID,
                runtimeDigest: original.runtimeDigest, wineBinary: recordedWine, wineserver: recordedServer,
                componentIDs: original.componentIDs, recipeVersion: original.recipeVersion, settings: original.settings,
                state: original.state, processes: original.processes, hides: original.hides, gameExecutable: original.gameExecutable)
            try journal.write(mirrored)
        }
        let manager = f.manager(gameMode: provider)
        #expect(await manager.reattachAll().count == 1)
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(provider.calls.withLock { $0.prepare + $0.validate } == 0)
        #expect(f.inspector.values.scopes.allSatisfy { $0.executableRoots.contains(f.paths.runtimes) })
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }
}
