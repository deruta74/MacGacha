// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import GameLibrary
import AppKit
import Launch
import LauncherCore
import SwiftUI

@main
struct MacGachaApp: App {
    @State private var model = Self.makeModel()
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate

    private static func makeModel() -> AppModel {
        #if DEBUG
        if let model = AppModel.debugLaunchPreview(
            state: UserDefaults.standard.string(forKey: "MacGachaDebugGameState"),
            recoveryNotice: UserDefaults.standard.bool(forKey: "MacGachaDebugRecoveryNotice")) {
            return model
        }
        // `-MacGachaDebugGameState progress` shows every game in one fixed state, for screenshots.
        if let name = UserDefaults.standard.string(forKey: "MacGachaDebugGameState"), let state = debugGameState(name) {
            return AppModel.preview(logLines: [], games: Dictionary(uniqueKeysWithValues: LauncherGame.all.map { ($0.id, state) }))
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
                .task {
                    delegate.bind(model)
                    await model.start()
                }
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

/// Confirmation presentation belongs to the app's view layer. Scheduling it
/// after returning terminateLater also supports a synchronous default hook.
@MainActor final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    var retryRecoveries: () -> Void = {}
    var liveGameName: () -> String? = { nil }
    var requestConfirmation: (String, @escaping @MainActor (NSApplication.TerminateReply) -> Void) -> Void = {
        _, completion in completion(.terminateNow)
    }
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func bind(_ model: AppModel) {
        retryRecoveries = { [weak model] in model?.retryRecoveriesOnActivation() }
        liveGameName = { [weak model] in model?.liveSessionGameName }
        requestConfirmation = { [weak model] game, completion in
            guard let model else { completion(.terminateNow); return }
            model.confirmQuit(gameName: game, completion: completion)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { retryRecoveries() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let game = liveGameName() else { return .terminateNow }
        Task { @MainActor [weak self] in
            self?.requestConfirmation(game) { [weak self] reply in
                self?.replyToTermination(reply == .terminateNow)
            }
        }
        return .terminateLater
    }
}

extension AppModel {
    /// Install quitConfirmation from the view layer to present Quit / Cancel.
    /// Until that presentation lands, the default permits the requested quit.
    func confirmQuit(gameName: String, completion: @escaping @MainActor (NSApplication.TerminateReply) -> Void) {
        if let quitConfirmation { quitConfirmation(gameName, completion) }
        else { completion(.terminateNow) }
    }
}

#if DEBUG
extension AppModel {
    /// Inert screenshot data: no launch, filesystem mutation or recovery is run.
    static func debugLaunchPreview(state name: String?, recoveryNotice: Bool) -> AppModel? {
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
            LauncherGame.all.map { ($0.id, GameState(status: .installed(tag: "1.0"))) }))
        model.debugLaunchRuntimesReady = true
        for game in LauncherGame.all {
            model.launchStates[game.id] = state
        }
        if ["playing", "launching", "recoveryNeeded"].contains(name) { model.launchSlotOwner = "starrail" }
        if name == "playing" || name == "launching" { model.liveLaunchGames.insert("starrail") }
        if recoveryNotice {
            let json = """
            {"id":"C2579465-61CA-4445-8C35-F00FF1395516","game":"starrail",\
            "movedTo":["file:///Volumes/Games/MacGacha/.macgacha-recovery/example/crashreport.exe"]}
            """
            if let notice = try? JSONDecoder().decode(RecoveryNotice.self, from: Data(json.utf8)) {
                model.recoveryNotices = [notice]
            }
        }
        return model
    }
}
#endif
