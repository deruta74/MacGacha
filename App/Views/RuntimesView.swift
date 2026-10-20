// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import DownloadEngine
import RuntimeManager
import SwiftUI

struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isStarting && model.rows.isEmpty {
                ProgressView("Checking installed runtimes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        ForEach(model.rows) { row in
                            RuntimeRowView(row: row)
                        }
                    } footer: {
                        Text("Translation layers the games run on. Each version is kept on its own, so an update never breaks a working one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.start() }
                }
                .disabled(model.isStarting)
                .help("Check installed runtimes again")
            }
        }
    }
}

struct RuntimeRowView: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeRow
    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.kindName).font(.headline)
                    Text(row.version).foregroundStyle(.secondary).monospacedDigit()
                }
                detail
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove \(row.kindName) \(row.version)?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove", role: .destructive) {
                Task { await model.remove(row.id) }
            }
        } message: {
            Text("Games that use this version won't start until you install it again.")
        }
    }

    @ViewBuilder private var detail: some View {
        switch row.state {
        case .notInstalled:
            Text(row.needsConsent ? "\(row.licenseName) · Needs your consent" : row.licenseName)
                .font(.caption).foregroundStyle(.secondary)
        case .working(let phase, let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(Self.label(for: phase, fraction: fraction))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(for: phase, fraction: fraction))
        case .installed(let source):
            Label(
                source == .importFromGPTK ? "\(row.licenseName) · Imported from Game Porting Toolkit" : "\(row.licenseName) · Installed",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(StatusLabelStyle(tint: .green))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle(tint: .orange))
                .lineLimit(2)
                .textSelection(.enabled)
        case .invalid(let reason, _):
            Label("Damaged: \(reason)", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle(tint: .red))
                .lineLimit(2)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch row.state {
            case .notInstalled, .failed:
                if row.canImportGPTK {
                    Button("Import…") { model.importGPTK(row.id) }
                        .help("Import D3DMetal from Apple's Game Porting Toolkit")
                }
                Button(row.state == .notInstalled ? "Install" : "Try Again") { model.install(row.id) }
            case .working:
                Button("Cancel") { model.cancel(row.id) }
            case .installed:
                Button("Remove") { confirmingRemoval = true }
            case .invalid(_, let removable):
                if removable {
                    Button("Remove") { confirmingRemoval = true }
                }
            }
        }
        .controlSize(.regular)
    }

    private var symbol: String {
        switch row.id {
        case let id where id.hasPrefix("wine"): "wineglass"
        case let id where id.hasPrefix("dxmt"): "cube.transparent"
        case let id where id.hasPrefix("d3dmetal"): "cpu"
        default: "shippingbox"
        }
    }

    static func label(for phase: OperationPhase, fraction: Double?) -> String {
        let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        switch phase {
        case .checkingSpace: return "Checking free space…"
        case .staging: return "Downloading\(percent)"
        case .verifying: return "Verifying\(percent)"
        case .committing: return "Installing…"
        case .deleting, .cleaningUp: return "Finishing…"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Keeps the status text secondary while the icon carries the state's color.
private struct StatusLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

#Preview {
    RuntimesView()
        .environment(AppModel.preview())
        .frame(width: 720, height: 420)
}
