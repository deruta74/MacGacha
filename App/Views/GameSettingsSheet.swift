// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch
import LauncherCore
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

    /// With one display there is nothing to choose, unless a choice was saved while another was connected.
    private var offersDisplayChoice: Bool {
        model.connectedDisplays.count > 1 || settings.wrappedValue.display != nil
    }

    private var missingDisplay: DisplayChoice? {
        guard let chosen = settings.wrappedValue.display,
            !model.connectedDisplays.contains(where: { $0.id == chosen.id }) else { return nil }
        return chosen
    }

    /// Selects by ID so a display that reports a new name still matches the saved choice.
    private var displayID: Binding<String?> {
        Binding(
            get: { settings.wrappedValue.display?.id },
            set: { id in
                var value = settings.wrappedValue
                if let id {
                    let name = model.connectedDisplays.first { $0.id == id }?.name ?? value.display?.name ?? ""
                    value.display = DisplayChoice(id: id, name: name)
                } else {
                    value.display = nil
                }
                settings.wrappedValue = value
            }
        )
    }

    private var displayFooter: String {
        if missingDisplay != nil {
            return String(localized: "That display isn't connected, so the game opens on the main display. Changes apply the next time you press Play.")
        }
        return String(localized: "The main display is the one with the menu bar. Changes apply the next time you press Play.")
    }

    private static func name(of display: String) -> String {
        display.isEmpty ? String(localized: "Unnamed Display") : display
    }

    /// Star Rail stores its frame rate in its own settings, which accept 30, 60 or 120.
    private var offersStarRailUnlock: Bool { GameDefinition.find(game.id)?.family == .starrail }

    /// Turning the unlock on lifts a lower frame limit, so the unlock isn't silently capped.
    private var unlockFPS: Binding<Bool> {
        Binding(
            get: { settings.wrappedValue.unlockFPS },
            set: { isOn in
                var value = settings.wrappedValue
                value.unlockFPS = isOn
                if isOn, let limit = value.frameLimit, limit < value.unlockTarget { value.frameLimit = value.unlockTarget }
                settings.wrappedValue = value
            }
        )
    }

    /// Only Zenless Zone Zero has a DirectX 12 renderer, and only D3DMetal runs it.
    private var offersDirectX12: Bool { Recipes.recipe(for: game.id)?.supportsDirectX12 == true }

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
                        ForEach([30, 60, 90, 120], id: \.self) { fps in
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
                if offersStarRailUnlock {
                    Section {
                        Toggle("Unlock 120 FPS", isOn: unlockFPS)
                    } footer: {
                        Text(unlockFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if offersDisplayChoice {
                    Section {
                        Picker("Display", selection: displayID) {
                            Text("Main Display").tag(String?.none)
                            ForEach(model.connectedDisplays, id: \.id) { display in
                                Text(Self.name(of: display.name)).tag(String?.some(display.id))
                            }
                            if let missing = missingDisplay {
                                Text("\(Self.name(of: missing.name)) (Not Connected)",
                                    comment: "A chosen display that is unplugged; the argument is its name")
                                    .tag(String?.some(missing.id))
                            }
                        }
                    } footer: {
                        Text(displayFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    private var unlockFooter: String {
        let value = settings.wrappedValue
        if value.unlockFPS, let limit = value.frameLimit, limit < value.unlockTarget {
            return String(localized: "The frame limit is \(limit) FPS, so the game won't go above it. Set the limit to 120 or Off to play at 120 FPS.",
                comment: "The argument is the current frame limit")
        }
        return String(localized: "Sets 120 FPS in the game's own graphics settings before each launch. While it's on, the game hides its FPS option. Turning it off sets the game back to 60 FPS.")
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
