// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import HoYoPlayAPI
import SwiftUI

/// The current background's "Version Highlights" button, drawn from HoYoPlay's own images.
/// It appears only once its image has loaded, so it never belongs to a different slide.
struct HighlightsButton: View {
    let highlights: GameHighlights
    let images: ArtImageCache
    @State private var hovered = false

    var body: some View {
        if let link = highlights.link, let normal = images.image(highlights.image) {
            Button { NSWorkspace.shared.open(link) } label: {
                Image(nsImage: hovered ? images.image(highlights.hoverImage) ?? normal : normal)
                    .resizable()
                    .scaledToFit()
                    // HoYoPlay ships these at 2x, 80 pixels high.
                    .frame(height: 40)
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(Text("Version highlights"))
            .accessibilityHint(Text("Opens in your browser"))
        }
    }
}
