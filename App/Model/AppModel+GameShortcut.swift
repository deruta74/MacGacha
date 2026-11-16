// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

@MainActor extension AppModel {
    func canCreateShortcut(_ id: String) -> Bool {
        gameRecords[id]?.installed != nil && gameRecords[id]?.uninstalling == false
    }

    /// Writes the game's shortcut app into ~/Applications and returns its location.
    func createShortcut(_ id: String) async throws -> URL {
        guard canCreateShortcut(id), let game = LauncherGame.all.first(where: { $0.id == id }) else {
            throw LauncherError.busy("Shortcut unavailable")
        }
        let url = try await shortcutWriter.write(gameID: id, name: game.name)
        EventLog(directory: paths.logs).post(.info, "shortcut", "Game shortcut created", metadata: ["game": id])
        return url
    }

    /// Handles `macgacha://play/<id>` from a shortcut. Unknown URLs are ignored.
    func openShortcutURL(_ url: URL) {
        guard let id = GameShortcut.gameID(from: url) else { return }
        shortcutTask?.cancel()
        shortcutTask = Task { [weak self] in await self?.playFromShortcut(id) }
    }

    /// Plays through the same checks as the footer. Anything that needs the user (an update,
    /// setup, a missing drive, recovery) opens the launcher on that game instead.
    func playFromShortcut(_ id: String) async {
        await waitForStartup()
        guard !Task.isCancelled, let game = GameDefinition.find(id) else { return }
        // Already playing: the shortcut has nothing to add.
        if liveLaunchGames.contains(id) { return }
        if region != game.region {
            region = game.region
            await refreshGames(in: game.region)
            guard !Task.isCancelled else { return }
        }
        // Startup's refresh returns early while another one (the window's, for example) is
        // still reading records. Decide only once the game's region has its records.
        for _ in 0..<600 where gameRefreshInFlight.contains(game.region) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard canPlayFromDock(id) else { shortcutEvent(id, "Shortcut opened the launcher", hidden: launchedHidden); revealLauncher(selecting: id); return }
        play(id)
        // Play claims the launch slot synchronously. If it refused, show why.
        guard liveLaunchGames.contains(id) else { shortcutEvent(id, "Shortcut launch refused", hidden: launchedHidden); revealLauncher(selecting: id); return }
        shortcutEvent(id, "Shortcut started the game", hidden: launchedHidden)
        if launchedHidden { watchShortcutSession(id, sawGame: true) }
    }

    private func shortcutEvent(_ id: String, _ message: String, hidden: Bool) {
        EventLog(directory: paths.logs).post(.info, "shortcut", message, metadata: ["game": id, "hidden": hidden ? "yes" : "no"])
    }

    /// Shows the launcher on a game, for example when a shortcut can't start it directly.
    func revealLauncher(selecting id: String?) {
        launchedHidden = false
        if let id { notificationSelection = GameNotificationSelection(gameID: id) }
        notificationReveal()
    }

    /// While the launcher is still hidden: a failure opens it, and the end of the game quits
    /// MacGacha once nothing else is running. Showing the window ends this watch.
    private func watchShortcutSession(_ id: String, sawGame: Bool) {
        withObservationTracking {
            _ = launchedHidden; _ = launchStates[id]; _ = liveLaunchGames; _ = lastError; _ = isBusyForUpdates
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.shortcutSessionChanged(id, sawGame: sawGame) }
        }
    }

    private func shortcutSessionChanged(_ id: String, sawGame: Bool) {
        guard launchedHidden else { return }
        switch launchStates[id] {
        case .failed?, .recoveryNeeded?: revealLauncher(selecting: id); return
        default: break
        }
        if lastError != nil { revealLauncher(selecting: id); return }
        // The session ended normally and nothing else holds MacGacha.
        if sawGame, !liveLaunchGames.contains(id), launchStates[id] == nil, !isBusyForUpdates {
            terminateAfterShortcut()
            return
        }
        watchShortcutSession(id, sawGame: sawGame)
    }
}
