// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import SwiftUI

/// The games MacGacha knows. Art is never bundled: it comes from the official
/// HoYoPlay API at run time and is cached locally (see `AppModel.gameArt`).
struct LauncherGame: Identifiable, Hashable {
    let id: String
    let name: String
    /// Fallback colors while art loads or when offline.
    let tint: Color
    let deepTint: Color
}

extension LauncherGame {
    static let all: [LauncherGame] = [
        LauncherGame(id: "genshin", name: "Genshin Impact", tint: Color(red: 0.98, green: 0.78, blue: 0.46), deepTint: Color(red: 0.16, green: 0.22, blue: 0.38)),
        LauncherGame(id: "starrail", name: "Honkai: Star Rail", tint: Color(red: 0.69, green: 0.66, blue: 0.93), deepTint: Color(red: 0.10, green: 0.08, blue: 0.24)),
        LauncherGame(id: "zzz", name: "Zenless Zone Zero", tint: Color(red: 0.85, green: 0.93, blue: 0.30), deepTint: Color(red: 0.10, green: 0.10, blue: 0.10)),
    ]
}

// MARK: - Images

/// Decodes a cached image file off the main actor and fades it in when ready.
struct LocalImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: url) { image = await Self.load(url) }
    }

    @concurrent private static func load(_ url: URL) async -> NSImage? {
        NSImage(contentsOf: url)
    }
}

// MARK: - Rail

struct GameRail: View {
    @Environment(AppModel.self) private var model
    @Binding var selectedID: String
    @Binding var panel: Panel?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(LauncherGame.all) { game in
                Button {
                    selectedID = game.id
                } label: {
                    GameIcon(game: game, art: model.gameArt[game.id], selected: game.id == selectedID)
                }
                .buttonStyle(.plain)
                .help(game.name)
                .accessibilityLabel(game.name)
                .accessibilityAddTraits(game.id == selectedID ? .isSelected : [])
            }
            Spacer(minLength: 24)
            RailButton(title: "Runtimes", symbol: "square.stack.3d.up") { panel = .runtimes }
            RailButton(title: "Diagnostics", symbol: "stethoscope") { panel = .diagnostics }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 14)
        .frame(width: 64)
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct GameIcon: View {
    let game: LauncherGame
    let art: GameArt?
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(game.tint.gradient)
            if let url = art?.icon {
                LocalImage(url: url).scaledToFill()
            } else {
                Text(game.name.prefix(1))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(game.deepTint)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(.rect(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white, lineWidth: selected ? 2 : 0)
                .padding(-3)
        }
        .opacity(selected ? 1 : 0.72)
        .scaleEffect(selected ? 1 : 0.94)
        .animation(.spring(response: 0.3, dampingFraction: 1), value: selected)
        .contentShape(.rect)
    }
}

private struct RailButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Footer

struct GameFooter: View {
    @Environment(AppModel.self) private var model
    let game: LauncherGame
    let art: GameArt?
    @Binding var panel: Panel?
    @Binding var animated: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            title
            Spacer(minLength: 24)
            VStack(alignment: .trailing, spacing: 10) {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                HStack(spacing: 10) {
                    if art?.videoPage != nil {
                        backgroundToggle
                    }
                    primaryButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Switches between the animated background and the static image.
    private var backgroundToggle: some View {
        Button {
            animated.toggle()
        } label: {
            Image(systemName: animated ? "photo" : "play.rectangle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .help(animated ? "Show a still background" : "Show the animated background")
        .accessibilityLabel(animated ? "Show a still background" : "Show the animated background")
    }

    /// HoYoPlay's art already carries the game's logo and event title, so the name
    /// is drawn only over the fallback tint.
    @ViewBuilder private var title: some View {
        if art?.background == nil {
            Text(game.name)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
        }
    }

    // Milestone 1 has no game installs yet; the button leads to what the user can do now.
    @ViewBuilder private var primaryButton: some View {
        if !model.runtimesReady {
            Button {
                panel = .runtimes
            } label: {
                Text("Set Up Runtimes").frame(minWidth: 180)
            }
            .buttonStyle(.glassProminent)
            .tint(game.tint)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
        } else {
            Button {} label: {
                Text("Coming Soon").frame(minWidth: 180)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .disabled(true)
            .help("\(game.name) installs arrive after its compatibility check")
        }
    }

    private var status: String {
        model.runtimesReady
            ? "Runtimes ready · Installs arrive after the compatibility check"
            : "Install the runtimes this game needs"
    }
}
