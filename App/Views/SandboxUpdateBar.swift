// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import DownloadEngine
import SwiftUI

/// A background Miliastra Sandbox update. Play stays the main action and stops this first,
/// so the capsule only reports progress and offers to stop it.
struct SandboxUpdateBar: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    let state: GameState

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
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
            if canStop {
                Button {
                    model.cancelAutomaticSandboxUpdate(game.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Stop. MacGacha tries again later.")
                .accessibilityLabel("Stop Miliastra Sandbox Update")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, canStop ? 6 : 14)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .foregroundStyle(.white)
    }

    private var label: String {
        model.sandboxPhaseLabel(for: game.id) ?? String(localized: "Updating Miliastra Sandbox…")
    }

    private var fraction: Double? {
        if case .working(_, let fraction, _, _, _) = state.activity { return fraction }
        return nil
    }

    private var amount: String? {
        guard case .working(_, _, _, let downloaded?, let total?) = state.activity, total > 0 else { return nil }
        return String(localized: "\(downloaded.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
    }

    /// Swapping the folders runs to the end, as for game updates.
    private var canStop: Bool {
        guard case .working(let phase, _, _, _, _) = state.activity else { return false }
        switch phase {
        case .committing, .deleting, .cleaningUp: return false
        default: return true
        }
    }
}
