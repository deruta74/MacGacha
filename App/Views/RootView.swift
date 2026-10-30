// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Launch
import LauncherCore
import SwiftUI

enum Panel: String, Identifiable {
    case runtimes, diagnostics
    var id: Self { self }
}

/// The launcher window: the selected game's art fills it, with a glass rail on the left
/// and the game's primary action bottom-right, like HoYoPlay.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("selectedGame") private var selectedID = LauncherGame.all[0].id
    @State private var panel: Panel?
    @State private var gameSheet: GameSheet?
    /// On by default like HoYoPlay; Reduce Motion starts with still images instead.
    @AppStorage("animatedBackgrounds") private var animatedSetting = true
    @AppStorage("animatedBackgroundsChosen") private var animatedChosen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var selection = BackgroundSelection(clock: ContinuousClock())
    @State private var images = ArtImageCache()
    /// The slide on screen: it follows the selection only once its image has loaded,
    /// so the background and its highlights button always change together.
    @State private var shownSlide: GameBackground?

    /// The rail shows one region; a selection from the other region falls back to its first game.
    private var game: LauncherGame {
        model.visibleGames.first { $0.id == selectedID } ?? model.visibleGames[0]
    }

    /// Reduce Motion only changes the default; an explicit choice always wins.
    private var animated: Binding<Bool> {
        Binding(
            get: { animatedChosen ? animatedSetting : (animatedSetting && !reduceMotion) },
            set: { animatedSetting = $0; animatedChosen = true }
        )
    }

    private struct SelectionInputs: Equatable {
        let region: Region
        let gameID: String
        let backgrounds: [GameBackground]
        let animated: Bool
        let reduceMotion: Bool
    }

    private var selectionInputs: SelectionInputs {
        SelectionInputs(region: model.region, gameID: game.id, backgrounds: model.gameArt[game.id]?.backgrounds ?? [],
            animated: animated.wrappedValue, reduceMotion: reduceMotion)
    }

    /// The selected slide once its image is decoded; until then the previous slide stays.
    private var readySlide: GameBackground? {
        guard let current = selection.slides?.current, images.image(current.image) != nil else { return nil }
        return current
    }

    private func updateWindowState() {
        selection.setWindow(active: activeState != .inactive, visible: scenePhase == .active)
    }

    var body: some View {
        ZStack {
            GameBackdrop(game: game, art: model.gameArt[game.id], video: selection.video, slide: shownSlide,
                images: images, crossfade: selection.allowsCrossfade) { selection.setPlaybackState($0, for: $1) }
                .id(game.id)
                .transition(.opacity)
            if let slides = selection.slides, !slides.dotIDs.isEmpty, let shown = shownSlide {
                BackgroundDots(ids: slides.dotIDs, current: shown.id,
                    onEnter: {}, onSelect: { selection.clickDot($0) })
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            HStack(alignment: .bottom, spacing: 0) {
                GameRail(selectedID: Binding(get: { game.id }, set: { selectedID = $0 }), panel: $panel)
                    .padding(.leading, 12)
                    .padding(.top, 40) // below the window's traffic lights
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity)
                GameFooter(game: game, art: model.gameArt[game.id], highlights: shownSlide?.highlights ?? selection.video?.background.highlights,
                    images: images, panel: $panel, gameSheet: $gameSheet, animated: animated)
                    // A fresh footer per game, so a confirmation opened for one game can't act on another.
                    .id(game.id)
                    .padding(24)
            }
        }
        .animation(.smooth(duration: 0.35), value: selectedID)
        .onChange(of: selectionInputs, initial: true) { old, new in
            if old.gameID != new.gameID || old.region != new.region { shownSlide = nil }
            images.preload(new.backgrounds.flatMap { [$0.image, $0.theme, $0.highlights?.image, $0.highlights?.hoverImage].compactMap { $0 } })
            selection.update(region: new.region, gameID: new.gameID, backgrounds: new.backgrounds,
                animated: new.animated, reduceMotion: new.reduceMotion)
        }
        .onChange(of: readySlide, initial: true) {
            if let readySlide { shownSlide = readySlide } else if selection.slides == nil { shownSlide = nil }
        }
        .onChange(of: activeState, initial: true) { updateWindowState() }
        .onChange(of: scenePhase) { updateWindowState() }
        .ignoresSafeArea()
        .frame(minWidth: 960, minHeight: 540)
        .sheet(item: $panel) { panel in
            PanelSheet(panel: panel)
        }
        .sheet(item: $gameSheet) { sheet in
            switch sheet {
            case .install(let id):
                InstallSheet(game: Self.game(id), installRoot: model.installRoot)
            case .voices(let id):
                VoicePacksSheet(game: Self.game(id))
            case .settings(let id):
                GameSettingsSheet(game: Self.game(id))
            case .setup(let id):
                RuntimeSetupSheet(game: Self.game(id)) { panel = .runtimes }
            case .rosetta(let id):
                RosettaSheet(game: Self.game(id))
            }
        }
        // While a panel is open, its sheet presents the consent and import flow instead.
        .modifier(RuntimeFlowSheets(active: panel == nil && gameSheet == nil))
        .alert("Something went wrong", isPresented: errorBinding, presenting: model.lastError) { _ in
            Button("OK", role: .cancel) { model.dismissError() }
        } message: { message in
            Text(message)
        }
        .alert(recoveryTitle, isPresented: recoveryBinding, presenting: model.recoveryNotices.first) { notice in
            Button("Show in Finder") {
                model.revealRecovery(notice)
                model.acknowledge(notice)
            }
            Button("OK", role: .cancel) { model.acknowledge(notice) }
        } message: { notice in
            Text(recoveryMessage(notice))
        }
        // A sheet belongs to one game; once its region is hidden it must not act on it.
        .onChange(of: model.region) { gameSheet = nil }
        #if DEBUG
        .onAppear(perform: applyDebugLaunchArguments)
        #endif
    }

    #if DEBUG
    /// Debug builds only: `-MacGachaDebugGame starrail -MacGachaDebugPanel runtimes` (or `-MacGachaDebugSheet install`,
    /// or `-MacGachaDebugSettings YES`) opens a state directly, for screenshots without clicking through the UI.
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "MacGachaDebugGame"), LauncherGame.all.contains(where: { $0.id == id }) {
            selectedID = id
        }
        if let name = defaults.string(forKey: "MacGachaDebugPanel") {
            panel = Panel(rawValue: name)
        }
        if defaults.bool(forKey: "MacGachaDebugSettings") { openSettings() }
        switch defaults.string(forKey: "MacGachaDebugSheet") {
        case "install": gameSheet = .install(selectedID)
        case "voices": gameSheet = .voices(selectedID)
        case "settings": gameSheet = .settings(selectedID)
        case "setup": gameSheet = .setup(selectedID)
        case "rosetta": gameSheet = .rosetta(selectedID)
        default: break
        }
    }
    #endif

    private static func game(_ id: String) -> LauncherGame {
        LauncherGame.all.first { $0.id == id } ?? LauncherGame.all[0]
    }

    private var recoveryTitle: Text {
        guard let notice = model.recoveryNotices.first else { return Text(verbatim: "") }
        return Text("\(Self.game(notice.game).name) files were kept aside", comment: "Alert title; the argument is the game's name")
    }

    private func recoveryMessage(_ notice: RecoveryNotice) -> String {
        String(localized: """
            While \(Self.game(notice.game).name) was running, it made a new copy of a file MacGacha had set aside. \
            The game folder keeps the new file. The older copy is in a recovery folder, so nothing was lost.
            """, comment: "The argument is the game's name")
    }

    // An error alert wins; the notice waits until it's dismissed.
    private var recoveryBinding: Binding<Bool> {
        Binding(get: { model.lastError == nil && !model.recoveryNotices.isEmpty }, set: { _ in })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.dismissError() } })
    }
}

/// Runtimes and Diagnostics open over the art as sheets, so the launcher stays one window.
private struct PanelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let panel: Panel

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .runtimes: RuntimesView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .modifier(RuntimeFlowSheets(active: true))
        .frame(minWidth: 620, idealWidth: 680, minHeight: 320, idealHeight: 380)
    }
}

/// The consent sheet comes first; the import sheet opens only once consent is settled.
/// SwiftUI presents one sheet per surface, so the frontmost surface owns this flow.
struct RuntimeFlowSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    let active: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { active ? model.consentRequest : nil }, set: { _ in })) { request in
                // Only the sheet's own buttons answer consent; it can't be dismissed otherwise.
                ConsentSheet(request: request)
            }
            .sheet(isPresented: Binding(
                get: { active && model.importState != nil && model.consentRequest == nil },
                set: { if !$0 { model.cancelImport() } }
            )) {
                GPTKImportSheet()
            }
    }
}

#Preview {
    RootView()
        .environment(AppModel.preview())
        .frame(width: 1100, height: 620)
}

/// Asks before quitting while a game runs: the game's connection goes through MacGacha.
enum QuitConfirmation {
    @MainActor static func present(gameName: String, completion: @escaping @MainActor (NSApplication.TerminateReply) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(gameName) is running", comment: "Quit confirmation title; the argument is the game's name")
        alert.informativeText = String(localized: "If you quit MacGacha, the game loses its connection and will need to be restarted.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        completion(alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel)
    }
}
