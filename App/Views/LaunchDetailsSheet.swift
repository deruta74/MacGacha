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
                            let changes = model.launchChangedValues(previous: previous, attempted: attempted)
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
        let display = model.launchConfigurationDisplay(configuration)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Game build: \(display.gameBuild)")
            Text("Runtime: \(display.runtime)")
            Text("Components: \(display.components)")
            Text("Graphics backend: \(display.backend)")
        }
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}
