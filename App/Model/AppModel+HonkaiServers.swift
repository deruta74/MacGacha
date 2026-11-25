// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import HoYoPlayAPI
import LauncherCore

struct HonkaiServerState: Identifiable, Equatable {
    let server: HonkaiImpactServer
    let description: String
    let isInstalled: Bool
    let launch: LaunchUIState?
    let activity: GameActivity?
    let isOperating: Bool

    var id: String { server.rawValue }
    var isRunning: Bool { launch == .running || launch == .ready }
}

@MainActor extension AppModel {
    static let honkaiServerKey = "selectedHonkaiServer"

    var honkaiServers: [HonkaiServerState] {
        HonkaiImpactServer.allCases.map { server in
            let id = server.rawValue
            return HonkaiServerState(server: server, description: honkaiServerDescription(server),
                isInstalled: isHonkaiServerInstalled(server), launch: launchState(for: id),
                activity: games[id]?.activity, isOperating: gameOperation?.id == id)
        }
    }

    var selectedHonkaiServer: HonkaiImpactServer {
        if let honkaiServerPreference { return honkaiServerPreference }
        let installed = HonkaiImpactServer.allCases.filter(isHonkaiServerInstalled)
        return installed.count == 1 ? installed[0] : .europeAmericas
    }

    func selectHonkaiServer(_ server: HonkaiImpactServer) {
        rememberHonkaiServer(for: server.rawValue)
        if let selected = defaults?.string(forKey: Self.selectedGameKey), HonkaiImpactServer(rawValue: selected) != nil {
            defaults?.set(server.rawValue, forKey: Self.selectedGameKey)
        }
    }

    func rememberHonkaiServer(for id: String) {
        guard let server = HonkaiImpactServer(rawValue: id) else { return }
        honkaiServerPreference = server
        defaults?.set(id, forKey: Self.honkaiServerKey)
    }

    var launcherCards: [LauncherGame] { LauncherGame.cards(in: region, honkaiServer: selectedHonkaiServer) }

    func launcherGame(for id: String) -> LauncherGame {
        let visibleID = region == .global && HonkaiImpactServer(rawValue: id) != nil ? selectedHonkaiServer.rawValue : id
        return launcherCards.first { $0.id == visibleID } ?? visibleGames[0]
    }

    func editionDisplayName(_ game: LauncherGame) -> String {
        guard let server = HonkaiImpactServer(rawValue: game.id) else { return game.name }
        return String(localized: "\(game.name) (\(honkaiServerDescription(server)))",
            comment: "Game title followed by its HoYoPlay server description")
    }

    func launcherArt(for id: String) -> GameArt? {
        let own = gameArt[id]
        guard let server = HonkaiImpactServer(rawValue: id), server != .europeAmericas,
            let base = gameArt[HonkaiImpactServer.europeAmericas.rawValue] else { return own }
        guard let own else { return base }
        let hasBackdrop = own.background != nil || own.backgrounds.contains { $0.image != nil }
        return GameArt(background: hasBackdrop ? own.background : base.background,
            video: hasBackdrop ? own.video : base.video, theme: hasBackdrop ? own.theme : base.theme,
            icon: own.icon ?? base.icon, logo: own.logo ?? base.logo,
            backgrounds: hasBackdrop ? own.backgrounds : base.backgrounds)
    }

    func launcherEvents(for id: String) -> [GameEvent] {
        if let own = gameEvents[id] { return own }
        return HonkaiImpactServer(rawValue: id) == nil ? [] : gameEvents[HonkaiImpactServer.europeAmericas.rawValue] ?? []
    }

    private func honkaiServerDescription(_ server: HonkaiImpactServer) -> String {
        honkaiServerDescriptions[server.rawValue] ?? server.englishDescription
    }

    private func isHonkaiServerInstalled(_ server: HonkaiImpactServer) -> Bool {
        gameRecords[server.rawValue]?.installed != nil && gameRecords[server.rawValue]?.uninstalling == false
    }
}
