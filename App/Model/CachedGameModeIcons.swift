// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import HoYoPlayAPI

struct CachedGameModeIcons: GameModeIconProviding {
    private let cachedImage: @Sendable (GameDefinition) async -> Data?
    private let fallback: any GameModeIconProviding
    init(cacheDirectory: URL, fallback: any GameModeIconProviding = BundleGameModeIcons()) {
        self.cachedImage = { game in
            await GameArtService(cacheDirectory: cacheDirectory, region: game.region).cachedIcon(for: game.id)
        }
        self.fallback = fallback
    }
    init(cachedImage: @escaping @Sendable (GameDefinition) async -> Data?, fallback: any GameModeIconProviding) {
        self.cachedImage = cachedImage; self.fallback = fallback
    }
    func icon(for game: GameDefinition) async throws -> GameModeIcon {
        if let data = await cachedImage(game),
            let icon = try? await BlockingIO.run({ try GameModeIcon.fromImage(data) }) { return icon }
        return try await fallback.icon(for: game)
    }
}
