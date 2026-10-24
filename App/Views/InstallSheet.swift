// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import GameLibrary
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Where to install, which voices, and whether it fits — then one button.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame
    @State private var location: URL
    @State private var voices: Set<String> = ["en-us"]
    @State private var check = SizeCheck.loading
    @State private var attempt = 0
    @State private var picking = false
    @State private var pickMode = PickMode.location
    @State private var confirmingParts = false

    private enum PickMode { case location, existing }

    /// The size check for the current location and voices: running, done, or refused with a reason.
    private enum SizeCheck: Equatable {
        case loading, ready(GameEstimate), failed(String, retryable: Bool)
    }

    init(game: LauncherGame, installRoot: URL) {
        self.game = game
        _location = State(initialValue: installRoot.appendingPathComponent(game.defaultInstallDirectoryName, isDirectory: true))
    }

    private var definition: GameDefinition? { GameDefinition.all.first { $0.id == game.id } }
    private var estimate: GameEstimate? { if case .ready(let value) = check { value } else { nil } }
    private var verdict: SpaceVerdict? { estimate.map(SpaceVerdict.of) }
    private var immediateVerdict: SpaceVerdict? { estimate.map(SpaceVerdict.immediate) }
    /// Another game's operation holds the one slot; starting here would only fail as busy.
    private var blocked: Bool { model.isGameOperationRunning }
    private var displayPath: String {
        let path = location.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Install \(game.name)")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Form {
                Section {
                    LabeledContent {
                        Button("Change…") { pickMode = .location; picking = true }
                    } label: {
                        Text(displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(displayPath)
                    }
                } header: {
                    Text("Location")
                } footer: {
                    if case .failed(let reason, false) = check {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    ForEach(definition?.voices ?? [], id: \.code) { voice in
                        Toggle(voice.displayName, isOn: binding(for: voice.code))
                    }
                } header: {
                    Text("Voice Packs")
                } footer: {
                    Text("Choose at least one. You can change voice packs later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    summary
                } footer: {
                    if immediateVerdict == .batchedOnly {
                        Text("There isn't room to install in one go, so MacGacha will install in parts. The game can't be played until it's done.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            // Longer translations push the secondary button onto its own row instead of truncating it.
            ViewThatFits(in: .horizontal) {
                HStack {
                    existingButton
                    Spacer()
                    sheetButtons
                }
                VStack(alignment: .trailing, spacing: 12) {
                    existingButton
                    HStack { sheetButtons }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            switch pickMode {
            case .location:
                location = folder.appendingPathComponent(game.defaultInstallDirectoryName, isDirectory: true)
            case .existing:
                guard !voices.isEmpty, !blocked else { return }
                model.adoptGame(game.id, folder: folder, voices: voices)
                dismiss()
            }
        }
        .confirmationDialog("Install in parts?", isPresented: $confirmingParts) {
            Button("Install in Parts") { start(approved: true) }
        } message: {
            Text("\(game.name) can't be played until the install finishes.")
        }
        .task(id: EstimateKey(location: location, voices: voices, attempt: attempt)) {
            check = .loading
            guard !voices.isEmpty else { return }
            // Toggling several voices quickly asks for one estimate, not one per click.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let value: GameEstimate
                #if DEBUG
                if UserDefaults.standard.string(forKey: "MacGachaDebugSpace") == "held" {
                    value = GameEstimate(download: 146_000_000_000, diskWhole: 151_000_000_000,
                        diskMinimum: 150_000_000_000, available: 88_000_000_000, purgeable: 221_000_000_000)
                } else {
                    value = try await model.estimate(game.id, voices: voices, at: location)
                }
                #else
                value = try await model.estimate(game.id, voices: voices, at: location)
                #endif
                if !Task.isCancelled { check = .ready(value) }
            } catch {
                guard !Task.isCancelled else { return }
                check = Self.failure(launcherError(error))
            }
        }
    }

    @ViewBuilder private var summary: some View {
        if let estimate {
            LabeledContent("Download", value: String(localized: "about \(ByteSize.text(estimate.download))", comment: "An estimated size"))
            LabeledContent("Needs on disk", value: String(localized: "about \(ByteSize.text(estimate.diskWhole))", comment: "An estimated size"))
            LabeledContent("Free on this volume") {
                if let available = estimate.available {
                    Text(ByteSize.text(available))
                        .foregroundStyle(verdict == .insufficient ? .red : .secondary)
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
            if case .heldByMacOS(let bytes) = verdict {
                PurgeableSpaceHint(bytes: bytes)
                Button("Check Again") { attempt += 1 }
            } else if verdict == .insufficient, let available = estimate.available {
                Label("Free up \(ByteSize.text(estimate.diskMinimum - available)) more to install.",
                    systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } else if voices.isEmpty {
            Text("Choose a voice pack to see the size.").foregroundStyle(.secondary)
        } else if case .failed(let reason, let retryable) = check {
            if retryable {
                HStack {
                    Label(reason, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { attempt += 1 }
                }
            } else {
                Text("Choose another location to see the size.").foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking size and free space…").foregroundStyle(.secondary)
            }
        }
    }

    private var existingButton: some View {
        Button("Use an Existing Installation…") { pickMode = .existing; picking = true }
            .disabled(voices.isEmpty || blocked)
            .help("Choose a folder that already has \(game.name). MacGacha checks it and downloads only what's missing.")
    }

    @ViewBuilder private var sheetButtons: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
        installButton
    }

    @ViewBuilder private var installButton: some View {
        if immediateVerdict == .batchedOnly {
            Button("Install in Parts…") { confirmingParts = true }
                .keyboardShortcut(.defaultAction)
                .disabled(blocked)
        } else {
            Button("Install") { start(approved: false) }
                .keyboardShortcut(.defaultAction)
                .disabled(immediateVerdict != .whole || blocked)
        }
    }

    private func start(approved: Bool) {
        // The estimate the user agreed to must still describe this location and these voices.
        guard !blocked, immediateVerdict == .whole || (approved && immediateVerdict == .batchedOnly) else { return }
        model.installGame(game.id, voices: voices, at: location, approved: approved)
        dismiss()
    }

    /// Location refusals are shown beside the location; network trouble offers a retry.
    private static func failure(_ error: LauncherError) -> SizeCheck {
        switch error {
        case .unsafePath:
            .failed(String(localized: "This folder can't be used: it overlaps another game or a protected location, or it's a link."), retryable: false)
        case .io(let detail) where detail.contains("not empty"):
            .failed(String(localized: "This folder isn't empty. Choose an empty folder, or use an existing installation."), retryable: false)
        case .http, .transport:
            .failed(String(localized: "Couldn't reach HoYoverse to check the size."), retryable: true)
        default:
            .failed(error.userMessage, retryable: true)
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { voices.contains(code) },
            set: { on in if on { voices.insert(code) } else { voices.remove(code) } }
        )
    }

    private struct EstimateKey: Hashable { let location: URL; let voices: Set<String>; let attempt: Int }
}

/// Add or remove voice packs for an installed game.
struct VoicePacksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: LauncherGame
    @State private var voices: Set<String> = []
    @State private var edited = false

    private var installed: Set<String> { model.installedVoices(game.id) }
    private var definition: GameDefinition? { GameDefinition.all.first { $0.id == game.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Voice Packs")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Form {
                Section {
                    ForEach(definition?.voices ?? [], id: \.code) { voice in
                        Toggle(isOn: binding(for: voice.code)) {
                            HStack {
                                Text(voice.displayName)
                                if installed.contains(voice.code) {
                                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Added packs are downloaded; removed ones free their space. Keep at least one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard !model.isGameOperationRunning else { return }
                    model.setVoices(game.id, voices)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(voices.isEmpty || voices == installed || model.isGameOperationRunning)
                .help(model.isGameOperationRunning ? Text("Wait for the current download to finish or pause it") : Text(verbatim: ""))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 440)
        .onAppear { voices = installed }
        // The record can arrive after the sheet opens; follow it until the user changes something.
        .onChange(of: installed) { _, now in if !edited { voices = now } }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { voices.contains(code) },
            set: { on in
                edited = true
                if on { voices.insert(code) } else { voices.remove(code) }
            }
        )
    }
}

extension VoiceOption {
    /// The voice's language in the UI language; `name` is GameLibrary's fixed English label.
    var displayName: String {
        switch code {
        case "zh-cn": String(localized: "Chinese", comment: "Voice pack language")
        case "en-us": String(localized: "English", comment: "Voice pack language")
        case "ja-jp": String(localized: "Japanese", comment: "Voice pack language")
        case "ko-kr": String(localized: "Korean", comment: "Voice pack language")
        default: name
        }
    }
}
