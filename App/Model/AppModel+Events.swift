// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import HoYoPlayAPI
import LauncherCore

@MainActor extension AppModel {
    func applyEvents(_ events: [String: GameEventsSnapshot], in region: Region) {
        eventsSnapshots[region] = events.filter { GameDefinition.find($0.key)?.region == region && $0.value.region == region }
        // An inactive region's late response must not reset the visible timer.
        if self.region == region { revalidateGameEvents() }
    }

    func hydrateGameEvents() -> Task<Void, Never> {
        if let task = eventsHydrationTask { return task }
        let providers = eventsServices
        let task = Task { [weak self] in
            await withTaskGroup(of: (Region, [String: GameEventsSnapshot]).self) { group in
                for (region, provider) in providers {
                    group.addTask { (region, await provider.loadCached()) }
                }
                for await (region, cached) in group {
                    if !Task.isCancelled { self?.applyEvents(cached, in: region) }
                }
            }
        }
        eventsHydrationTask = task
        return task
    }

    /// Normally invoked together with loadGameArt(); also available for an
    /// explicit Events retry. Only the selected/requested region is fetched.
    func loadGameEvents() async { await loadGameEvents(in: region) }

    func loadGameEvents(in region: Region) async {
        await beginGameEventsLoad(in: region)?.value
    }

    /// Art completion must not wait for Events: first-launch reveal belongs to
    /// the art refresh. This owned task publishes Events whenever they arrive.
    @discardableResult func beginGameEventsLoad(in region: Region) -> Task<Void, Never>? {
        if let task = eventsTasks[region] { return task }
        guard let provider = eventsServices[region], !Task.isCancelled else { return nil }
        let hydration = hydrateGameEvents()
        let task = Task { [weak self] in
            defer { self?.eventsTasks[region] = nil }
            await hydration.value
            guard !Task.isCancelled else { return }
            let updated = await provider.refresh()
            if !Task.isCancelled { self?.applyEvents(updated, in: region) }
        }
        eventsTasks[region] = task
        return task
    }

    func observeEventsWindowActivation() {
        let center = activationCenter
        eventsWindowTask = Task { [weak self] in
            let notifications = center.notifications(named: NSWindow.didBecomeKeyNotification).map { _ in true }
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                self?.revalidateGameEvents()
            }
        }
    }
}
