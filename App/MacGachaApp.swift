// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import GameLibrary
import AppKit
import Launch
import LauncherCore
import Observation
import SwiftUI

@main
struct MacGachaApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate

    init() {
        let model = Self.makeModel()
        _model = State(initialValue: model)
        // A shortcut launch opens a URL, and SwiftUI creates no window for that,
        // so the delegate needs the model to start without one.
        LauncherAppDelegate.launchModel = model
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        if let model = AppModel.debugPreview(defaults: .standard) { return model }
        #endif
        return AppModel.forCurrentProcess()
    }

    var body: some Scene {
        Window("MacGacha", id: "launcher") {
            LauncherWindowContent()
                .environment(model)
                // Startup belongs to the window, not to the launcher view the loading screen replaces.
                .task {
                    delegate.bind(model)
                    await model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        // A shortcut session ends with the window hidden. Restoring that state would
        // leave the next ordinary launch without a window.
        .restorationBehavior(.disabled)
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
    weak var dockModel: AppModel?
    var retryRecoveries: () -> Void = {}
    var liveGameName: () -> String? = { nil }
    var catalogPublication: () -> Task<Void, Never>? = { nil }
    var requestConfirmation: (String, @escaping @MainActor (NSApplication.TerminateReply) -> Void) -> Void = {
        _, completion in completion(.terminateNow)
    }
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// Shortcut URLs that arrived before the model was bound.
    private var pendingURLs: [URL] = []
    private var isWaitingForWindowlessQueue = false
    static var launchModel: AppModel?

    func bind(_ model: AppModel) {
        dockModel = model
        let urls = pendingURLs; pendingURLs = []
        for url in urls { model.openShortcutURL(url) }
        retryRecoveries = { [weak model] in model?.retryRecoveriesOnActivation() }
        liveGameName = { [weak model] in model?.liveSessionGameName }
        catalogPublication = { [weak model] in model?.catalogMutationTask }
        requestConfirmation = { [weak model] game, completion in
            guard let model else { completion(.terminateNow); return }
            model.confirmQuit(gameName: game, completion: completion)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { retryRecoveries() }

    /// The SwiftUI lifecycle doesn't forward URL events to `application(_:open:)`, and its own
    /// handling would bring the launcher window forward. Shortcut URLs come straight here.
    /// A shortcut launch has no window to run startup, so it starts here.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.launchModel, model.launchedHidden, dockModel == nil else { return }
        bind(model)
        Task { await model.start() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: text) else { return }
        guard let model = dockModel else { pendingURLs.append(url); return }
        model.openShortcutURL(url)
    }

    /// Scheduled work survives closing the window. Explicit Quit still terminates the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if let dockModel, dockModel.keepsUpdateQueueRunning {
            isWaitingForWindowlessQueue = true
            watchWindowlessQueue(dockModel)
            return false
        }
        return !(dockModel?.launchedHidden ?? CommandLine.arguments.contains(GameShortcut.launchArgument))
    }

    private func watchWindowlessQueue(_ model: AppModel) {
        withObservationTracking {
            _ = model.keepsUpdateQueueRunning
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model, self.isWaitingForWindowlessQueue else { return }
                if model.keepsUpdateQueueRunning {
                    self.watchWindowlessQueue(model)
                } else {
                    self.isWaitingForWindowlessQueue = false
                    if !model.launchedHidden, !NSApp.windows.contains(where: \.isVisible) { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// A Dock click while a shortcut kept the launcher hidden shows it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        isWaitingForWindowlessQueue = false
        guard let model = dockModel, model.launchedHidden else { return true }
        model.revealLauncher(selecting: nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let publication = catalogPublication() {
            Task { @MainActor [weak self] in
                await publication.value
                guard let self else { return }
                let reply = self.applicationShouldTerminate(sender)
                if reply != .terminateLater { self.replyToTermination(reply == .terminateNow) }
            }
            return .terminateLater
        }
        guard let game = liveGameName() else { return finishTermination() }
        Task { @MainActor [weak self] in
            self?.requestConfirmation(game) { [weak self] reply in
                guard let self else { return }
                if reply == .terminateNow {
                    if self.finishTermination() == .terminateNow { self.replyToTermination(true) }
                } else {
                    self.replyToTermination(false)
                }
            }
        }
        return .terminateLater
    }

    private func finishTermination() -> NSApplication.TerminateReply {
        isWaitingForWindowlessQueue = false
        guard let draining = dockModel?.stopUpdateQueueForQuit() else { return .terminateNow }
        Task { @MainActor [weak self] in
            await draining.value
            self?.replyToTermination(true)
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

/// Holds the loading screen until HoYoPlay's art is ready, then the launcher itself.
private struct LauncherWindowContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.launcherRevealed {
                RootView()
                    .transition(.opacity)
            } else {
                LaunchLoadingView()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: model.launcherRevealed)
        .frame(minWidth: 960, minHeight: 540)
        .background { HiddenLaunchWindow(hidden: model.launchedHidden) }
        // Installed here, not in RootView: startup can reattach a running game while the loading screen shows.
        .task { model.quitConfirmation = QuitConfirmation.present }
    }
}

/// Keeps the launcher window invisible while a shortcut started MacGacha only to play.
/// The window still exists, so startup runs as usual and revealing it needs no new scene.
private struct HiddenLaunchWindow: NSViewRepresentable {
    let hidden: Bool

    final class Probe: NSView {
        var keepsWindowHidden = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard keepsWindowHidden, let window else { return }
            // Transparent before SwiftUI first orders it front, then out of the window list.
            window.alphaValue = 0
            DispatchQueue.main.async { [weak window] in
                guard let window, window.alphaValue == 0 else { return }
                window.orderOut(nil)
            }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe(); probe.keepsWindowHidden = hidden
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.keepsWindowHidden = hidden
        if !hidden { probe.window?.alphaValue = 1 }
    }
}
