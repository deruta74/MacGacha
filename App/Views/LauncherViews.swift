// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import SwiftUI
import LauncherCore

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
    // CN-3 adds the picker; keep the visible rail Global-only meanwhile.
    static let all: [LauncherGame] = GameDefinition.inRegion(.global).map { definition in
        let name: String, tint: Color, deepTint: Color
        switch definition.family {
        case .genshin:
            name = String(localized: "Genshin Impact")
            tint = Color(red: 0.98, green: 0.78, blue: 0.46); deepTint = Color(red: 0.16, green: 0.22, blue: 0.38)
        case .starrail:
            name = String(localized: "Honkai: Star Rail")
            tint = Color(red: 0.69, green: 0.66, blue: 0.93); deepTint = Color(red: 0.10, green: 0.08, blue: 0.24)
        case .zzz:
            name = String(localized: "Zenless Zone Zero")
            tint = Color(red: 0.85, green: 0.93, blue: 0.30); deepTint = Color(red: 0.10, green: 0.10, blue: 0.10)
        }
        return LauncherGame(id: definition.id, name: name, tint: tint, deepTint: deepTint)
    }
    var defaultInstallDirectoryName: String {
        GameDefinition.find(id)?.defaultInstallDirectoryName ?? name
    }

}

// MARK: - Images

/// Decodes a cached image file off the main actor and fades it in when ready.
/// It always fills the space it's offered and never changes layout: an image's own size
/// must not push the window's controls around while art loads or games switch.
struct LocalImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
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
                LocalImage(url: url)
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
