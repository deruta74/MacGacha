// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

@main
struct MacGachaApp: App {
    @State private var model = AppModel.live()

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
