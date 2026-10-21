// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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

    private var game: LauncherGame {
        LauncherGame.all.first { $0.id == selectedID } ?? LauncherGame.all[0]
    }

    /// Reduce Motion only changes the default; an explicit choice always wins.
    private var animated: Binding<Bool> {
        Binding(
            get: { animatedChosen ? animatedSetting : (animatedSetting && !reduceMotion) },
            set: { animatedSetting = $0; animatedChosen = true }
        )
    }

    var body: some View {
        ZStack {
            GameBackdrop(game: game, art: model.gameArt[game.id], animated: animated.wrappedValue)
                .id(game.id)
                .transition(.opacity)
            HStack(alignment: .bottom, spacing: 0) {
                GameRail(selectedID: $selectedID, panel: $panel)
                    .padding(.leading, 12)
                    .padding(.top, 40) // below the window's traffic lights
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity)
                GameFooter(game: game, art: model.gameArt[game.id], panel: $panel, gameSheet: $gameSheet, animated: animated)
                    // A fresh footer per game, so a confirmation opened for one game can't act on another.
                    .id(game.id)
                    .padding(24)
            }
        }
        .animation(.smooth(duration: 0.35), value: selectedID)
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
            }
        }
        // While a panel is open, its sheet presents the consent and import flow instead.
        .modifier(RuntimeFlowSheets(active: panel == nil && gameSheet == nil))
        .alert("Something went wrong", isPresented: errorBinding, presenting: model.lastError) { _ in
            Button("OK", role: .cancel) { model.dismissError() }
        } message: { message in
            Text(message)
        }
        .task { await model.loadGameArt() }
        #if DEBUG
        .onAppear(perform: applyDebugLaunchArguments)
        #endif
    }

    #if DEBUG
    /// Debug builds only: `-MacGachaDebugGame starrail -MacGachaDebugPanel runtimes` (or `-MacGachaDebugSheet install`)
    /// opens a state directly, for screenshots without clicking through the UI.
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "MacGachaDebugGame"), LauncherGame.all.contains(where: { $0.id == id }) {
            selectedID = id
        }
        if let name = defaults.string(forKey: "MacGachaDebugPanel") {
            panel = Panel(rawValue: name)
        }
        switch defaults.string(forKey: "MacGachaDebugSheet") {
        case "install": gameSheet = .install(selectedID)
        case "voices": gameSheet = .voices(selectedID)
        default: break
        }
    }
    #endif

    private static func game(_ id: String) -> LauncherGame {
        LauncherGame.all.first { $0.id == id } ?? LauncherGame.all[0]
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
