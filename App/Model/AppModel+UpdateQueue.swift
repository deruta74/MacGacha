// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import LauncherCore
import GameLibrary

@MainActor extension AppModel {
    var keepsUpdateQueueRunning: Bool {
        updateQueue.enabled && (!updateQueue.entries.isEmpty || (updateQueue.automatic && !updateQueue.automaticGames.isEmpty))
    }

    func saveUpdateQueue(_ edit: (inout UpdateQueue) -> Void) {
        let wasAutomatic = updateQueue.automatic, previousGames = updateQueue.automaticGames
        edit(&updateQueue)
        if updateQueue.automatic && (!wasAutomatic || updateQueue.automaticGames != previousGames) { updateQueue.lastDiscovery = nil }
        let removed = updateQueue.entries.filter { $0.automatic && (!updateQueue.automatic || !updateQueue.automaticGames.contains($0.id)) }.map(\.id)
        updateQueue.entries.removeAll { removed.contains($0.id) }
        for id in removed {
            if pausedDownloadForPlay?.token.id == id, pausedDownloadForPlay?.token.isQueuedUpdate == true { cancelPlayDownloadResume(for: id) }
        }
        persistUpdateQueue()
        updateQueueTimer?.cancel(); updateQueueTimer = nil
        startUpdateQueueMonitoring()
        evaluateUpdateQueue()
    }

    func enqueueUpdate(_ id: String) {
        guard GameDefinition.find(id) != nil, gameRecords[id]?.installed != nil,
            gameRecords[id]?.pending == nil, gameRecords[id]?.uninstalling != true,
            !updateQueue.entries.contains(where: { $0.id == id }) else { return }
        saveUpdateQueue { $0.entries.append(.init(id: id, source: gameRecords[id])) }
    }

    func removeQueuedUpdate(_ id: String) {
        saveUpdateQueue { $0.entries.removeAll { $0.id == id } }
        if gameOperation?.id == id, gameOperation?.isQueuedUpdate == true { gameTask?.cancel() }
        if pausedDownloadForPlay?.token.id == id, pausedDownloadForPlay?.token.isQueuedUpdate == true {
            cancelPlayDownloadResume(for: id)
        }
    }

    func moveQueuedUpdate(_ id: String, before target: String) {
        saveUpdateQueue { queue in
            guard id != target, let from = queue.entries.firstIndex(where: { $0.id == id }),
                queue.entries.contains(where: { $0.id == target }) else { return }
            let entry = queue.entries.remove(at: from)
            if let to = queue.entries.firstIndex(where: { $0.id == target }) { queue.entries.insert(entry, at: to) }
        }
    }

    var updateQueueWaitingReason: String? {
        guard keepsUpdateQueueRunning else { return nil }
        let signals = (updateQueueNetworkAllowed, updateQueueOnAC, updateQueueIdleSeconds)
        let needsIdle = updateQueue.requiresIdle || nextQueuedUpdate?.automatic == true || (nextQueuedUpdate == nil && updateQueue.automatic)
        if !signals.0 { return String(localized: "Waiting for a connection without Low Data Mode.") }
        if updateQueue.requiresAC && signals.1 != true { return String(localized: "Waiting for AC power.") }
        if !updateQueue.permits(at: eventsNow(), onAC: signals.1) { return String(localized: "Waiting for scheduled hours.") }
        if needsIdle && signals.2 < Double(max(1, updateQueue.idleMinutes) * 60) {
            return String(localized: "Waiting for idle time.")
        }
        return nil
    }

    func moveQueuedUpdate(_ id: String, by offset: Int) {
        saveUpdateQueue { queue in
            guard let index = queue.entries.firstIndex(where: { $0.id == id }), queue.entries.indices.contains(index + offset) else { return }
            queue.entries.swapAt(index, index + offset)
        }
    }

    func retryQueuedUpdate(_ id: String) {
        saveUpdateQueue { queue in
            guard let index = queue.entries.firstIndex(where: { $0.id == id }) else { return }
            queue.entries[index].paused = false
        }
    }

    func manuallyPauseQueuedUpdate(_ id: String) {
        guard updateQueue.entries.contains(where: { $0.id == id }) else { return }
        saveUpdateQueue { queue in
            if let index = queue.entries.firstIndex(where: { $0.id == id }) { queue.entries[index].paused = true }
        }
    }

    func persistUpdateQueue() {
        if let data = try? JSONEncoder().encode(updateQueue) { defaults?.set(data, forKey: "updateQueue.v1") }
    }

    func startUpdateQueueMonitoring() {
        guard startupFinished, keepsUpdateQueueRunning else {
            if !keepsUpdateQueueRunning {
                updateQueueTimer?.cancel(); updateQueueTimer = nil
                updateQueueEnvironment.stop()
            }
            return
        }
        updateQueueEnvironment.start { [weak self] in self?.refreshUpdateQueueEnvironment() }
        guard updateQueueTimer == nil else { return }
        let delay = nextUpdateQueueDelay()
        updateQueueTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.updateQueueTimer = nil
            self.evaluateUpdateQueue()
            self.startUpdateQueueMonitoring()
        }
    }

    func refreshUpdateQueueEnvironment() {
        updateQueueTimer?.cancel(); updateQueueTimer = nil
        evaluateUpdateQueue()
        startUpdateQueueMonitoring()
    }

    func queueEnvironmentPermits(automatic: Bool) -> Bool {
        let signals = updateQueueSignals?() ?? (updateQueueEnvironment.permitsNetwork, updateQueueEnvironment.onAC, updateQueueEnvironment.idleSeconds)
        guard signals.0,
            updateQueue.permits(at: eventsNow(), onAC: signals.1) else { return false }
        if updateQueue.requiresIdle || automatic {
            guard signals.2 >= Double(max(1, updateQueue.idleMinutes) * 60) else { return false }
        }
        if automatic {
            guard updateQueue.automatic, launchSlotOwner == nil, launchTasks.isEmpty, liveLaunchGames.isEmpty,
                !launchStates.values.contains(where: {
                    switch $0 { case .starting, .running, .ready, .recoveryNeeded: true; default: false }
                }) else { return false }
        }
        return true
    }

    func queuedPlayContinuationPermitted(_ token: GameOperationToken) -> Bool {
        guard token.isQueuedUpdate else { return true }
        guard let entry = updateQueue.entries.first(where: { $0.id == token.id }), !entry.paused else { return false }
        return (!entry.automatic || updateQueue.automaticGames.contains(entry.id)) && queueEnvironmentPermits(automatic: entry.automatic)
    }

    func evaluateUpdateQueue() {
        guard startupFinished else { return }
        let signals = updateQueueSignals?() ?? (updateQueueEnvironment.permitsNetwork, updateQueueEnvironment.onAC, updateQueueEnvironment.idleSeconds)
        updateQueueNetworkAllowed = signals.0
        updateQueueOnAC = signals.1
        updateQueueIdleSeconds = signals.2
        watchUpdateQueueReservations()
        if !queueEnvironmentPermits(automatic: updateQueueTaskIsAutomatic) { updateQueueTask?.cancel() }
        if let token = gameOperation, token.isQueuedUpdate {
            if !queuedPlayContinuationPermitted(token) { gameTask?.cancel() }
            return
        }
        guard updateQueueTask == nil, gameOperation == nil, !isStarting,
            languageRestart == nil, !updater.isInstallingUpdate,
            !storageCleanupInProgress, prefixResetGame == nil, !gameMoveRecoveryReservation,
            runtimeCatalogMutationID == nil, !isRuntimeOperationRunning,
            launchStartupError == nil else { return }
        if let saved = pausedDownloadForPlay, saved.token.isQueuedUpdate {
            if updateQueue.entries.first(where: { $0.id == saved.token.id })?.paused != false {
                // Batch approval may race Play's pause. Keep the entry's exact
                // saved plan, but do not let its held continuation block others.
                cancelPlayDownloadResume(for: saved.token.id)
            } else {
                if queuedPlayContinuationPermitted(saved.token) { resumeDownloadAfterPlayIfPossible() }
                return
            }
        }
        if let entry = nextQueuedUpdate {
            guard queueEnvironmentPermits(automatic: entry.automatic),
                canOperateGameDuringPlay(entry.id, isDownload: true), gameUpdateCheckTasks[entry.id] == nil else { return }
            updateQueueTaskIsAutomatic = entry.automatic
            updateQueueTask = Task { [weak self] in
                guard let self else { return }
                defer { self.updateQueueTask = nil; self.refreshUpdateQueueEnvironment() }
                do {
                    try await self.gameServices.waitUntilIdle(entry.id)
                    let record = try await self.gameServices.record(entry.id)
                    try Task.checkCancellation()
                    guard self.nextQueuedUpdate == entry, self.queueEnvironmentPermits(automatic: entry.automatic),
                        self.gameOperation == nil, self.canOperateGameDuringPlay(entry.id, isDownload: true) else { return }
                    guard record?.installed != nil, record?.uninstalling == false else {
                        self.holdQueuedUpdate(entry.id); return
                    }
                    self.setGameRecord(entry.id, record)
                    if let pending = record?.pending {
                        guard entry.pending == pending, pending.kind == .update,
                            record?.installIdentity == entry.source?.installIdentity,
                            record?.installPath == entry.source?.installPath else { self.holdQueuedUpdate(entry.id); return }
                        self.beginQueuedGame(entry.id, pending: pending)
                    } else {
                        guard record?.installIdentity == entry.source?.installIdentity,
                            record?.installPath == entry.source?.installPath,
                            record?.installed == entry.source?.installed else { self.holdQueuedUpdate(entry.id); return }
                        let status = try await self.gameServices.checkForUpdate(entry.id)
                        try Task.checkCancellation()
                        guard self.nextQueuedUpdate == entry,
                            self.queueEnvironmentPermits(automatic: entry.automatic), self.gameOperation == nil else { return }
                        if case .updateAvailable = status { self.beginQueuedGame(entry.id, initial: .init(request: .update, record: record)) }
                        else if case .installed = status { self.removeQueuedUpdate(entry.id) }
                        else { self.holdQueuedUpdate(entry.id) }
                    }
                } catch {
                    if !Task.isCancelled { self.holdQueuedUpdate(entry.id); self.show(error) }
                }
            }
        } else {
            discoverQueuedUpdatesIfNeeded()
        }
    }

    private func holdQueuedUpdate(_ id: String) {
        if let index = updateQueue.entries.firstIndex(where: { $0.id == id }) { updateQueue.entries[index].paused = true }
        persistUpdateQueue()
    }

    func queuedUpdateRecordChanged(_ id: String, record: GameRecord?) {
        guard gameOperation?.id == id, gameOperation?.isQueuedUpdate == true,
            let index = updateQueue.entries.firstIndex(where: { $0.id == id }) else { return }
        updateQueue.entries[index].pending = record?.pending
        updateQueue.entries[index].planID = record?.pending?.planID.rawValue
        persistUpdateQueue()
    }

    func queuedUpdateFinished(_ token: GameOperationToken, outcome: GameConsumerOutcome) {
        guard token.isQueuedUpdate, let index = updateQueue.entries.firstIndex(where: { $0.id == token.id }) else { return }
        switch outcome {
        case .completed: updateQueue.entries.remove(at: index)
        case .failed: updateQueue.entries[index].paused = true
        case .stopped:
            // Approval and non-resumable stops require the user; schedule/Play pauses keep exact ownership.
            if case .needsApproval = games[token.id]?.activity { updateQueue.entries[index].paused = true }
        }
        persistUpdateQueue()
        Task { [weak self] in
            await Task.yield()
            self?.refreshUpdateQueueEnvironment()
        }
    }

    private var nextQueuedUpdate: UpdateQueue.Entry? {
        updateQueue.entries.first { !$0.paused }
    }

    private func watchUpdateQueueReservations() {
        guard keepsUpdateQueueRunning, updateQueueWatchID == nil else { return }
        let generation = UUID()
        updateQueueWatchID = generation
        withObservationTracking {
            _ = isStarting; _ = gameOperation; _ = launchSlotOwner; _ = launchTasks; _ = liveLaunchGames; _ = launchStates
            _ = languageRestart; _ = storageCleanupInProgress; _ = prefixResetGame
            _ = gameMoveRecoveryReservation; _ = runtimeCatalogMutationID; _ = isRuntimeOperationRunning
            _ = globalLaunchSettings; _ = updater.isInstallingUpdate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.updateQueueWatchID == generation else { return }
                self.updateQueueWatchID = nil
                self.refreshUpdateQueueEnvironment()
            }
        }
    }

    /// No UI polling: sleep to the next wall-clock/discovery deadline where possible.
    func nextUpdateQueueDelay() -> TimeInterval {
        let date = eventsNow(), calendar = Calendar.current
        if gameOperation?.isQueuedUpdate == true {
            if updateQueue.scheduled {
                let end = DateComponents(hour: updateQueue.endMinute / 60, minute: updateQueue.endMinute % 60)
                if let boundary = calendar.nextDate(after: date, matching: end, matchingPolicy: .nextTime) {
                    return max(1, min(30, boundary.timeIntervalSince(date)))
                }
            }
            return 30
        }
        if !updateQueueNetworkAllowed || (updateQueue.requiresAC && updateQueueOnAC != true) { return 3600 }
        if nextQueuedUpdate == nil, !updateQueue.automatic { return 3600 }
        if updateQueue.scheduled, !updateQueue.permits(at: date, onAC: true), updateQueue.enabled {
            let parts = DateComponents(hour: updateQueue.startMinute / 60, minute: updateQueue.startMinute % 60)
            if let next = calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) {
                return max(1, date.distance(to: next))
            }
        }
        if nextQueuedUpdate == nil, let checked = updateQueue.lastDiscovery {
            return max(30, min(6 * 3600, checked.addingTimeInterval(6 * 3600).timeIntervalSince(date)))
        }
        return 30
    }

    private func discoverQueuedUpdatesIfNeeded() {
        guard updateQueue.automatic, !updateQueue.automaticGames.isEmpty,
            queueEnvironmentPermits(automatic: true),
            updateQueue.lastDiscovery.map({ eventsNow().timeIntervalSince($0) >= 6 * 3600 }) ?? true else { return }
        let chosen = updateQueue.automaticGames
        updateQueue.lastDiscovery = eventsNow(); persistUpdateQueue()
        updateQueueTaskIsAutomatic = true
        updateQueueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if Task.isCancelled { self.updateQueue.lastDiscovery = nil; self.persistUpdateQueue() }
                self.updateQueueTask = nil; self.refreshUpdateQueueEnvironment()
            }
            for game in GameDefinition.all where chosen.contains(game.id) {
                guard !Task.isCancelled, self.updateQueue.automatic, self.updateQueue.automaticGames.contains(game.id),
                    self.queueEnvironmentPermits(automatic: true), self.gameOperation == nil else { return }
                do {
                    let record = try await self.gameServices.record(game.id)
                    guard record?.installed != nil, record?.pending == nil, record?.uninstalling == false else { continue }
                    let status = try await self.gameServices.checkForUpdate(game.id)
                    guard self.updateQueue.automatic, self.updateQueue.automaticGames.contains(game.id),
                        self.queueEnvironmentPermits(automatic: true), self.gameOperation == nil,
                        !self.updateQueue.entries.contains(where: { $0.id == game.id }),
                        try await self.gameServices.record(game.id) == record else { continue }
                    if case .updateAvailable = status {
                        self.updateQueue.entries.append(.init(id: game.id, source: record, automatic: true))
                        self.persistUpdateQueue()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    // A failed metadata check has no authority to change a queue or installation.
                    self.updateQueue.lastDiscovery = self.eventsNow().addingTimeInterval(-5 * 3600)
                    self.persistUpdateQueue()
                }
            }
        }
    }
}
