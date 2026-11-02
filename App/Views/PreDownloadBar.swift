// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

/// The next version's pre-download, a smaller capsule above the primary action.
/// It never replaces Play: the installed version stays playable throughout.
struct PreDownloadBar: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    /// A running or starting game holds the session, so a new transfer can't start.
    let gameIsLive: Bool

    private var overlay: PreDownloadOverlay { model.preDownloadState(for: game.id) }
    /// A paused install or update owns the game until it finishes, so a transfer can't start or resume.
    private var blocked: Bool {
        model.isGameOperationRunning || gameIsLive || model.gameRecord(game.id)?.pending != nil
    }

    var body: some View {
        Group {
            switch overlay.state {
            case .unavailable:
                EmptyView()
            case .available(let version, let bytes):
                Button {
                    model.startPreDownload(game.id)
                } label: {
                    Label(String(localized: "Pre-download \(version) · \(bytes.formatted(.byteCount(style: .file)))",
                        comment: "Footer button; the next game version and its download size"),
                        systemImage: "arrow.down.circle")
                        .font(.callout)
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .disabled(blocked)
            case .downloading(let progress):
                transfer(label: String(localized: "Pre-downloading \(version)…",
                        comment: "Footer pre-download progress; the argument is the next game version"),
                    downloaded: progress.downloaded, total: progress.total,
                    fraction: progress.isResolving ? nil : progress.fraction, paused: false)
            case .paused:
                transfer(label: String(localized: "Pre-download paused"), downloaded: overlay.info.downloaded,
                    total: overlay.info.bytes, fraction: pausedFraction, paused: true)
            case .ready(let version):
                Label(String(localized: "\(version) pre-downloaded",
                    comment: "Footer note after a finished pre-download; the argument is the next game version"),
                    systemImage: "checkmark.circle")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassEffect(.regular, in: .capsule)
                    .help("The update installs these files when the new version is released.")
            }
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.25), value: overlay.state)
    }

    private var version: String { overlay.info.version ?? "" }

    private var pausedFraction: Double? {
        let info = overlay.info
        return info.bytes > 0 ? min(1, Double(info.downloaded) / Double(info.bytes)) : nil
    }

    private func transfer(label: String, downloaded: Int64, total: Int64, fraction: Double?, paused: Bool) -> some View {
        let amount = total > 0
            ? String(localized: "\(downloaded.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
            : nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // Long translations move the amount under the label instead of truncating either.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(label).fontWeight(.medium)
                        Spacer(minLength: 12)
                        if let amount { Text(amount).foregroundStyle(.white.opacity(0.75)) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).fontWeight(.medium)
                        if let amount { Text(amount).foregroundStyle(.white.opacity(0.75)) }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .tint(game.tint)
            .frame(width: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(amount.map { StatusText.joined(label, $0) } ?? label)
            Button {
                if paused { model.resumePreDownload(game.id) } else { model.pausePreDownload(game.id) }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.caption)
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            // Resuming needs the same free session and lease as starting.
            .disabled(paused && blocked)
            .help(paused ? Text("Resume Pre-download") : Text("Pause Pre-download"))
            .accessibilityLabel(paused ? Text("Resume Pre-download") : Text("Pause Pre-download"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .glassEffect(.regular, in: .capsule)
    }
}
