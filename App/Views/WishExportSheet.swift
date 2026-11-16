// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import GameLibrary
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Downloads one game's wish history and saves it as a UIGF file the player picks.
struct WishExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame

    @State private var result: WishHistoryExport?
    @State private var failure: String?
    @State private var saved = false
    @State private var saveFailed = false
    @State private var choosingDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Wish History").font(.title3.bold())
            Group {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else if saveFailed {
                    Label("The file couldn't be saved there. Choose another place and try again.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                } else if let result {
                    Text(saved
                        ? String(localized: "Saved. Records: \(result.totalCount)", comment: "After saving the wish history; the argument is a count")
                        : String(localized: "Records downloaded: \(result.totalCount). Choose where to save the file.",
                            comment: "The argument is a count of wish history records"))
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        if let progress = model.wishHistoryProgress {
                            Text("Downloading… Records so far: \(progress.count)",
                                comment: "Wish history export progress; the argument is a count")
                                .monospacedDigit()
                        } else {
                            Text("Looking for the history link…")
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("The file uses the UIGF format, which wish trackers such as paimon.moe and starrailstation import. It stays on this Mac until you share it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if result == nil, failure == nil {
                    Button("Cancel", role: .cancel) { model.cancelWishHistoryExport(); dismiss() }
                } else if let result, !saved {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Save…") { choosingDestination = true }
                        .keyboardShortcut(.defaultAction)
                        .fileExporter(isPresented: $choosingDestination, document: UIGFDocument(data: result.data),
                            contentType: .json, defaultFilename: result.suggestedFilename) { outcome in
                            // The system error can name the chosen folder, so only a fixed message is shown.
                            switch outcome {
                            case .success: saveFailed = false; saved = true
                            case .failure: saveFailed = true
                            }
                        }
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            do { result = try await model.exportWishHistory(game.id) }
            catch {
                // A cancelled export (Cancel, or the switch turned off) has nothing to show.
                let error = launcherError(error)
                if error == .cancelled { dismiss() } else { failure = error.userMessage }
            }
        }
        .onDisappear { if result == nil { model.cancelWishHistoryExport() } }
    }
}

/// The exported bytes as-is. The history is private, so it is only ever written where the player chooses.
private struct UIGFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
