// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting = false
    @State private var bundle: DiagnosticZip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent MacGacha events. Tokens and account details are removed before anything is written here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            Divider()
            if model.logLines.isEmpty {
                ContentUnavailableView(
                    "No events yet",
                    systemImage: "text.alignleft",
                    description: Text("Installs, updates and errors are recorded here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            LogRow(entry: LogEntry(line: line))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottomLeading)
                .background(.background)
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshLogs() }
                }
                .help("Reload recent events")
                if model.isExporting {
                    ProgressView().controlSize(.small)
                }
                Button("Export Diagnostic Bundle…", systemImage: "square.and.arrow.up") {
                    // Build the complete bundle first; the save panel only ever gets a finished file.
                    Task {
                        guard let file = try? await model.makeDiagnosticBundle() else { return }
                        bundle = DiagnosticZip(url: file)
                        exporting = true
                    }
                }
                .disabled(model.isExporting)
                .help("Save a zip with system details and redacted logs to share in a bug report")
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: bundle,
            contentType: .zip,
            defaultFilename: Self.defaultFilename()
        ) { _ in
            // Saved or cancelled, the temporary copy is no longer needed.
            if let file = bundle?.url {
                Task { await TemporaryDiagnosticBundle.discard(file) }
            }
            bundle = nil
        }
        .task { await model.refreshLogs() }
    }

    static func defaultFilename(now: Date = .now) -> String {
        // The user's local date, not UTC, so a late-evening export isn't named for tomorrow or yesterday.
        "MacGacha-Diagnostics-\(now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))"
    }
}

/// One MacGacha JSONL event, formatted for reading. Lines that aren't valid JSON are
/// shown as they are, so nothing is hidden from the user.
struct LogEntry {
    var time = ""
    var level = "info"
    var category = ""
    var message: String
    var details = ""

    init(line: String) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = object["message"] as? String else {
            self.message = line
            return
        }
        self.message = message
        level = object["level"] as? String ?? "info"
        category = object["category"] as? String ?? ""
        if let ts = object["ts"] as? String, let date = try? Date(ts, strategy: .iso8601) {
            time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        }
        if let metadata = object["metadata"] as? [String: Any], !metadata.isEmpty {
            details = metadata.keys.sorted().map { "\($0)=\(metadata[$0].map { "\($0)" } ?? "")" }.joined(separator: "  ")
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.time)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityLabel(entry.level)
            Text(entry.category)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                if !entry.details.isEmpty {
                    Text(entry.details).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var symbol: String {
        switch entry.level {
        case "error", "fault": "xmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }

    private var tint: Color {
        switch entry.level {
        case "error", "fault": .red
        case "warning": .orange
        default: .secondary.opacity(0.5)
        }
    }
}

/// A finished diagnostic zip on disk, handed to the save panel as-is.
struct DiagnosticZip: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}
