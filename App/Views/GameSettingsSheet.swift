// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch
import RuntimeManager
import SwiftUI

/// How one game launches. Every change is saved at once and applies the next time Play is pressed.
struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame

    private var settings: Binding<LaunchSettings> {
        Binding(
            get: { model.launchSettings(for: game.id) },
            set: { newValue in
                do { try model.saveLaunchSettings(newValue, for: game.id) } catch { model.show(error) }
            }
        )
    }

    /// Only Zenless Zone Zero has a DirectX 12 renderer, and only D3DMetal runs it.
    private var offersDirectX12: Bool { game.id == "zzz" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Graphics", selection: settings.backend) {
                        Text("D3DMetal", comment: "Graphics backend name; usually not translated").tag(RuntimeBackend.d3dmetal)
                        Text("DXMT", comment: "Graphics backend name; usually not translated").tag(RuntimeBackend.dxmt)
                    }
                    .pickerStyle(.segmented)
                    Picker("Frame limit", selection: settings.frameLimit) {
                        Text("Off").tag(Int?.none)
                        ForEach([30, 60, 120], id: \.self) { fps in
                            Text(fps.formatted()).tag(Int?.some(fps))
                        }
                    }
                    .pickerStyle(.segmented)
                    if offersDirectX12 {
                        Toggle("DirectX 12", isOn: settings.directX12)
                            .disabled(settings.wrappedValue.backend != .d3dmetal)
                    }
                } footer: {
                    Text(graphicsFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Retina resolution", isOn: settings.retina)
                } footer: {
                    Text("Sharper, but much heavier on the GPU.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Compatibility patches", isOn: settings.compatibilityPatches)
                } footer: {
                    Text(patchesFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("\(game.name) Settings", comment: "Sheet title; the argument is the game's name"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var graphicsFooter: String {
        var text = String(localized: "The frame limit is set in the graphics layer, not in the game. Changes apply the next time you press Play.")
        if offersDirectX12, settings.wrappedValue.backend != .d3dmetal {
            text = String(localized: "DirectX 12 needs D3DMetal. \(text)", comment: "The argument is the general note about graphics settings")
        }
        return text
    }

    private var patchesFooter: String {
        String(localized: """
            Workarounds \(game.name) needs to start on a Mac, such as a small helper that starts the game. \
            They don't change the game's files. With patches off, the game usually doesn't start.
            """, comment: "The argument is the game's name")
    }
}

#Preview {
    GameSettingsSheet(game: LauncherGame.all[2])
        .environment(AppModel.preview())
}
