// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

/// HoYoPlay's background picker: one dot per still, the current one ringed. The dots show
/// only while the pointer is over them. Pointing at them stops automatic switching,
/// clicking the current dot turns it back on.
struct BackgroundDots: View {
    let ids: [String]
    let current: String
    let onEnter: () -> Void
    let onSelect: (String) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                Button { onSelect(id) } label: { dot(selected: id == current) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Background \(index + 1) of \(ids.count)",
                        comment: "Accessibility label of a background picker dot; the arguments are its position and the count"))
                    .accessibilityAddTraits(id == current ? .isSelected : [])
            }
        }
        .opacity(hovered ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hovered)
        // A generous zone finds the dots before they appear; the shape keeps it hoverable while they're hidden.
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            // Entry only, so a click on the current dot can resume while the pointer is still here.
            if inside { onEnter() }
        }
    }

    private func dot(selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(selected ? 1 : 0.5))
                .frame(width: 8, height: 8)
            if selected {
                Circle()
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .shadow(color: .black.opacity(0.4), radius: 3)
    }
}
