// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import HoYoPlayAPI
import SwiftUI

/// HoYoPlay's events for the game, bottom left: each title with its date, opening the post in the browser.
struct EventsPanel: View {
    let events: [GameEvent]
    /// HoYoPlay shows a short list; the rest are a click away on the game's site.
    private static let visible = 3

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Events")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .accessibilityAddTraits(.isHeader)
                // Posts have no stable id, and titles can repeat, so rows are keyed by position.
                ForEach(Array(events.prefix(Self.visible).enumerated()), id: \.offset) { _, event in
                    EventRow(event: event)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: 380, alignment: .leading)
            .background(.black.opacity(0.35), in: .rect(cornerRadius: 14))
        }
    }
}

private struct EventRow: View {
    let event: GameEvent
    @State private var hovered = false

    var body: some View {
        let row = HStack(spacing: 12) {
            Text(event.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: event.date)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(hovered ? 0.12 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .help(event.title)

        if let link = event.link {
            Button { NSWorkspace.shared.open(link) } label: { row }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityHint(Text("Opens in your browser"))
        } else {
            row
        }
    }
}
