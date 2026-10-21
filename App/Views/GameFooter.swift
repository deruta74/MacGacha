// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import DownloadEngine
import GameLibrary
import SwiftUI

/// Sheets that act on one game, opened from its footer.
enum GameSheet: Identifiable, Hashable {
    case install(String), voices(String)

    var id: String {
        switch self {
        case .install(let game): "install-\(game)"
        case .voices(let game): "voices-\(game)"
        }
    }
}

/// Bottom of the launcher: the game's status, its menu and the one action that matters now.
struct GameFooter: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    let art: GameArt?
    @Binding var panel: Panel?
    @Binding var gameSheet: GameSheet?
    @Binding var animated: Bool
    @State private var confirmingParts = false
    @State private var confirmingUninstall = false

    private var state: GameState { model.games[game.id] ?? GameState(status: .unknown) }
    private var action: PrimaryAction { .resolve(state, runtimesReady: model.runtimesReady) }

    var body: some View {
        HStack(alignment: .bottom) {
            title
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 10) {
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .contentTransition(.opacity)
                HStack(spacing: 10) {
                    if art?.videoPage != nil {
                        backgroundToggle
                    }
                    if showsMenu {
                        GameMenu(game: game, state: state, gameSheet: $gameSheet, confirmingUninstall: $confirmingUninstall)
                    }
                    PrimaryActionButton(game: game, action: action, state: state, panel: $panel,
                        gameSheet: $gameSheet, confirmingParts: $confirmingParts, confirmingUninstall: $confirmingUninstall)
                }
                // Every action fits this height, so switching states never moves the footer.
                .frame(height: 52)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.25), value: action)
        .confirmationDialog("Continue in parts?", isPresented: $confirmingParts) {
            Button("Continue in Parts") {
                // Another game may have started meanwhile; approving now would only fail as busy.
                guard !model.isGameOperationRunning else { return }
                model.approveBatches(game.id)
            }
        } message: {
            Text(partsMessage)
        }
        .confirmationDialog("Uninstall \(game.name)?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) {
                Task { await model.uninstallGame(game.id) }
            }
        } message: {
            Text(uninstallMessage)
        }
    }

    /// Switches between the animated background and the static image.
    private var backgroundToggle: some View {
        Button {
            animated.toggle()
        } label: {
            Image(systemName: animated ? "photo" : "play.rectangle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .help(animated ? "Show a still background" : "Show the animated background")
        .accessibilityLabel(animated ? "Show a still background" : "Show the animated background")
    }

    /// HoYoPlay's art already carries the game's logo and event title, so the name
    /// is drawn only over the fallback tint.
    @ViewBuilder private var title: some View {
        if art?.background == nil {
            Text(game.name)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
        }
    }

    private var showsMenu: Bool {
        switch state.activity {
        // Nothing in the menu can run while an operation is in flight.
        case .resolving, .working: return false
        // Waiting for approval is a pause: Show in Finder and Uninstall stay reachable.
        case .needsApproval: return true
        case nil: break
        }
        return switch state.status {
        case .installed, .updateAvailable, .paused: true
        default: false
        }
    }

    private var statusLine: String {
        if case .working(let phase, _, _, _, _) = state.activity {
            switch phase {
            case .committing, .deleting, .cleaningUp: return "Finishing up — this can't be paused"
            default: return "Keep MacGacha open — you can pause and resume any time"
            }
        }
        switch state.status {
        case .unknown: return "Checking for updates…"
        case .notInstalled: return "Not installed"
        case .installed(let tag): return "Version \(tag) · Installed"
        case .updateAvailable(let from, let to): return "Version \(from) · Version \(to) is available"
        case .paused: return "Paused"
        case .uninstallPaused: return "Uninstall didn't finish"
        case .locationUnavailable: return "Install location unavailable — connect the drive it's on"
        }
    }

    private var partsMessage: String {
        guard case .needsApproval(let required, let available) = state.activity else { return "" }
        return "This needs \(ByteSize.text(required)) at once, but only \(ByteSize.text(available)) is free. "
            + "MacGacha can finish it in parts instead. \(game.name) can't be played until it's done."
    }

    private var uninstallMessage: String {
        let record = model.gameRecord(game.id)
        var path = record?.installPath.path(percentEncoded: false) ?? "its folder"
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let paused: String
        switch state.status {
        case .paused: paused = "The paused operation is discarded. "
        case .uninstallPaused: paused = "This finishes the uninstall that was interrupted. "
        default: paused = ""
        }
        if record?.ownership == .adopted {
            return paused + "MacGacha removes the game files it manages from \(path). Other files in that folder are kept."
        }
        return paused + "The folder \(path) and everything in it will be removed."
    }
}

// MARK: - Primary action

/// The footer's big button. `PrimaryAction` decides what it is; this decides how it looks.
struct PrimaryActionButton: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    let action: PrimaryAction
    let state: GameState
    @Binding var panel: Panel?
    @Binding var gameSheet: GameSheet?
    @Binding var confirmingParts: Bool
    @Binding var confirmingUninstall: Bool

    /// Another game's operation holds the one slot; starting this one would only fail as busy.
    /// (This game's own running operation shows progress instead of a prominent button.)
    private var blocked: Bool { model.isGameOperationRunning }

    var body: some View {
        switch action {
        case .progress:
            progress
        case .preparing:
            waiting("Preparing…", spinner: true)
        case .install:
            prominent("Install") { gameSheet = .install(game.id) }
        case .resume:
            prominent("Resume") { model.resumeGame(game.id) }
        case .continueInParts:
            prominent("Continue in Parts…") { confirmingParts = true }
        case .finishUninstall:
            prominent("Finish Uninstall") { confirmingUninstall = true }
        case .update(let tag):
            prominent("Update to \(tag)") { model.updateGame(game.id) }
        case .setUpRuntimes:
            // Opening Runtimes doesn't compete with a game download.
            prominent("Set Up Runtimes", alwaysEnabled: true) { panel = .runtimes }
        case .locationUnavailable:
            waiting("Location Unavailable")
                .help(unavailablePath)
        case .playUnavailable:
            waiting("Play")
                .help("Launching arrives after the compatibility check")
        }
    }

    private func prominent(_ title: String, alwaysEnabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            // Game tints are light, so the label takes the game's dark tone for contrast.
            Text(title)
                .frame(minWidth: 180)
                .foregroundStyle(game.deepTint)
        }
        .buttonStyle(.glassProminent)
        .tint(game.tint)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(blocked && !alwaysEnabled)
        .help(blocked && !alwaysEnabled ? "Wait for the other game's download to finish or pause it" : "")
    }

    private func waiting(_ title: String, spinner: Bool = false) -> some View {
        Button {} label: {
            HStack(spacing: 8) {
                if spinner { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(minWidth: 180)
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .disabled(true)
    }

    private var progress: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progressLabel)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .tint(game.tint)
            .frame(width: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progressLabel)
            if canPause {
                Button {
                    model.pauseGame(game.id)
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Pause")
                .accessibilityLabel("Pause")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, canPause ? 8 : 18)
        .frame(height: 52)
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .capsule)
    }

    private var phase: OperationPhase? {
        if case .working(let phase, _, _, _, _) = state.activity { return phase }
        return nil
    }

    /// Replacing files, deleting and final cleanup always run to the end, as for runtimes.
    private var canPause: Bool {
        switch phase {
        case .committing, .deleting, .cleaningUp: false
        default: true
        }
    }

    private var fraction: Double? {
        if case .working(_, let fraction, _, _, _) = state.activity { return fraction }
        return nil
    }

    private var progressLabel: String {
        guard case .working(let phase, let fraction, let speed, let downloaded, let total) = state.activity else { return "" }
        var parts = [RuntimeRowView.label(for: phase, fraction: fraction)]
        if phase == .staging, let downloaded, let total, total > 0 {
            parts.append("\(ByteSize.number(downloaded, unitOf: total)) of \(ByteSize.text(total))")
        }
        if phase == .staging, let speed, speed > 0 { parts.append(ByteSize.text(speed) + "/s") }
        return parts.joined(separator: " · ")
    }

    private var unavailablePath: String {
        if case .locationUnavailable(let url) = state.status { return url.path(percentEncoded: false) }
        return ""
    }
}

// MARK: - Menu

/// Secondary actions for an installed or paused game.
struct GameMenu: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    let state: GameState
    @Binding var gameSheet: GameSheet?
    @Binding var confirmingUninstall: Bool

    /// While waiting for approval only folder actions make sense; verify and voices would start new work.
    private var waitingForApproval: Bool {
        if case .needsApproval = state.activity { return true }
        return false
    }

    var body: some View {
        Menu {
            if isInstalled, !waitingForApproval, !model.isGameOperationRunning {
                Button("Verify Files", systemImage: "checkmark.shield") { model.verifyGame(game.id) }
                Button("Voice Packs…", systemImage: "waveform") { gameSheet = .voices(game.id) }
            }
            if let folder = model.gameRecord(game.id)?.installPath {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            Divider()
            Button("Uninstall…", systemImage: "trash", role: .destructive) { confirmingUninstall = true }
                .disabled(model.isGameOperationRunning)
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .help("More for \(game.name)")
        .accessibilityLabel("More for \(game.name)")
    }

    private var isInstalled: Bool {
        switch state.status {
        case .installed, .updateAvailable: true
        default: false
        }
    }
}

/// File sizes as people read them: decimal units, like Finder.
enum ByteSize {
    static func text(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// The number part of `bytes` in the unit `reference` is shown in, so "18.3 of 136.5 GB"
    /// doesn't repeat the unit.
    static func number(_ bytes: Int64, unitOf reference: Int64) -> String {
        let units: [(Int64, String)] = [(1_000_000_000_000, "TB"), (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB")]
        guard let unit = units.first(where: { reference >= $0.0 }) else { return text(bytes) }
        let value = Double(bytes) / Double(unit.0)
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
