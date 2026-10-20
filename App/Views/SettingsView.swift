// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @AppStorage("animatedBackgrounds") private var animatedBackgrounds = true
    @AppStorage("animatedBackgroundsChosen") private var animatedChosen = false

    var body: some View {
        Form {
            Section {
                Toggle("Animated backgrounds", isOn: Binding(
                    get: { animatedBackgrounds },
                    set: { animatedBackgrounds = $0; animatedChosen = true }
                ))
            } footer: {
                Text("Plays the game's animated art when HoYoPlay provides it. Still images use less power.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Install games in") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(model.installRoot.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.installRoot])
                    }
                    Button("Choose…") { choosing = true }
                }
            } footer: {
                Text("Games need a lot of space. Pick a drive with at least 100 GB free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setInstallRoot(url) }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel.preview())
}
