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
        if let model = AppModel.debugPreview(defaults: .standard) { return model }
        #endif
        return AppModel.forCurrentProcess()
    }

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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
                    .disabled(!model.canCheckForUpdates)
            }
        }

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
