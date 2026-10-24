// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import Launch

#if DEBUG
extension AppModel {
    static func debugPreview(defaults: UserDefaults) -> AppModel? {
        let region = initialRegion(defaults: defaults, locale: .current)
        let name = defaults.string(forKey: "MacGachaDebugGameState")
        let notice = defaults.bool(forKey: "MacGachaDebugRecoveryNotice")
        let games = LauncherGame.games(in: region)
        let model: AppModel?
        if let name, let state = debugGameState(name) {
            model = preview(logLines: [], games: Dictionary(uniqueKeysWithValues: games.map { ($0.id, state) }), region: region)
        } else if let name, name.hasPrefix("busy") {
            let requested = name == "busy" ? nil : GameDefinition.find(String(name.dropFirst(5)))
            let busy = GameDefinition.inRegion(region).first { $0.family == (requested?.family ?? .genshin) }!.id
            let downloading = GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.12,
                bytesPerSecond: 215_500_000, downloaded: 18_100_000_000, total: 146_480_000_000))
            model = preview(rows: [], logLines: [], games: Dictionary(uniqueKeysWithValues: games.map {
                ($0.id, $0.id == busy ? downloading : GameState(status: .notInstalled))
            }), region: region)
            model?.gameOperation = GameOperationToken(id: busy, generation: UUID())
        } else { model = debugLaunchPreview(state: name, recoveryNotice: notice, region: region) }
        if notice, let recovery = debugRecoveryNotice(in: region) { model?.recoveryNotices = [recovery] }
        return model
    }

    private static func debugGameState(_ name: String) -> GameState? {
        switch name {
        case "preparing": GameState(status: .notInstalled, activity: .resolving)
        case "progress": GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.42, bytesPerSecond: 47_000_000, downloaded: 57_300_000_000, total: 136_500_000_000))
        case "verifying": GameState(status: .installed(tag: "7.1.0"), activity: .working(.verifying, fraction: nil, bytesPerSecond: nil))
        case "parts": GameState(status: .paused(.install), activity: .needsApproval(required: 150_000_000_000, available: 60_000_000_000))
        case "install": GameState(status: .notInstalled)
        case "resume": GameState(status: .paused(.update))
        case "uninstall": GameState(status: .uninstallPaused)
        case "update": GameState(status: .updateAvailable(from: "7.1.0", to: "7.2.0"))
        case "location": GameState(status: .locationUnavailable(URL(fileURLWithPath: "/Volumes/Games SSD/MacGacha/Genshin Impact")))
        case "installed": GameState(status: .installed(tag: "7.1.0"))
        default: nil
        }
    }

    /// Inert screenshot data: no launch, filesystem mutation or recovery is run.
    static func debugLaunchPreview(state name: String?, recoveryNotice: Bool, region: Region = .global) -> AppModel? {
        let state: LaunchUIState?
        switch name {
        case "playing": state = .running
        case "launching": state = .starting(.prepare)
        case "launchFailed": state = .failed(LaunchFailureInfo(stage: .watch,
            message: String(localized: "The game closed during startup."), hasLog: true, unverifiedBuild: false))
        case "recoveryNeeded": state = .recoveryNeeded(String(localized: "MacGacha is putting the game's files back. You can play when it's done."))
        default: state = nil
        }
        // `ready` is an idle installed game with every runtime present, so the footer shows Play.
        guard state != nil || recoveryNotice || name == "ready" else { return nil }
        let model = AppModel.preview(logLines: [], games: Dictionary(uniqueKeysWithValues:
            LauncherGame.games(in: region).map { ($0.id, GameState(status: .installed(tag: "1.0"))) }), region: region)
        model.debugLaunchRuntimesReady = true
        for game in LauncherGame.games(in: region) {
            model.launchStates[game.id] = state
        }
        let owner = LauncherGame.games(in: region)[1].id
        if ["playing", "launching", "recoveryNeeded"].contains(name) { model.launchSlotOwner = owner }
        if name == "playing" || name == "launching" { model.liveLaunchGames.insert(owner) }
        if recoveryNotice, let notice = debugRecoveryNotice(in: region) { model.recoveryNotices = [notice] }
        return model
    }

    private static func debugRecoveryNotice(in region: Region) -> RecoveryNotice? {
        let game = LauncherGame.games(in: region)[1].id
        let json = """
        {"id":"C2579465-61CA-4445-8C35-F00FF1395516","game":"\(game)",\
        "movedTo":["file:///Volumes/Games/MacGacha/.macgacha-recovery/example/crashreport.exe"]}
        """
        return try? JSONDecoder().decode(RecoveryNotice.self, from: Data(json.utf8))
    }
}
#endif
