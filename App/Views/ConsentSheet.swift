// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

struct ConsentSheet: View {
    @Environment(AppModel.self) private var model
    let request: ConsentRequest

    private static let gptkPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(request.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .background(.background.secondary, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            VStack(alignment: .leading, spacing: 6) {
                Link("Read Apple's license terms", destination: request.termsURL)
                if request.mode == .importGPTK {
                    Link("Get Game Porting Toolkit from Apple", destination: Self.gptkPage)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Decline", role: .cancel) { model.respondToConsent(accept: false) }
                    .keyboardShortcut(.cancelAction)
                Button(request.mode == .importGPTK ? String(localized: "Accept and Import") : String(localized: "Accept and Download")) {
                    model.respondToConsent(accept: true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}

#Preview("Download") {
    ConsentSheet(request: AppModel.previewConsent(mode: .download))
        .environment(AppModel.preview())
}

#Preview("Import") {
    ConsentSheet(request: AppModel.previewConsent(mode: .importGPTK))
        .environment(AppModel.preview())
}
