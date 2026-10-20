// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI
import WebKit

/// Plays HoYoPlay's animated background. The videos are VP9 WebM, which AVFoundation
/// can't open, so WebKit plays them; its decoder also runs in WebKit's sandboxed process.
/// The page is a fixed local template written by GameArtService: no JavaScript,
/// no navigation, and read access limited to the art cache.
struct AnimatedBackdrop: NSViewRepresentable {
    let page: URL
    let paused: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        load(page, in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != page {
            load(page, in: view, coordinator: context.coordinator)
        }
        view.setAllMediaPlaybackSuspended(paused)
    }

    private func load(_ page: URL, in view: WKWebView, coordinator: Coordinator) {
        coordinator.loaded = page
        coordinator.page = page
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        var page: URL?

        // Only the template itself may load; links or redirects never navigate the backdrop.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.request.url == page ? .allow : .cancel
        }
    }
}

/// The window's background for one game: the video with its overlay when animation is on
/// and available, otherwise the static image, otherwise the game's fallback tint.
struct GameBackdrop: View {
    let game: LauncherGame
    let art: GameArt?
    let animated: Bool

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [game.deepTint, game.deepTint.mix(with: .black, by: 0.5)], startPoint: .top, endPoint: .bottom)
            if let url = art?.background {
                LocalImage(url: url)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            if animated, let page = art?.videoPage {
                // The static image stays underneath, so there's no flash while the video starts.
                AnimatedBackdrop(page: page, paused: activeState == .inactive || scenePhase != .active)
                    .transition(.opacity)
                if let theme = art?.theme {
                    LocalImage(url: theme)
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            // A scrim only behind the footer keeps the art clean while text stays legible.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.3), value: animated)
        .accessibilityHidden(true)
    }
}
