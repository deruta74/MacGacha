// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary

@MainActor extension AppModel {
    func unavailableVolumeName(for id: String) -> String? {
        guard case .locationUnavailable(let path) = games[id]?.status else { return nil }
        return GameLocation.volumeDisplayName(for: path)
    }

    func gameLocationHint(for id: String) -> String? {
        guard let name = unavailableVolumeName(for: id) else { return nil }
        return String(localized: "Connect the drive “\(name)” to play")
    }

    /// Views can offer Show in Finder only while the recorded location is available.
    func gameLocationURL(for id: String) -> URL? {
        guard let state = games[id] else { return nil }
        switch state.status {
        case .unknown, .notInstalled, .locationUnavailable: return nil
        default: return gameRecords[id]?.installPath
        }
    }

    func gameLocationPauseReason(for id: String) -> LauncherError? { gameLocationPauseReasons[id] }

    /// Recheck after preparation awaits, immediately before handing off to a service.
    /// PR 4's move entry point uses this same guard.
    func recheckGameLocation(_ id: String) async throws {
        do { try await gameServices.requireGameLocationAvailable(id) }
        catch LauncherError.installVolumeUnavailable {
            let record: GameRecord?
            if let cached = gameRecords[id] { record = cached }
            else { record = try? await gameServices.record(id) }
            if let record {
                setGameRecord(id, record)
                setGameState(id, GameState(status: .locationUnavailable(record.installPath)))
            }
            throw LauncherError.installVolumeUnavailable
        }
    }

    func receiveVolumeEvent(_ event: VolumeEvent) {
        let affected = GameDefinition.all.map(\.id).filter { id in
            guard let path = gameRecords[id]?.installPath else { return true }
            return Self.volumeEvent(event, affects: path)
        }
        for id in affected {
            gameRevisions[id] = UUID()
            if event.isUnmount, let path = gameRecords[id]?.installPath {
                var state = games[id] ?? GameState(status: .unknown)
                state.status = .locationUnavailable(path)
                setGameState(id, state)
            }
        }
        let active = gameOperation
        var operation: Task<Void, Never>?
        if event.isUnmount, let token = active {
            let path = token.installPath ?? gameRecords[token.id]?.installPath
            if path.map({ Self.volumeEvent(event, affects: $0) }) ?? (event.volume == nil) {
                operation = pauseForUnavailableVolume(token)
            }
        }
        let previous = volumeEventTask, services = gameServices, revisions = gameRevisions
        volumeEventTask = Task { [weak self] in
            await previous?.value
            if event.isUnmount { await operation?.value }
            for id in affected {
                guard !Task.isCancelled else { return }
                do {
                    guard let record = try await services.record(id), Self.volumeEvent(event, affects: record.installPath) else { continue }
                    // Broad discovery is safe for uncached records. Cancellation
                    // needs the captured destination or this verified record.
                    if event.isUnmount, let token = active, token.id == id, token.installPath == nil,
                        let self, self.gameOperation == token {
                        let consumer = self.pauseForUnavailableVolume(token)
                        await consumer?.value
                    }
                    let status = try await services.locationStatus(id)
                    guard let self, self.gameRevisions[id] == revisions[id] else { continue }
                    self.setGameRecord(id, record)
                    var state = self.games[id] ?? GameState(status: status)
                    state.status = status
                    self.setGameState(id, state)
                } catch { self?.show(error) }
            }
        }
    }

    private func pauseForUnavailableVolume(_ token: GameOperationToken) -> Task<Void, Never>? {
        guard gameOperation == token else { return nil }
        gameLocationPauseReasons[token.id] = .installVolumeUnavailable
        let consumer = gameTask
        consumer?.cancel()
        return consumer
    }

    private static func volumeEvent(_ event: VolumeEvent, affects path: URL) -> Bool {
        guard let url = event.volume else { return true }
        // Component-aware containment also supports nonstandard mount roots.
        let volume = GameLocation.volumeRoot(for: url) ?? url.standardizedFileURL
        let location = GameLocation.volumeRoot(for: path) ?? path.standardizedFileURL
        return location.pathComponents.starts(with: volume.pathComponents)
    }
}
