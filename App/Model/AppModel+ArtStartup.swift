// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import HoYoPlayAPI
import LauncherCore

enum ArtCacheState: Sendable, Equatable {
    case notChecked, usable, none
}

@MainActor extension AppModel {
    /// Also called by start(). The window host may call this before mounting launcher content.
    /// The timeout owns only reveal; it never cancels the independent refresh task.
    func startArtStartup() {
        guard !artStartupBegan else { return }
        artStartupBegan = true
        startArtRevealTimeout(artClock)
        updateArtReveal()
        let initialRegion = region
        artStartupTask = Task { [weak self] in
            await self?.loadGameArt(in: initialRegion)
        }
    }

    func updateArtReveal() {
        guard artStartupBegan, !launcherRevealed else { return }
        if artCacheState == .usable || artRefreshFinished.contains(region) { revealLauncher() }
    }

    private func startArtRevealTimeout<C: Clock>(_ clock: C) where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .seconds(8))
        artRevealTask = Task { [weak self] in
            do { try await clock.sleep(until: deadline, tolerance: nil) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.revealLauncher()
        }
    }

    nonisolated static func hasUsableArt(_ art: [String: GameArt], in region: Region) async -> Bool {
        (try? await BlockingIO.run {
            for (id, game) in art where GameDefinition.find(id)?.region == region {
                let images = game.backgrounds.compactMap(\.image) + [game.background].compactMap { $0 }
                for image in images where image.isFileURL {
                    guard let fs = try? ContainedFileSystem(root: image.deletingLastPathComponent()),
                        let path = try? SafeRelativePath(image.lastPathComponent),
                        let size = try? fs.size(at: path), size > 0 else { continue }
                    return true
                }
            }
            return false
        }) ?? false
    }
}
