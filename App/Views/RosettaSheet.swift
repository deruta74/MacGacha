// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

/// Why Rosetta 2 is needed and one button that hands the install to macOS's own prompt.
struct RosettaSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame

    private var installed: Bool { model.rosetta == .installed }
    private var waiting: Bool { model.rosettaInstallInProgress && !installed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install Rosetta 2")
                    .font(.title2.weight(.semibold))
                Text("\(game.name) runs through Wine, which is built for Intel processors. Apple's Rosetta 2 translates it on this Mac. It's free from Apple and installs in about a minute.",
                     comment: "Rosetta sheet explanation; the argument is the game's name")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            Form {
                Section {
                    if installed {
                        Label("Rosetta 2 is installed.", systemImage: "checkmark.circle.fill")
                    } else if waiting {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("macOS asks whether to install Rosetta. Click Install in that window and accept Apple's license; MacGacha continues on its own.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Label("macOS shows its own window to install Rosetta. MacGacha doesn't need your password.", systemImage: "info.circle")
                    }
                } footer: {
                    if waiting {
                        Text("If no window appears, open Terminal and run softwareupdate --install-rosetta.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if installed {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        model.cancelRosettaInstall()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    // While waiting, the same button brings Apple's window back instead of starting over.
                    if waiting {
                        Button("Show Apple's Window Again") { model.requestRosettaInstall() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Install Rosetta…") { model.requestRosettaInstall() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
    }
}
