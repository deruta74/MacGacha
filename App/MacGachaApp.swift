// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import GameLibrary
import SwiftUI

@main
struct MacGachaApp: App {
    @State private var model = Self.makeModel()

    private static func makeModel() -> AppModel {
        #if DEBUG
        // `-MacGachaDebugGameState progress` shows every game in one fixed state, for screenshots.
        if let name = UserDefaults.standard.string(forKey: "MacGachaDebugGameState"), let state = debugGameState(name) {
            return AppModel.preview(rows: [], logLines: [], games: Dictionary(uniqueKeysWithValues: LauncherGame.all.map { ($0.id, state) }))
        }
        // `-MacGachaDebugGameState busy` (or `busy-<game>`): one game downloads at full speed while the others wait.
        if let name = UserDefaults.standard.string(forKey: "MacGachaDebugGameState"), name.hasPrefix("busy") {
            let busy = name == "busy" ? "genshin" : String(name.dropFirst(5))
            let downloading = GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.12, bytesPerSecond: 215_500_000,
                downloaded: 18_100_000_000, total: 146_480_000_000))
            let model = AppModel.preview(rows: [], logLines: [], games: Dictionary(uniqueKeysWithValues: LauncherGame.all.map {
                ($0.id, $0.id == busy ? downloading : GameState(status: .notInstalled))
            }))
            model.gameOperation = GameOperationToken(id: busy, generation: UUID())
            return model
        }
        #endif
        return AppModel.forCurrentProcess()
    }

    #if DEBUG
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
    #endif

    var body: some Scene {
        Window("MacGacha", id: "launcher") {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
