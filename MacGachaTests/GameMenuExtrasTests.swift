// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import Testing
import LauncherCore
import GameLibrary
import RuntimeManager
import Launch
@testable import MacGacha

@Suite(.serialized) @MainActor struct GameMenuExtrasTests {
    @Test(arguments: GameDefinition.all.map(\.id)) func screenshotsAreContainedAndRequireAvailableInstallation(id: String) throws {
        let game = GameDefinition.find(id)!
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        let folder = game.family == .starrail ? "StarRail_Data/ScreenShots" : "ScreenShot"
        let root = fixture.paths.root.appendingPathComponent("game")
        let fs = try ContainedFileSystem(root: root)
        #expect(!model.offersScreenshots(for: game.id))
        model.setGameRecord(game.id, fixture.record(game: game, root: root))
        model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        #expect(model.offersScreenshots(for: game.id))
        #expect(model.screenshotsURL(for: game.id) == nil)
        try fs.createDirectory(at: SafeRelativePath(folder))
        #expect(model.screenshotsURL(for: game.id)?.standardizedFileURL == root.appendingPathComponent(folder).standardizedFileURL)
        model.setGameState(game.id, GameState(status: .locationUnavailable(root)))
        #expect(!model.offersScreenshots(for: game.id))
        #expect(model.screenshotsURL(for: game.id) == nil)
        model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        try fs.removeItem(at: SafeRelativePath(folder))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(folder).path, withDestinationPath: fixture.paths.root.path)
        #expect(model.screenshotsURL(for: game.id) == nil)
    }

    @Test func dockFiltersRegionAndUsesFooterReadiness() async throws {
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        await model.start()
        for game in GameDefinition.all {
            model.setGameRecord(game.id, fixture.record(game: game, root: fixture.paths.games))
            model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        }
        model.debugLaunchRuntimesReady = true
        #expect(model.dockGames.map(\.id) == ["genshin", "starrail", "zzz"])
        #expect(model.dockGames.allSatisfy { $0.canPlay })
        model.setGameState("starrail", GameState(status: .updateAvailable(from: "1", to: "2")))
        #expect(model.dockGames.first { $0.id == "starrail" }?.canPlay == false)
        model.launchSlotOwner = "genshin"
        model.launchStates["genshin"] = .running
        model.liveLaunchGames.insert("genshin")
        #expect(model.dockRunningGame?.id == "genshin")
        #expect(model.dockGames.allSatisfy { !$0.canPlay })
        model.region = .mainlandChina
        #expect(model.dockGames.map(\.id) == ["genshin-cn", "starrail-cn", "zzz-cn"])
        #expect(model.dockRunningGame?.id == "genshin")
    }

    @Test func staleDockActionDoesNotLaunchAndDelegateMarksRunningGame() async throws {
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        await model.start()
        let game = GameDefinition.find("genshin")!
        model.setGameRecord(game.id, fixture.record(game: game, root: fixture.paths.games))
        model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        model.debugLaunchRuntimesReady = true
        let delegate = LauncherAppDelegate(); delegate.bind(model)
        let menu = try #require(delegate.applicationDockMenu(NSApplication.shared))
        #expect(menu.items.first?.isEnabled == true)
        model.setLanguageRestart(UUID())
        model.playFromDock("genshin")
        #expect(model.launchSlotOwner == nil)
        model.setLanguageRestart(nil)
        model.launchSlotOwner = game.id; model.liveLaunchGames.insert(game.id); model.launchStates[game.id] = .ready
        let running = try #require(delegate.applicationDockMenu(NSApplication.shared))
        #expect(running.items.contains { $0.state == .on && $0.title == model.dockRunningGame?.name })
    }

    @Test func dockActionEntersSameImmediatePlayReservation() async throws {
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        await model.start()
        let game = GameDefinition.find("genshin")!
        model.setGameRecord(game.id, fixture.record(game: game, root: fixture.paths.games))
        model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        model.debugLaunchRuntimesReady = true
        let delegate = LauncherAppDelegate(); delegate.bind(model)
        let item = try #require(delegate.applicationDockMenu(NSApplication.shared)?.items.first)
        #expect(item.representedObject as? String == "genshin")
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(model.launchSlotOwner == "genshin")
        #expect(model.launchState(for: "genshin") == .starting(.preflight))
        await model.launchTasks["genshin"]?.value
    }

    @Test(arguments: ["game", "recovery", "operation", "runtime", "language", "startup"])
    func blockedResetPreservesPrefix(blocker: String) async throws {
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        if blocker != "startup" { await model.start() }
        let fs = try ContainedFileSystem(root: fixture.paths.root)
        try fs.writeAtomically(Data("keep".utf8), to: SafeRelativePath("Prefixes/genshin-dxmt/keep"))
        let expected: PrefixResetBlocker
        switch blocker {
        case "game": model.launchSlotOwner = "zzz"; expected = .game
        case "recovery": model.launchStates["zzz"] = .recoveryNeeded("pending"); expected = .recovery
        case "operation": model.gameOperation = GameOperationToken(id: "zzz", generation: UUID()); expected = .gameOperation
        case "runtime": model.dependencyAutoUpdateReservation = true; expected = .runtimeWork
        case "language": model.setLanguageRestart(UUID()); expected = .languageRestart
        default: expected = .startup
        }
        #expect(model.prefixResetBlocker(for: "genshin") == expected)
        await #expect(throws: LauncherError.self) { try await model.resetWinePrefix("genshin") }
        #expect(try fs.readFile(at: SafeRelativePath("Prefixes/genshin-dxmt/keep"), maxBytes: 100) == Data("keep".utf8))
    }

    @Test func successfulResetKeepsModelGameRecordAndLaunchSettings() async throws {
        let fixture = try MenuExtrasFixture(), model = fixture.model
        defer { fixture.remove() }
        await model.start()
        let game = GameDefinition.find("starrail")!
        let record = fixture.record(game: game, root: fixture.paths.games)
        model.setGameRecord(game.id, record)
        model.setGameState(game.id, GameState(status: .installed(tag: "1")))
        var settings = model.launchSettings(for: game.id); settings.metalHUD = true
        try model.saveLaunchSettings(settings, for: game.id)
        try await model.flushLaunchSettings()
        let fs = try ContainedFileSystem(root: fixture.paths.root)
        try fs.writeAtomically(Data("registry".utf8), to: SafeRelativePath("Prefixes/starrail-dxmt/system.reg"))
        try await model.resetWinePrefix(game.id)
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/starrail-dxmt")) == nil)
        #expect(model.gameRecord(game.id) == record)
        #expect(model.launchSettings(for: game.id) == settings)
        #expect(model.prefixResetGame == nil)
    }

    @Test func prefixResetReservesAppAcrossSuspensionAndReleasesAfterFailure() async throws {
        let gate = MenuResetGate(), fixture = try MenuExtrasFixture(resetter: gate), model = fixture.model
        defer { fixture.remove() }
        await model.start()
        let operation = Task { try await model.resetWinePrefix("genshin") }
        await gate.entered()
        #expect(model.prefixResetBlocker(for: "zzz") == .resetting)
        #expect(model.isBusyForUpdates)
        #expect(model.languageRestartBlocker != nil)
        #expect(!model.canBeginGameOrRuntimeOperation())
        #expect(!model.canChangeRuntimeCatalog)
        #expect(!model.canRemoveRuntime("wine-1"))
        model.play("zzz")
        #expect(model.launchSlotOwner == nil)
        await gate.release()
        await #expect(throws: LauncherError.self) { try await operation.value }
        #expect(model.prefixResetBlocker(for: "genshin") == nil)
        #expect(!model.isBusyForUpdates)
    }
}

@MainActor private struct MenuExtrasFixture {
    let paths: AppPaths
    let model: AppModel
    init(resetter: (any WinePrefixResetting)? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGacha-Menu-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
        model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil, locale: Locale(identifier: "en_US"), prefixResetter: resetter)
    }
    func record(game: GameDefinition, root: URL) -> GameRecord {
        GameRecord(installPath: root, ownership: .created, executable: try! SafeRelativePath(game.executableName),
            installed: InstalledBuild(tag: "1", buildID: "1", categories: [], voices: []), installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
}

private actor MenuResetGate: WinePrefixResetting {
    private let arrivals = AsyncStream<Void>.makeStream()
    private var resume: CheckedContinuation<Void, Never>?
    func reset(game: String) async throws {
        await withCheckedContinuation { resume = $0; arrivals.continuation.yield(()) }
        throw LauncherError.io("Injected reset failure")
    }
    func entered() async { var iterator = arrivals.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { resume?.resume(); resume = nil }
}
