// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import HoYoPlayAPI
import LauncherCore

enum OtherRegionActivity: Sendable, Equatable {
    case downloading, updating, verifying, playing, restoring
}

@MainActor extension AppModel {
    var visibleGames: [LauncherGame] { LauncherGame.games(in: region) }
    var regionIsBeta: Bool { region == .mainlandChina }

    var otherRegionActivity: (game: LauncherGame, kind: OtherRegionActivity)? {
        if let id = launchSlotOwner, let game = LauncherGame.all.first(where: { $0.id == id }), game.region != region {
            let kind: OtherRegionActivity
            if knownEndedLaunchGames.contains(id) { kind = .restoring }
            else {
                switch launchStates[id] {
                case .recoveryNeeded, .starting(.restore): kind = .restoring
                default: kind = .playing
                }
            }
            return (game, kind)
        }
        if let operation = gameOperation, let game = LauncherGame.all.first(where: { $0.id == operation.id }), game.region != region {
            if case .working(.verifying, _, _, _, _) = games[game.id]?.activity { return (game, .verifying) }
            return (game, operation.kind)
        }
        return nil
    }

    static func persistedRegion(defaults: UserDefaults?, locale: Locale) -> Region {
        defaults?.string(forKey: "region").flatMap(Region.init(rawValue:))
            ?? (locale.region?.identifier == "CN" ? .mainlandChina : .global)
    }

    static func initialRegion(defaults: UserDefaults?, locale: Locale) -> Region {
        #if DEBUG
        switch defaults?.string(forKey: "MacGachaDebugRegion") {
        case "cn": return .mainlandChina
        case "global": return .global
        default: break
        }
        #endif
        return persistedRegion(defaults: defaults, locale: locale)
    }

    /// Independent region loads never own or cancel operation/launch tasks. A late
    /// response updates only its edition's cache, even after another selection.
    func loadRegion(_ region: Region) {
        guard regionLoadTasks[region] == nil else { return }
        regionLoadTasks[region] = Task { [weak self] in
            guard let self else { return }
            async let art: Void = self.loadGameArt(in: region)
            await self.refreshGames(in: region)
            await art
            self.regionLoadTasks[region] = nil
        }
    }

    func loadGameArt() async { await loadGameArt(in: region) }

    func loadGameArt(in region: Region) async {
        if let task = artTasks[region] { await task.value; return }
        guard let provider = artServices[region], !Task.isCancelled else { return }
        let hydration = hydrateGameArt()
        let task = Task { [weak self] in
            await hydration.value
            guard !Task.isCancelled else { return }
            let updated = await provider.refresh()
            if !Task.isCancelled { self?.applyArt(updated, in: region) }
        }
        artTasks[region] = task
        await task.value
        artTasks[region] = nil
    }

    private func hydrateGameArt() -> Task<Void, Never> {
        if let task = artHydrationTask { return task }
        let providers = artServices
        let task = Task { [weak self] in
            await withTaskGroup(of: (Region, [String: GameArt]).self) { group in
                for (region, provider) in providers {
                    group.addTask { (region, await provider.loadCached()) }
                }
                for await (region, cached) in group {
                    if !Task.isCancelled { self?.applyArt(cached, in: region) }
                }
            }
        }
        artHydrationTask = task
        return task
    }

}
