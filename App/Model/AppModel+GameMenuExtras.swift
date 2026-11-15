// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import GameLibrary
import LauncherCore

/// Confirmation presentation belongs to the settings view. The action rechecks
/// every guard after confirmation and retains its reservation until I/O joins.
enum PrefixResetBlocker: Equatable {
    case unknownGame, startup, game, recovery, gameOperation, runtimeWork, resetting, languageRestart, updating

    var reason: String {
        switch self {
        case .unknownGame: String(localized: "Game is not available.")
        case .startup: String(localized: "Available after MacGacha finishes starting.")
        case .game: String(localized: "Available after the game closes.")
        case .recovery: String(localized: "Available after file recovery finishes.")
        case .gameOperation: String(localized: "Available after the current game operation finishes.")
        case .runtimeWork: String(localized: "Available after the current runtime setup finishes.")
        case .resetting: String(localized: "Available after the Wine prefix reset finishes.")
        case .languageRestart: String(localized: "Available after the language restart finishes.")
        case .updating: String(localized: "Available after the app update finishes.")
        }
    }
}

struct DockGame: Identifiable, Equatable {
    let id: String
    let name: String
    let canPlay: Bool
    var playTitle: String { String(localized: "Play \(name)", comment: "Dock menu action with the localized game name") }
}

@MainActor extension AppModel {
    func offersScreenshots(for id: String) -> Bool {
        GameDefinition.find(id) != nil && gameRecords[id]?.installed != nil && gameRecords[id]?.uninstalling == false && gameLocationURL(for: id) != nil
    }

    /// Metadata-only lookup. Never creates the folder and rejects linked ancestors or leaves.
    func screenshotsURL(for id: String) -> URL? {
        guard offersScreenshots(for: id), let root = gameLocationURL(for: id), let game = GameDefinition.find(id) else { return nil }
        do {
            let fs = try ContainedFileSystem(root: root)
            guard try fs.itemType(at: game.screenshotsPath) == .directory else { return nil }
            return game.screenshotsPath.resolved(against: root)
        } catch { return nil }
    }

    var screenshotsMenuTitle: String { String(localized: "Open Screenshots") }
    var prefixResetTitle: String { String(localized: "Reset Wine Prefix…") }
    var screenshotsHelp: String { String(localized: "Screenshots you take in game appear here") }
    var prefixResetConfirmation: String {
        String(localized: "The Wine prefix will be recreated the next time you play. In-prefix settings, including Star Rail’s saved frame rate, will be reset. Game files, saved logins in the game folder and launcher settings are kept.")
    }

    func prefixResetBlocker(for id: String) -> PrefixResetBlocker? {
        guard GameDefinition.find(id) != nil else { return .unknownGame }
        if prefixResetGame != nil { return .resetting }
        if isStarting { return .startup }
        if languageRestart != nil { return .languageRestart }
        if updater.isInstallingUpdate { return .updating }
        if launchStartupError != nil || !recoveryNotices.isEmpty || launchStates.values.contains(where: { if case .recoveryNeeded = $0 { true } else { false } }) { return .recovery }
        if launchSlotOwner != nil || !liveLaunchGames.isEmpty || !launchTasks.isEmpty { return .game }
        if gameMoveRecoveryReservation || isGameOperationRunning { return .gameOperation }
        if dependencyAutoUpdateReservation || runtimeCatalogMutationID != nil || isRuntimeOperationRunning || consentRequest != nil || importState != nil || !runtimeSetupRosettaChecks.isEmpty ||
            runtimeSetupProgress.values.contains(where: { if case .installing = $0 { true } else { false } }) { return .runtimeWork }
        return nil
    }

    func resetWinePrefix(_ id: String) async throws {
        if let blocker = prefixResetBlocker(for: id) { throw LauncherError.busy(blocker.reason) }
        prefixResetGame = id
        defer { prefixResetGame = nil; scheduleDependencyAutoUpdates() }
        try await prefixResetter.reset(game: id)
    }

    var dockGames: [DockGame] {
        visibleGames.compactMap { game in
            guard gameRecords[game.id]?.installed != nil, gameRecords[game.id]?.uninstalling == false else { return nil }
            return DockGame(id: game.id, name: game.name, canPlay: canPlayFromDock(game.id))
        }
    }

    var dockRunningGame: DockGame? {
        guard let game = LauncherGame.all.first(where: { liveLaunchGames.contains($0.id) && !knownEndedLaunchGames.contains($0.id) && (launchStates[$0.id] == .running || launchStates[$0.id] == .ready) }) else { return nil }
        return DockGame(id: game.id, name: game.name, canPlay: false)
    }

    func canPlayFromDock(_ id: String) -> Bool {
        guard visibleGames.contains(where: { $0.id == id }), let state = games[id], gameRecords[id]?.installed != nil,
            gameRecords[id]?.uninstalling == false, !isStarting, launchStartupError == nil,
            prefixResetGame == nil, !gameMoveRecoveryReservation, languageRestart == nil, !updater.isInstallingUpdate,
            !runtimeCatalogUnavailable, runtimeCatalogMutationID == nil, launchSlotOwner == nil, launchTasks.isEmpty,
            gameOperation?.id != id || gameOperation?.isPreDownload == true else { return false }
        return PrimaryAction.resolve(state, runtimesReady: runtimesReady, launch: launchState(for: id),
            missingComponents: missingComponents(for: id), rosetta: rosetta) == .play
    }

    func playFromDock(_ id: String) {
        guard canPlayFromDock(id) else { return }
        play(id)
    }
}
