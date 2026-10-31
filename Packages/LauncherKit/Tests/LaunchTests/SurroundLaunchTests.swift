// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import Launch

private final class SurroundHelper: GameModeProviding, Sendable {
    let paths: AppPaths
    let failure: String
    let requests = Mutex<[GameModeOptions]>([])
    init(paths: AppPaths, failure: String) { self.paths = paths; self.failure = failure }
    func prepare(bundle: InstalledRuntimeBundle, game: GameDefinition, componentIDs: [String], options: GameModeOptions) async throws -> GameModeRuntime {
        requests.withLock { $0.append(options) }
        if failure == "prepare" { throw LauncherError.io("Synthetic private helper path") }
        let root = paths.runtimes.appendingPathComponent("GameMode/audio/genshin/genshin.app/Contents")
        return GameModeRuntime(game: game, root: root, wineBinary: root.appendingPathComponent("MacOS/wine-wrapper"),
            wineserver: root.appendingPathComponent("bin/wineserver"), gameModeEnabled: options.gameModeEnabled,
            surroundModule: failure == "overlay" ? nil : options.surroundModule)
    }
    func validate(_ helper: GameModeRuntime, bundle: InstalledRuntimeBundle) async throws {
        if failure == "validate" { throw LauncherError.io("Synthetic private validation path") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct SurroundLaunchTests {
    @Test func reattachmentKeepsCapturedAudioHelperAndRebuildsPins() async throws {
        let f = try await ManagerFixture.make(), game = GameDefinition.find("genshin")!
        let helper = f.paths.runtimes.appendingPathComponent("GameMode/audio/genshin/genshin.app/Contents")
        try await BlockingIO.run {
            var settings = LaunchSettings.defaults(for: game.id); settings.surroundSound = true
            let session = LaunchSession(sessionID: UUID(), game: game.id, installRoot: f.installRoot,
                installIdentity: try ContainedFileSystem(root: f.installRoot).rootIdentity(), prefix: f.prefix,
                bundleID: SurroundAudio.bundleID, runtimeDigest: f.bundle.digest, wineBinary: helper.appendingPathComponent("MacOS/wine-wrapper"),
                wineserver: helper.appendingPathComponent("bin/wineserver"), componentIDs: ["wine-a", SurroundAudio.componentID],
                recipeVersion: 1, settings: settings, state: .running, processes: [f.gameProcess.identity], gameExecutable: try SafeRelativePath("StarRail.exe"),
                bootSessionUUID: ManagerFixture.bootSessionUUID, sessionStartTime: ManagerFixture.sessionStartTime)
            try LaunchJournal(paths: f.paths).write(session)
            try LaunchSettingsStore(paths: f.paths).save(.defaults(for: game.id), for: game.id)
            try GlobalLaunchSettingsStore(paths: f.paths).save(GlobalLaunchSettings(gameModeEnabled: false))
        }
        let provider = SurroundHelper(paths: f.paths, failure: "prepare"), manager = f.manager(gameMode: provider)
        #expect(await manager.reattachAll().count == 1)
        #expect(provider.requests.withLock { $0.isEmpty })
        #expect(throws: (any Error).self) { _ = try RuntimeStore.componentLocks(paths: f.paths, componentIDs: [SurroundAudio.componentID], mode: .exclusive) }
        let journal = try #require(try await BlockingIO.run { try LaunchJournal(paths: f.paths).read(game: game.id) })
        #expect(journal.wineBinary == helper.appendingPathComponent("MacOS/wine-wrapper"))
        #expect(journal.settings.surroundSound)
        try await f.end(manager)
        await manager.waitForSupervision(game: game.id)
        _ = try RuntimeStore.componentLocks(paths: f.paths, componentIDs: [SurroundAudio.componentID], mode: .exclusive)
    }

    @Test(arguments: [false, true], ["none", "prepare", "validate", "overlay", "missingComponent"])
    func managerUsesAudioHelperOrReportsOneFallback(gameMode: Bool, failure: String) async throws {
        let f = try await ManagerFixture.make(), game = GameDefinition.find("genshin")!
        var settings = LaunchSettings.defaults(for: game.id); settings.compatibilityPatches = false; settings.surroundSound = true
        let saved = settings
        try await BlockingIO.run {
            try LaunchSettingsStore(paths: f.paths).save(saved, for: game.id)
            try GlobalLaunchSettingsStore(paths: f.paths).save(GlobalLaunchSettings(gameModeEnabled: gameMode))
        }
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(SurroundAudio.bundleID), root: f.bundle.root,
            wineBinary: f.bundle.wineBinary, digest: f.bundle.digest, source: .download)
        let component = f.paths.runtimes.appendingPathComponent("surroundAudio/wine-11.20-1")
        let runtime = ManagerRuntimeProvider(selected: LaunchRuntimeSelection(bundle: bundle, componentIDs: ["wine-a"],
            componentRoots: failure == "missingComponent" ? [:] : [.surroundAudio: component],
            compatibilityComponentIDs: failure == "missingComponent" ? [:] : [.surroundAudio: SurroundAudio.componentID]))
        let recipe = LaunchRecipe(game: game.id, recipeVersion: 1, verifiedBuilds: [], executable: try SafeRelativePath("StarRail.exe"),
            wrapper: .none, blockedHosts: [], hidden: [], copyIfPresent: [], timeoutFix: false, supportsDirectX12: false)
        let provider = SurroundHelper(paths: f.paths, failure: failure), log = EventLog(directory: f.paths.logs)
        let manager = LaunchManager(paths: f.paths, runtimes: runtime, prefixes: f.prefixes, preparation: f.preparation, spawner: f.spawner,
            inspector: f.inspector, runner: f.runner, clock: f.clock, log: log, gameMode: provider,
            proxyFactory: { [proxy = f.proxy] _, action in proxy.start(log: action); return proxy }, recipeOverrides: [game.id: recipe],
            sessionProvenance: { (ManagerFixture.bootSessionUUID, ManagerFixture.sessionStartTime) })
        let stream = await manager.launch(game: game, installRoot: f.installRoot, gameBuild: "probe"), events = ManagerEvents()
        let consumer = Task { for await event in stream { await events.append(event) } }
        await events.wait { if case .running = $0 { return true }; if case .failed = $0 { return true }; return false }
        if failure == "missingComponent" {
            #expect(f.spawner.calls.isEmpty)
            #expect(provider.requests.withLock { $0.isEmpty })
            await consumer.value
            return
        }
        let active = failure == "none", spawn = try #require(f.spawner.calls.first)
        #expect(spawn.environment["MACGACHA_SURROUND"] == (active ? "1" : nil))
        #expect(provider.requests.withLock { $0.first?.gameModeEnabled } == gameMode)
        let snapshot = try #require(try await BlockingIO.run { try LaunchJournal(paths: f.paths).read(game: game.id) })
        #expect(snapshot.componentIDs.contains(SurroundAudio.componentID))
        #expect(snapshot.wineBinary == spawn.executable)
        #expect(snapshot.settings.surroundSound)
        let notes = await events.values.filter { if case .note(.surroundUnavailable) = $0 { return true }; return false }
        #expect(notes.count == (active ? 0 : 1))
        #expect(throws: (any Error).self) { _ = try RuntimeStore.componentLocks(paths: f.paths, componentIDs: [SurroundAudio.componentID], mode: .exclusive) }
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: game.id)
        _ = try RuntimeStore.componentLocks(paths: f.paths, componentIDs: [SurroundAudio.componentID], mode: .exclusive)
        await manager.flushLogs()
        let text = try String(decoding: ContainedFileSystem(root: f.paths.root).readFile(at: SafeRelativePath("Logs/macgacha.log"), maxBytes: 1 << 20), as: UTF8.self)
        #expect(!text.contains("Synthetic private"))
        if !active { #expect(text.contains("Surround audio skipped")) }
    }
}
