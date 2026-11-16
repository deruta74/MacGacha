// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore

@MainActor extension AppModel {
    var notificationsEnabled: Bool {
        get { globalLaunchSettings.notificationsEnabled }
        set { setGlobalLaunchPreference(\.notificationsEnabled, to: newValue) }
    }

    func openNotificationSettings() { notificationSettings() }

    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notifications.authorizationState()
    }

    func configureNotifications() {
        notifications.onResponse = { [weak self] id in
            guard let self, let game = GameDefinition.find(id) else { return }
            self.notificationSelection = GameNotificationSelection(gameID: id)
            self.region = game.region
            self.notificationReveal()
        }
        let center = activationCenter
        notificationActivationTask = Task { [weak self] in
            // Reading authorization never asks permission.
            await self?.refreshNotificationAuthorization()
            let activations = center.notifications(named: NSApplication.didBecomeActiveNotification).map { _ in true }
            for await _ in activations {
                guard !Task.isCancelled else { return }
                await self?.refreshNotificationAuthorization()
            }
        }
    }

    func notify(_ kind: GameNotificationKind, gameID: String, version: String? = nil) {
        guard notificationsEnabled, !notificationIsFrontmost(),
            let game = LauncherGame.all.first(where: { $0.id == gameID }) else { return }
        let marker: GameNotificationHistory.Marker?
        if kind.isAvailability {
            guard let version, !version.isEmpty, version.utf8.count <= 256 else { return }
            marker = .init(gameID: gameID, version: version, kind: kind)
        } else { marker = nil }
        let previous = notificationTask, history = notificationHistory
        notificationTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.notificationsEnabled, !self.notificationIsFrontmost(),
                marker.map(self.isCurrentAvailability) ?? true else { return }
            if let marker {
                do {
                    guard try await !history.contains(marker) else { return }
                } catch { return }
            }
            await self.refreshNotificationAuthorization()
            guard self.notificationsEnabled, !self.notificationIsFrontmost(),
                marker.map(self.isCurrentAvailability) ?? true else { return }
            if self.notificationAuthorization == .notDetermined {
                do {
                    self.notificationAuthorization = try await self.notifications.requestAuthorization() ? .allowed : .denied
                } catch { return }
            }
            guard !Task.isCancelled, self.notificationAuthorization == .allowed,
                self.notificationsEnabled, !self.notificationIsFrontmost(),
                marker.map(self.isCurrentAvailability) ?? true else { return }
            do {
                if let marker {
                    guard try await history.claim(marker) else { return }
                    guard !Task.isCancelled, self.notificationsEnabled, !self.notificationIsFrontmost(),
                        self.isCurrentAvailability(marker) else {
                        try await history.release(marker)
                        return
                    }
                }
                let notification = GameNotification(id: UUID().uuidString, gameID: gameID, kind: kind, title: kind.title, body: game.name)
                do { try await self.notifications.deliver(notification) }
                catch {
                    if let marker { try await history.release(marker) }
                }
            } catch { /* Best-effort notifications never interrupt game work. */ }
        }
    }

    private func isCurrentAvailability(_ marker: GameNotificationHistory.Marker) -> Bool {
        let id = marker.gameID
        guard GameDefinition.find(id) != nil, gameOperation?.id != id,
            games[id]?.activity == nil, gameRecords[id]?.pending == nil,
            gameRecords[id]?.uninstalling != true,
            gameRecords[id]?.installed?.tag != marker.version else { return false }
        let installed: String
        switch games[id]?.status {
        case .installed(let tag): installed = tag
        case .updateAvailable(let from, _): installed = from
        default: return false
        }
        guard installed != marker.version else { return false }
        if let recorded = gameRecords[id]?.installed?.tag, recorded != installed { return false }
        switch marker.kind {
        case .updateAvailable:
            if case .updateAvailable(_, let version) = games[id]?.status { return version == marker.version }
            return false
        case .preDownloadAvailable:
            guard let overlay = preDownloads[id], overlay.info.state == .available,
                overlay.info.version == marker.version else { return false }
            if case .available(let version, _) = overlay.state { return version == marker.version }
            return false
        default: return false
        }
    }

}
