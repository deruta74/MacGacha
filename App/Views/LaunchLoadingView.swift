// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import SwiftUI

/// Shown on a first launch while HoYoPlay's art arrives, at most a few seconds.
struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }
}
