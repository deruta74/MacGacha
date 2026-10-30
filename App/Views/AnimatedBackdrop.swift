// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AVFoundation
import AppKit
import BackdropVideo
import SwiftUI

/// Plays HoYoPlay's animated background with MacGacha's own VP9 player on a GPU display layer.
/// It reports its state so the still image stays until the first frame is really on screen.
struct AnimatedBackdrop: NSViewRepresentable {
    let video: URL
    let paused: Bool
    let onState: @MainActor (BackdropVideoState) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        let coordinator = context.coordinator
        coordinator.onState = onState
        coordinator.player = BackdropVideoPlayer(layer: view.displayLayer) { [weak coordinator] url, state in
            // Only the source this view shows may report; a callback from a replaced video is ignored.
            guard let coordinator, coordinator.player?.sourceURL == url else { return }
            coordinator.onState?(state)
        }
        return view
    }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onState = onState
        guard let player = coordinator.player else { return }
        if player.sourceURL != video { player.play(video) }
        if paused { player.pause() } else { player.resume() }
    }

    static func dismantleNSView(_ view: VideoLayerView, coordinator: Coordinator) {
        coordinator.player?.stop()
        coordinator.player = nil
    }

    @MainActor final class Coordinator {
        var player: BackdropVideoPlayer?
        var onState: (@MainActor (BackdropVideoState) -> Void)?
    }

    /// A layer-hosting view whose layer is the player's display layer, filling like the stills.
    final class VideoLayerView: NSView {
        let displayLayer = AVSampleBufferDisplayLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            displayLayer.videoGravity = .resizeAspectFill
            displayLayer.backgroundColor = NSColor.clear.cgColor
            layer = displayLayer
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The window's background for one game: the selected video with its overlay once it plays,
/// otherwise the current still (crossfading between slides), otherwise the game's fallback tint.
struct GameBackdrop: View {
    let game: LauncherGame
    let art: GameArt?
    let video: BackgroundVideo?
    let slide: GameBackground?
    let images: ArtImageCache
    let crossfade: Bool
    let onPlayback: @MainActor (BackgroundPlaybackState, BackgroundVideoToken) -> Void

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [game.deepTint, game.deepTint.mix(with: .black, by: 0.5)], startPoint: .top, endPoint: .bottom)
            if let video {
                still(video.background)
                // The video and its overlay appear together as one layer, only once a frame is on
                // screen. The overlay stays mounted (decoded ahead of time) so it never lags the
                // video; the still stays underneath until then, and a failure falls back to stills.
                let showing = video.state == .playing
                ZStack {
                    AnimatedBackdrop(video: video.token.source.assetURL,
                        paused: activeState == .inactive || scenePhase != .active) { state in
                        switch state {
                        case .preparing: onPlayback(.preparing, video.token)
                        case .playing: onPlayback(.playing, video.token)
                        case .failed: onPlayback(.failed, video.token)
                        case .stopped: break
                        }
                    }
                    if let theme = images.image(video.background.theme ?? art?.theme) {
                        fill(theme)
                    }
                }
                .opacity(showing ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: showing)
                .allowsHitTesting(false)
            } else if let slide {
                still(slide)
            }
            // A scrim only behind the footer keeps the art clean while text stays legible.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .allowsHitTesting(false)
        }
        .animation(crossfade ? .easeInOut(duration: 0.8) : nil, value: slide?.id)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func still(_ background: GameBackground) -> some View {
        if let image = images.image(background.image) {
            fill(image)
                .id(background.id)
                .transition(.opacity)
        }
    }

    private func fill(_ image: NSImage) -> some View {
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }
}
