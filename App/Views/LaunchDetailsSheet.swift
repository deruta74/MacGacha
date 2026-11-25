// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch
import SwiftUI

struct LaunchDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame
    @State private var loading = true

    private var failure: LaunchFailureInfo? {
        if case .failed(let failure) = model.launchState(for: game.id) { return failure }
        return nil
    }
    private var successful: SuccessfulLaunch? { failure?.diagnosis?.previous ?? model.successfulLaunches[game.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Launch Details").font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let failure {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Probable cause").font(.headline)
                            Text(LaunchDiagnosticText.explanation(failure))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let previous = successful?.configuration, let attempted = failure.diagnosis?.attempted {
                            let changes = LaunchDiagnosticText.changedValues(previous: previous, attempted: attempted)
                            if !changes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Changed values").font(.headline)
                                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                        GridRow {
                                            Color.clear.frame(width: 0, height: 1).accessibilityHidden(true)
                                            Text("Previous").font(.caption.bold())
                                            Text("Attempted").font(.caption.bold())
                                        }
                                        ForEach(changes, id: \.field) { change in
                                            GridRow(alignment: .top) {
                                                Text(change.label).foregroundStyle(.secondary)
                                                Text(change.previous)
                                                Text(change.attempted)
                                            }
                                            .font(.callout)
                                        }
                                    }
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else if let attempted = failure.diagnosis?.attempted {
                            configuration(attempted)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last successful launch").font(.headline)
                        if let successful {
                            Text(successful.endedAt, format: .dateTime.year().month().day().hour().minute())
                                .foregroundStyle(.secondary)
                            configuration(successful.configuration)
                            Text("Recorded after a normal session of at least two minutes.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("No successful launch recorded for this edition.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if failure != nil {
                        Text("Verify files or check Dependencies. Game updates cannot be undone here.")
                            .font(.callout).foregroundStyle(.secondary)
                        if failure?.diagnosis?.retryID != nil {
                            Text("Uses the previous installed configuration once, without changing saved settings.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 370)
            HStack {
                if failure?.hasLog == true { Button("Open Log") { model.openLaunchLog(game.id) } }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if failure?.diagnosis?.retryID != nil {
                    Button("Try Previous Configuration Once") {
                        model.retrySuccessfulLaunch(game.id)
                        dismiss()
                    }
                    .disabled(!model.canRetrySuccessfulLaunch(game.id))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.refreshLaunchHistory(); loading = false }
    }

    private func configuration(_ configuration: LaunchConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Game build: \(configuration.gameBuild)")
            Text("Runtime: \(configuration.bundleID)")
            Text("Components: \(configuration.componentIDs.joined(separator: ", "))")
            Text("Graphics backend: \(configuration.settings.backend.rawValue)")
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Only typed failures and an actual configuration comparison inform this text.
/// Changes are evidence of a possible cause, never a claim that the runtime caused it.
struct LaunchChangedValue: Equatable {
    let field: String
    let label: String
    let previous: String
    let attempted: String
}

enum LaunchDiagnosticText {
    static func changedValues(previous: LaunchConfiguration, attempted: LaunchConfiguration) -> [LaunchChangedValue] {
        var rows: [LaunchChangedValue] = []
        func add(_ field: String, _ label: String, _ old: String, _ new: String) {
            if old != new { rows.append(LaunchChangedValue(field: field, label: label, previous: old, attempted: new)) }
        }
        func flag(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }
        func build(_ value: LaunchConfiguration) -> String {
            [value.gameBuild, value.gameBuildID].compactMap { $0 }.joined(separator: "\n")
        }
        func runtime(_ value: LaunchConfiguration) -> String {
            [value.bundleID, value.runtimeProfileID, value.runtimeDigest.hex].joined(separator: "\n")
        }
        func helpers(_ value: LaunchConfiguration) -> String {
            value.compatibilityComponentIDs.keys.sorted { $0.rawValue < $1.rawValue }.map {
                "\($0.rawValue): \(value.compatibilityComponentIDs[$0]!)"
            }.joined(separator: "\n")
        }
        add("game", String(localized: "Game build"), build(previous), build(attempted))
        add("runtime", String(localized: "Runtime"), runtime(previous), runtime(attempted))
        add("components", String(localized: "Components"), previous.componentIDs.joined(separator: "\n"), attempted.componentIDs.joined(separator: "\n"))
        add("helpers", String(localized: "Compatibility components"), helpers(previous), helpers(attempted))
        add("recipe", String(localized: "Launch recipe"), previous.recipeVersion.formatted(), attempted.recipeVersion.formatted())
        if let oldMode = previous.gameModeEnabled, let newMode = attempted.gameModeEnabled {
            add("gameMode", String(localized: "Game Mode"), flag(oldMode), flag(newMode))
        }
        let old = previous.settings, new = attempted.settings
        add("backend", String(localized: "Graphics"), old.backend.rawValue, new.backend.rawValue)
        add("retina", String(localized: "Retina resolution"), flag(old.retina), flag(new.retina))
        add("frameLimit", String(localized: "Frame limit"), old.frameLimit?.formatted() ?? String(localized: "Off"), new.frameLimit?.formatted() ?? String(localized: "Off"))
        add("directX12", String(localized: "DirectX 12"), flag(old.directX12), flag(new.directX12))
        add("patches", String(localized: "Compatibility patches"), flag(old.compatibilityPatches), flag(new.compatibilityPatches))
        let oldDisplay = old.display.map { [$0.name, $0.id].joined(separator: "\n") } ?? String(localized: "Main Display")
        let newDisplay = new.display.map { [$0.name, $0.id].joined(separator: "\n") } ?? String(localized: "Main Display")
        add("display", String(localized: "Display"), oldDisplay, newDisplay)
        add("surround", String(localized: "Surround sound"), flag(old.surroundSound), flag(new.surroundSound))
        add("metalHUD", String(localized: "Metal HUD"), flag(old.metalHUD), flag(new.metalHUD))
        add("hudContents", String(localized: "Contents"), GameSettingsSheet.name(of: old.metalHUDContents), GameSettingsSheet.name(of: new.metalHUDContents))
        add("hudElements", String(localized: "Metal HUD"), old.metalHUDElements.map { GameSettingsSheet.name(of: $0) }.joined(separator: ", "), new.metalHUDElements.map { GameSettingsSheet.name(of: $0) }.joined(separator: ", "))
        add("hudPosition", String(localized: "Position"), GameSettingsSheet.name(of: old.metalHUDPosition), GameSettingsSheet.name(of: new.metalHUDPosition))
        add("hudSize", String(localized: "Size"), GameSettingsSheet.name(of: old.metalHUDSize), GameSettingsSheet.name(of: new.metalHUDSize))
        add("unlockFPS", String(localized: "Unlock frame rate"), flag(old.unlockFPS), flag(new.unlockFPS))
        add("unlockTarget", String(localized: "Target"), old.unlockTarget.formatted(), new.unlockTarget.formatted())
        return rows
    }

    static func explanation(_ failure: LaunchFailureInfo) -> String {
        if failure.cause == .antiCheatOffline { return String(localized: "The game could not reach its servers. Check your connection or try another network.") }
        switch failure.diagnosis?.reason ?? .unknown {
        case .runtime: return String(localized: "The selected runtime is unavailable. Check Dependencies.")
        case .process: return String(localized: "A required tool could not finish. Check Diagnostics for details.")
        case .busy: return String(localized: "Another operation is already running. Wait for it to finish and try again.")
        case .rosetta: return String(localized: "Rosetta 2 is required to run games. Install it using MacGacha, then try again.")
        case .location: return String(localized: "The game drive is unavailable. Reconnect it, then resume the operation.")
        case .gameFiles: return String(localized: "The game executable is missing. Verify Files.")
        case .network: return String(localized: "The game could not reach its servers. Check your connection or try another network.")
        case .unknown:
            let changes = failure.diagnosis?.comparison?.changes ?? []
            if changes.contains(.game) { return String(localized: "The game build changed. The update may have affected compatibility.") }
            if changes.contains(.backend) { return String(localized: "The graphics backend changed and may be involved.") }
            if changes.contains(.runtime) { return String(localized: "The runtime changed and may be involved.") }
            if changes.contains(.settings) { return String(localized: "Launch settings changed and may be involved.") }
            return String(localized: "The cause could not be determined.")
        }
    }
}
