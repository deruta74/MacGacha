// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import DownloadEngine
import GameLibrary
import Launch
import LauncherCore
import SwiftUI

/// Sheets that act on one game, opened from its footer.
enum GameSheet: Identifiable, Hashable {
    case install(String), voices(String), settings(String)

    var id: String {
        switch self {
        case .install(let game): "install-\(game)"
        case .voices(let game): "voices-\(game)"
        case .settings(let game): "settings-\(game)"
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
    private var launch: LaunchUIState? { model.launchState(for: game.id) }
    private var action: PrimaryAction {
        .resolve(state, runtimesReady: model.runtimesReady, launch: launch, missingComponents: model.missingComponents(for: game.id))
    }

    var body: some View {
        HStack(alignment: .bottom) {
            title
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 10) {
                if let note = otherRegionNote {
                    OtherRegionNote(text: note.text) { model.region = note.region }
                }
                HStack(spacing: 8) {
                    Text(statusLine)
                        .contentTransition(.opacity)
                    if case .failed(let failure) = launch, failure.hasLog, model.sessionLogsEnabled {
                        Button("Open Log") { model.openLaunchLog(game.id) }
                            .buttonStyle(.link)
                            .underline()
                    }
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.4), radius: 3)
                if let held = state.spaceShortage?.heldByMacOS {
                    PurgeableSpaceHint(bytes: held)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: 480, alignment: .trailing)
                }
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
        .help(backgroundToggleLabel)
        .accessibilityLabel(backgroundToggleLabel)
    }

    // A ternary of two literals is a String, which SwiftUI shows verbatim, so each branch is a Text.
    private var backgroundToggleLabel: Text {
        animated ? Text("Show a still background") : Text("Show the animated background")
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
            case .committing, .deleting, .cleaningUp: return String(localized: "Finishing up — this can't be paused")
            default: return String(localized: "Keep MacGacha open — you can pause and resume any time")
            }
        }
        if let launchLine { return launchLine }
        // A disabled button shows no tooltip on macOS, so the reason it waits goes here.
        if let busy = busyElsewhere { return busy }
        switch state.status {
        case .unknown: return String(localized: "Checking for updates…")
        case .notInstalled: return String(localized: "Not installed")
        case .installed(let tag): return String(localized: "Version \(tag) · Installed", comment: "Game status; the argument is the game version")
        case .updateAvailable(let from, let to):
            return String(localized: "Version \(from) · Version \(to) is available", comment: "Game status: installed version, then the newer one")
        case .paused:
            return state.spaceShortage == nil ? String(localized: "Paused") : String(localized: "Paused — Not enough free disk space")
        case .uninstallPaused: return String(localized: "Uninstall didn't finish")
        case .locationUnavailable: return String(localized: "Install location unavailable — connect the drive it's on")
        }
    }

    /// What the launch is doing, or why it stopped. Nil when the game isn't launching or running.
    private var launchLine: String? {
        switch launch {
        case .starting(let stage):
            switch stage {
            case .preflight, .lock, .snapshot: return String(localized: "Checking \(game.name)…", comment: "Launch status; the argument is the game's name")
            case .prepare: return String(localized: "Preparing Wine…")
            case .proxy, .spawn: return String(localized: "Starting \(game.name)…", comment: "Launch status; the argument is the game's name")
            case .watch: return String(localized: "Waiting for the game window…")
            case .restore, .report: return String(localized: "Restoring game files…")
            }
        case .running, .ready:
            return String(localized: "Keep MacGacha open while you play — it restores the game's files when you quit")
        case .failed(let failure):
            let line = failureLine(failure)
            return failure.unverifiedBuild
                ? StatusText.joined(line, String(localized: "This game version hasn't been tested with MacGacha yet"))
                : line
        case .recoveryNeeded(let reason): return reason
        case nil:
            guard let other = playingElsewhere else { return nil }
            if case .recoveryNeeded = model.launchState(for: other.id) {
                return String(localized: "Waiting for \(other.name) to put its files back", comment: "The argument is another game's name")
            }
            return String(localized: "\(other.name) is running — quit it to play this one", comment: "The argument is another game's name")
        }
    }

    /// Names the step that failed in plain words. Checks and locks already carry a message meant for people.
    private func failureLine(_ failure: LaunchFailureInfo) -> String {
        switch failure.stage {
        case .preflight, .lock: failure.message
        case .watch: String(localized: "\(game.name) closed during startup", comment: "The argument is the game's name")
        case .prepare, .snapshot: String(localized: "Couldn't prepare Wine for \(game.name)", comment: "The argument is the game's name")
        case .proxy: String(localized: "Couldn't start the network helper for \(game.name)", comment: "The argument is the game's name")
        case .spawn, .restore, .report: String(localized: "\(game.name) couldn't start", comment: "The argument is the game's name")
        }
    }

    /// The status line already names the other region's game; this offers the way to it.
    private var otherRegionNote: (text: String, region: Region)? {
        guard let other = model.otherRegionActivity?.game else { return nil }
        let text = other.region == .mainlandChina
            ? String(localized: "Switch to Mainland China") : String(localized: "Switch to Global")
        return (text, other.region)
    }

    /// Only one game runs at a time, from pressing Play until its files are back.
    private var playingElsewhere: LauncherGame? {
        guard let owner = model.launchSlotOwner, owner != game.id else { return nil }
        return LauncherGame.all.first { $0.id == owner }
    }

    /// Set while another game holds the one operation slot and this game is idle.
    private var busyElsewhere: String? {
        guard model.isGameOperationRunning, state.activity == nil else { return nil }
        let other = LauncherGame.all.first { $0.id != game.id && model.games[$0.id]?.activity != nil }
        guard let other, case .working(let phase, _, _, _, _) = model.games[other.id]?.activity else {
            return String(localized: "Another game is busy — this one can start when it finishes")
        }
        return phase == .staging
            ? String(localized: "\(other.name) is downloading — pause it to start this one", comment: "The argument is another game's name")
            : String(localized: "Waiting for \(other.name) to finish", comment: "The argument is another game's name")
    }

    private var partsMessage: String {
        guard case .needsApproval(let required, let available) = state.activity else { return "" }
        return String(localized: """
            This needs \(ByteSize.text(required)) at once, but only \(ByteSize.text(available)) is free. \
            MacGacha can finish it in parts instead. \(game.name) can't be played until it's done.
            """, comment: "Sizes needed and free, then the game's name")
    }

    private var uninstallMessage: String {
        let record = model.gameRecord(game.id)
        var path = record?.installPath.path(percentEncoded: false) ?? String(localized: "its folder", comment: "Stands in for a folder path")
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let removal = record?.ownership == .adopted
            ? String(localized: "MacGacha removes the game files it manages from \(path). Other files in that folder are kept.",
                comment: "The argument is the game's folder")
            : String(localized: "The folder \(path) and everything in it will be removed.", comment: "The argument is the game's folder")
        switch state.status {
        case .paused:
            return String(localized: "The paused operation is discarded. \(removal)", comment: "The argument is the sentence about what is removed")
        case .uninstallPaused:
            return String(localized: "This finishes the uninstall that was interrupted. \(removal)",
                comment: "The argument is the sentence about what is removed")
        default: return removal
        }
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

    /// Another game holds the one launch slot, from pressing Play until its files are back.
    private var playingElsewhere: Bool {
        model.launchSlotOwner.map { $0 != game.id } ?? false
    }

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
        case .play:
            prominent("Play", alwaysEnabled: true) { model.play(game.id) }
                .disabled(playingElsewhere)
        case .launching:
            launching
        case .playing:
            waiting("Playing", symbol: "gamecontroller.fill")
        case .recoveryNeeded:
            waiting("Restoring Files…", spinner: true)
        }
    }

    /// The circle buttons beside it use a 44-point label at the regular control size; matching both
    /// gives every footer control one height.
    private let labelHeight: CGFloat = 44

    private func prominent(_ title: LocalizedStringKey, alwaysEnabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            // Game tints are light, so the label takes the game's dark tone for contrast.
            Text(title)
                .frame(minWidth: 180, minHeight: labelHeight)
                .foregroundStyle(game.deepTint)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(game.tint)
        .font(.title3)
        .keyboardShortcut(.defaultAction)
        .disabled(blocked && !alwaysEnabled)
        .help(blocked && !alwaysEnabled ? Text("Wait for the other game's download to finish or pause it") : Text(verbatim: ""))
    }

    private func waiting(_ title: LocalizedStringKey, spinner: Bool = false, symbol: String? = nil) -> some View {
        Button {} label: {
            HStack(spacing: 8) {
                if spinner { ProgressView().controlSize(.small) }
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title)
            }
            .frame(minWidth: 180, minHeight: labelHeight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .font(.title3)
        .disabled(true)
    }

    private var progress: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(progressLabel)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    // The capsule grows with the label instead of truncating the speed.
                    .fixedSize(horizontal: true, vertical: false)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .tint(game.tint)
            .frame(minWidth: 300, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
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

    /// Starting has no meaningful fraction, so the bar runs indeterminate in the progress capsule's place.
    private var launching: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Starting…")
                .font(.callout.weight(.medium))
            ProgressView().progressViewStyle(.linear)
        }
        .tint(game.tint)
        .frame(width: 300, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting…")
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
        var label = RuntimeRowView.label(for: phase, fraction: fraction)
        if phase == .staging, let downloaded, let total, total > 0 {
            let amount = String(localized: "\(ByteSize.number(downloaded, unitOf: total)) of \(ByteSize.text(total))",
                comment: "Downloaded so far of the total, e.g. 18.3 of 136.5 GB")
            label = StatusText.joined(label, amount)
        }
        if phase == .staging, let speed, speed > 0 {
            label = StatusText.joined(label, String(localized: "\(ByteSize.text(speed))/s", comment: "Download speed, e.g. 47 MB/s"))
        }
        return label
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
            if case .recoveryNeeded = model.launchState(for: game.id) {
                Button("Try Restoring Again", systemImage: "arrow.clockwise") { model.retryRecovery(game.id) }
            }
            if isInstalled {
                Button("Game Settings…", systemImage: "slider.horizontal.3") { gameSheet = .settings(game.id) }
            }
            if isInstalled, !waitingForApproval, !model.isGameOperationRunning, !isLive {
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
                .disabled(model.isGameOperationRunning || isLive)
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

    /// The game is launching, running or still being restored; its files must stay put.
    private var isLive: Bool {
        switch model.launchState(for: game.id) {
        case .starting, .running, .ready, .recoveryNeeded: true
        case .failed, nil: false
        }
    }

    private var isInstalled: Bool {
        switch state.status {
        case .installed, .updateAvailable: true
        default: false
        }
    }
}

/// Status lines built from parts read as one localized phrase each, never as fragments.
enum StatusText {
    static func joined(_ first: String, _ second: String) -> String {
        String(localized: "\(first) · \(second)", comment: "Joins two parts of a status line")
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

/// A small button to the region whose game is downloading or running.
struct OtherRegionNote: View {
    let text: String
    let show: () -> Void

    var body: some View {
        Button(action: show) {
            Label(text, systemImage: "globe.asia.australia")
                .font(.callout)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .foregroundStyle(.white)
    }
}
