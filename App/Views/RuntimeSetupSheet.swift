// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

/// What one game still needs before Play, and one button that installs all of it.
struct RuntimeSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame
    /// Opens the Runtimes panel for people who want to pick versions themselves.
    let chooseManually: () -> Void

    private var plan: RuntimeSetupPlan? { model.runtimeSetupPlan(for: game.id) }
    /// No plan can mean everything is installed, or that the runtime list isn't readable yet.
    private var ready: Bool { plan == nil && !model.missingComponents(for: game.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up \(game.name)", comment: "Runtime setup sheet title; the argument is the game's name")
                    .font(.title2.weight(.semibold))
                Text("\(game.name) is a Windows game. MacGacha runs it with these compatibility components, matched to the game's settings.",
                     comment: "Runtime setup sheet explanation; the argument is the game's name")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            Form {
                if let plan {
                    Section {
                        ForEach(plan.items) { item in
                            LabeledContent(item.name) {
                                if let size = item.size { Text(size.formatted(.byteCount(style: .file))).monospacedDigit() }
                            }
                        }
                    } footer: {
                        if plan.needsAppleTerms {
                            Text("D3DMetal is Apple software. You'll be asked to accept Apple's license terms before it downloads.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let total = plan.totalSize, plan.items.count > 1 {
                        Section {
                            LabeledContent("Download") {
                                Text(total.formatted(.byteCount(style: .file))).monospacedDigit()
                            }
                        }
                    }
                } else if ready {
                    Section {
                        Label("Everything \(game.name) needs is installed.", systemImage: "checkmark.circle.fill")
                    }
                } else {
                    Section {
                        Label("MacGacha can't tell yet what \(game.name) needs. Choose the runtimes manually, or try again in a moment.",
                              systemImage: "exclamationmark.triangle.fill")
                    }
                }
            }
            .formStyle(.grouped)
            ViewThatFits(in: .horizontal) {
                HStack {
                    manualButton
                    Spacer()
                    sheetButtons
                }
                VStack(alignment: .trailing, spacing: 12) {
                    manualButton
                    HStack { sheetButtons }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
    }

    private var manualButton: some View {
        Button("Choose Manually…") {
            dismiss()
            chooseManually()
        }
    }

    @ViewBuilder private var sheetButtons: some View {
        if plan == nil {
            if ready {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            // The sheet closes first so Apple's terms, when needed, can take its place.
            Button("Install") {
                model.installRecommended(for: game.id)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
