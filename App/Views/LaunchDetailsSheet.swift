// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch
import SwiftUI

/// Why the last launch failed, what changed since the last good session, and a one-time retry with that setup.
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
    private var changes: [LaunchChangedValue] {
        guard let previous = successful?.configuration, let attempted = failure?.diagnosis?.attempted else { return [] }
        return model.launchChangedValues(previous: previous, attempted: attempted)
    }
    private var offersRetry: Bool { failure?.diagnosis?.retryID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch Details").font(.title3.bold())
                Text(verbatim: model.editionDisplayName(game)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let failure {
                        Label(LaunchDiagnosticText.explanation(failure), systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                        if !changes.isEmpty { changedValues }
                    }
                    lastSuccessful
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            if failure != nil {
                Text(offersRetry
                    ? String(localized: "Uses the previous installed configuration once, without changing saved settings.")
                    : String(localized: "Verify files or check Dependencies. Game updates cannot be undone here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if failure?.hasLog == true { Button("Open Log") { model.openLaunchLog(game.id) } }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(offersRetry ? .cancelAction : .defaultAction)
                if offersRetry {
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
        .frame(width: 500)
        .task { await model.refreshLaunchHistory(); loading = false }
    }

    /// Previous → attempted, one row per value that differs.
    private var changedValues: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changed values").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: "").gridColumnAlignment(.trailing)
                    Text("Previous")
                    Text("Attempted")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(changes, id: \.field) { change in
                    GridRow {
                        Text(verbatim: change.label).foregroundStyle(.secondary)
                        Text(verbatim: change.previous)
                        Text(verbatim: change.attempted).fontWeight(.medium)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private var lastSuccessful: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last successful launch").font(.headline)
                Spacer()
                if let successful {
                    Text(successful.endedAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let successful {
                let display = model.launchConfigurationDisplay(successful.configuration)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("Game build", display.gameBuild)
                    row("Graphics", display.backend)
                    row("Runtime", display.runtime)
                    row("Components", display.components)
                }
                .font(.callout)
                .textSelection(.enabled)
                Text("Recorded after a normal session of at least two minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if loading {
                ProgressView().controlSize(.small)
            } else {
                Text("No successful launch recorded for this edition.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
