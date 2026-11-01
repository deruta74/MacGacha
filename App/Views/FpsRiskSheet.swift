// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

/// Shown once, the first time a Genshin frame-rate unlock is turned on. The confirm
/// button waits 10 seconds so the warning is read, not clicked through.
struct FpsRiskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let gameName: String
    let confirm: () -> Void

    @State private var remaining = 10

    private static let upstream = URL(string: "https://github.com/34736384/genshin-fps-unlock")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Unlock the frame rate in \(gameName)?", comment: "Warning title; the argument is the game's name")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("MacGacha loads a small helper into the game that only raises its frame-rate limit. It doesn't change game files or anything else in the game.")
                Text("Changing a running game goes against HoYoverse's Terms of Service and could lead to an account ban. The genshin-fps-unlock project, whose method this uses, says FPS-only use isn't banned, but MacGacha can't promise that.")
                Text("This warning appears only once. You can turn the unlock off at any time in the game's settings.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            Link("About genshin-fps-unlock", destination: Self.upstream)
                .font(.callout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirm()
                    dismiss()
                } label: {
                    if remaining > 0 {
                        Text("Turn On (\(remaining))", comment: "Confirm button while its countdown runs; the argument is seconds left")
                            .monospacedDigit()
                    } else {
                        Text("Turn On")
                    }
                }
                .disabled(remaining > 0)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
        }
    }
}

#Preview {
    FpsRiskSheet(gameName: "Genshin Impact") {}
}
