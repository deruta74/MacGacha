// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import RuntimeManager
import SwiftUI

struct GPTKImportSheet: View {
    @Environment(AppModel.self) private var model
    @State private var selection: URL?
    @State private var choosingFolder = false

    private static let gptkPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import D3DMetal")
                .font(.title3.weight(.semibold))
            content
                .frame(minHeight: 160)
            HStack {
                Button("Choose Folder…") { choosingFolder = true }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                if case .choose(let candidates) = model.importState {
                    Button("Import") {
                        if let pick = candidates.first(where: { $0.root == selection }) ?? candidates.first {
                            model.chooseCandidate(pick)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addGPTKSearchRoot(url) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.importState {
        case .searching, nil:
            ProgressView("Looking for Game Porting Toolkit…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound:
            ContentUnavailableView {
                Label("No Game Porting Toolkit found", systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text("Open the Game Porting Toolkit disk image from Apple, then rescan, or choose the folder that contains it.")
            } actions: {
                Button("Rescan") { model.rescanGPTK() }
                Link("Get Game Porting Toolkit from Apple", destination: Self.gptkPage)
            }
        case .choose(let candidates):
            List(candidates, id: \.root, selection: $selection) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.version.map { String(localized: "D3DMetal \($0)", comment: "The argument is a version") }
                    ?? String(localized: "D3DMetal, unknown version"))
                        .font(.headline)
                    Text(candidate.root.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .onAppear { selection = selection ?? candidates.first?.root }
        }
    }
}

#Preview {
    GPTKImportSheet()
        .environment(AppModel.preview(importState: .notFound))
}
