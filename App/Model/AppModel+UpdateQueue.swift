// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import LauncherCore
import GameLibrary

@MainActor extension AppModel {
    var keepsUpdateQueueRunning: Bool {
        updateQueue.enabled && (nextQueuedUpdate != nil || hasAutomaticQueueDiscovery)
    }

    private var hasAutomaticQueueDiscovery: Bool {
        updateQueue.automatic && !updateQueue.automaticGames.isEmpty
    }

    func queueEditionDisplayName(_ id: String) -> String? {
        LauncherGame.all.first { $0.id == id }.map(editionDisplayName)
    }

    var automaticCheckGameGroups: [AutomaticCheckGameGroup] {
        Region.allCases.flatMap { region in
            let games = LauncherGame.games(in: region)
            return games.compactMap { game -> AutomaticCheckGameGroup? in
                let server = HonkaiImpactServer(rawValue: game.id)
                if let server, server != .europeAmericas { return nil }
                let editions = server == nil ? [game] : games.filter { HonkaiImpactServer(rawValue: $0.id) != nil }
                return AutomaticCheckGameGroup(id: game.id, displayName: game.name, region: region, editions: editions.map { edition in
                    .init(id: edition.id, displayName: editionDisplayName(edition), region: region,
                        isInstalled: gameRecords[edition.id]?.installed != nil && gameRecords[edition.id]?.uninstalling == false)
                })
            }
        }
    }

    func queueFailure(for id: String) -> UpdateQueueFailure? { updateQueueFailures[id] }

    func saveUpdateQueue(_ edit: (inout UpdateQueue) -> Void) {
        guard updateQueueStore == nil || updateQueueLoaded else { return }
        let wasAutomatic = updateQueue.automatic, previousGames = updateQueue.automaticGames
        edit(&updateQueue)
        if updateQueue.automatic && (!wasAutomatic || updateQueue.automaticGames != previousGames) { updateQueue.lastDiscovery = nil }
        let removed = updateQueue.entries.filter { $0.automatic && (!updateQueue.automatic || !updateQueue.automaticGames.contains($0.id)) }.map(\.id)
        updateQueue.entries.removeAll { removed.contains($0.id) }
        for id in removed {
            updateQueueFailures[id] = nil
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
            !updateQueue.entries.contains(where: { $0.id == id }),
            !(gameOperation?.id == id && gameOperation?.isQueuedUpdate == true) else { return }
        updateQueueFailures[id] = nil
        saveUpdateQueue { $0.entries.append(.init(id: id, source: gameRecords[id])) }
    }

    func removeQueuedUpdate(_ id: String) {
        updateQueueFailures[id] = nil
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

    var updateQueueWaitingReason: String? { updateQueueWaiting?.userMessage }

    var updateQueueWaiting: UpdateQueueWaiting? {
        guard keepsUpdateQueueRunning, gameOperation?.isQueuedUpdate != true else { return nil }
        if !updateQueueNetworkAllowed { return .connection }
        if updateQueue.requiresAC && updateQueueOnAC != true { return .acPower }
        if !updateQueue.permits(at: eventsNow(), onAC: updateQueueOnAC) { return .dailyWindow }
        let needsIdle = updateQueue.requiresIdle || (nextQueuedUpdate?.automatic ?? hasAutomaticQueueDiscovery)
        if needsIdle && updateQueueIdleSeconds < queueIdleThreshold { return .idle }
        return nil
    }

    private var queueIdleThreshold: TimeInterval { Double(max(1, updateQueue.idleMinutes)) * 60 }

    func moveQueuedUpdate(_ id: String, by offset: Int) {
        saveUpdateQueue { queue in
            guard let index = queue.entries.firstIndex(where: { $0.id == id }), queue.entries.indices.contains(index + offset) else { return }
            queue.entries.swapAt(index, index + offset)
        }
    }

    func retryQueuedUpdate(_ id: String) {
        updateQueueFailures[id] = nil
        saveUpdateQueue { queue in
            guard let index = queue.entries.firstIndex(where: { $0.id == id }) else { return }
            queue.entries[index].paused = false
        }
    }

    func manuallyPauseQueuedUpdate(_ id: String) {
        guard gameOperation?.id == id, gameOperation?.isQueuedUpdate == true,
            updateQueue.entries.contains(where: { $0.id == id }) else { return }
        saveUpdateQueue { queue in
            if let index = queue.entries.firstIndex(where: { $0.id == id }) { queue.entries[index].paused = true }
        }
    }

    func loadUpdateQueue() async {
        guard let store = updateQueueStore, !updateQueueLoaded else { return }
        defer { updateQueueLoaded = true }
        let legacy = defaults?.data(forKey: UpdateQueueStore.legacyKey)
        do {
            let loaded = try await BlockingIO.run { try store.load(migrating: legacy) }
            updateQueue = loaded
            defaults?.removeObject(forKey: UpdateQueueStore.legacyKey)
        } catch {
            reportUpdateQueuePersistenceFailure(error)
        }
    }

    func persistUpdateQueue() {
        guard let store = updateQueueStore else { return }
        let snapshot = updateQueue, previous = updateQueueWriteTask, revision = UUID()
        updateQueueWriteRevision = revision
        updateQueueWriteTask = Task { [weak self] in
            await previous?.value
            guard let self, self.updateQueueWriteRevision == revision else { return }
            do {
                try await BlockingIO.run { try store.save(snapshot) }
                if self.updateQueueWriteRevision == revision { self.updateQueuePersistenceFailure = nil }
                self.defaults?.removeObject(forKey: UpdateQueueStore.legacyKey)
            } catch {
                if self.updateQueueWriteRevision == revision { self.reportUpdateQueuePersistenceFailure(error) }
            }
            if self.updateQueueWriteRevision == revision { self.updateQueueWriteTask = nil }
        }
    }

    private func reportUpdateQueuePersistenceFailure(_ error: any Error) {
        let failure = launcherError(error)
        updateQueuePersistenceFailure = failure
        updateQueueLog?.post(.warning, "update-queue", "Queue state unavailable", metadata: ["case": failure.logCase])
    }

    func stopUpdateQueueForQuit() -> Task<Void, Never>? {
        updateQueueShuttingDown = true
        updateQueueTimer?.cancel()
        let discovery = updateQueueTask
        discovery?.cancel()
        updateQueueEnvironment.stop()
        let transfer = gameOperation?.isQueuedUpdate == true ? gameTask : nil
        transfer?.cancel()
        guard discovery != nil || transfer != nil || updateQueueWriteTask != nil else { return nil }
        return Task {
            await discovery?.value
            await transfer?.value
            await updateQueueWriteTask?.value
        }
    }

    func startUpdateQueueMonitoring() {
        guard startupFinished, !updateQueueShuttingDown, keepsUpdateQueueRunning else {
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
            do { guard let sleep = self?.eventsSleep else { return }; try await sleep(.seconds(delay)) } catch { return }
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

    private func queueSignals() -> (network: Bool, onAC: Bool?, idle: TimeInterval) {
        updateQueueSignals?() ?? (updateQueueEnvironment.permitsNetwork, updateQueueEnvironment.onAC, updateQueueEnvironment.idleSeconds)
    }

    private func queueCanContinue(automatic: Bool) -> Bool {
        guard !updateQueueShuttingDown, updateQueue.enabled, (!automatic || updateQueue.automatic) else { return false }
        let signals = queueSignals()
        return signals.network && (!updateQueue.requiresAC || signals.onAC == true)
    }

    func queueEnvironmentPermits(automatic: Bool) -> Bool {
        guard queueCanContinue(automatic: automatic) else { return false }
        let signals = queueSignals()
        guard updateQueue.permits(at: eventsNow(), onAC: signals.onAC),
            !(updateQueue.requiresIdle || automatic) || signals.idle >= queueIdleThreshold else { return false }
        if automatic {
            guard launchSlotOwner == nil, launchTasks.isEmpty, liveLaunchGames.isEmpty,
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
        guard startupFinished, !updateQueueShuttingDown else { return }
        let signals = queueSignals()
        updateQueueNetworkAllowed = signals.0
        updateQueueOnAC = signals.1
        updateQueueIdleSeconds = signals.2
        watchUpdateQueueReservations()
        if !queueCanContinue(automatic: updateQueueTaskIsAutomatic) { updateQueueTask?.cancel() }
        if let token = gameOperation, token.isQueuedUpdate {
            let entry = updateQueue.entries.first { $0.id == token.id }
            if let entry, !entry.paused, queueCanContinue(automatic: entry.automatic) { return }
            gameTask?.cancel()
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
                        self.holdQueuedUpdate(entry.id, failure: .installationChanged); return
                    }
                    self.setGameRecord(entry.id, record)
                    if let pending = record?.pending {
                        guard entry.pending == pending, pending.kind == .update,
                            record?.installIdentity == entry.source?.installIdentity,
                            record?.installPath == entry.source?.installPath else { self.holdQueuedUpdate(entry.id, failure: .pendingOperation); return }
                        self.beginQueuedGame(entry.id, pending: pending)
                    } else {
                        guard record?.installIdentity == entry.source?.installIdentity,
                            record?.installPath == entry.source?.installPath,
                            record?.installed == entry.source?.installed else { self.holdQueuedUpdate(entry.id, failure: .installationChanged); return }
                        let status = try await self.gameServices.checkForUpdate(entry.id)
                        try Task.checkCancellation()
                        guard self.nextQueuedUpdate == entry,
                            self.queueEnvironmentPermits(automatic: entry.automatic), self.gameOperation == nil else { return }
                        if case .updateAvailable = status { self.beginQueuedGame(entry.id, initial: .init(request: .update, record: record)) }
                        else if case .installed = status { self.removeQueuedUpdate(entry.id) }
                        else { self.holdQueuedUpdate(entry.id, failure: .installationChanged) }
                    }
                } catch {
                    if !Task.isCancelled, self.updateQueue.entries.contains(entry) {
                        self.holdQueuedUpdate(entry.id, failure: .operation(launcherError(error)))
                    }
                }
            }
        } else {
            discoverQueuedUpdatesIfNeeded()
        }
    }

    func recordQueueFailure(_ id: String, _ failure: UpdateQueueFailure) {
        updateQueueFailures[id] = failure
        updateQueueLog?.post(.warning, "update-queue", "Queued work failed",
            metadata: ["game": id, "case": failure.logCase])
    }

    func holdQueuedUpdate(_ id: String, failure: UpdateQueueFailure) {
        guard let index = updateQueue.entries.firstIndex(where: { $0.id == id }) else { return }
        updateQueue.entries[index].paused = true
        recordQueueFailure(id, failure)
        persistUpdateQueue()
    }

    func queuedUpdateRecordChanged(_ id: String, record: GameRecord?) {
        guard gameOperation?.id == id, gameOperation?.isQueuedUpdate == true,
            let index = updateQueue.entries.firstIndex(where: { $0.id == id }) else { return }
        guard updateQueue.entries[index].pending != record?.pending else { return }
        updateQueue.entries[index].pending = record?.pending
        updateQueue.entries[index].planID = record?.pending?.planID.rawValue
        persistUpdateQueue()
    }

    func queuedUpdateFinished(_ token: GameOperationToken, outcome: GameConsumerOutcome,
        failure: LauncherError?, activity: GameActivity?) {
        guard token.isQueuedUpdate, let index = updateQueue.entries.firstIndex(where: { $0.id == token.id }) else { return }
        if case .completed = outcome {
            updateQueue.entries.remove(at: index)
            updateQueueFailures[token.id] = nil
            persistUpdateQueue()
        } else if case .needsApproval(let required, let available) = activity {
            holdQueuedUpdate(token.id, failure: .approvalRequired(required: required, available: available))
        } else if case .failed = outcome, let failure {
            holdQueuedUpdate(token.id, failure: .operation(failure))
        }
        Task { [weak self] in self?.refreshUpdateQueueEnvironment() }
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
        if gameOperation?.isQueuedUpdate == true { return 30 }
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
                        self.updateQueueFailures[game.id] = nil
                        self.updateQueue.entries.append(.init(id: game.id, source: record, automatic: true))
                        self.persistUpdateQueue()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.recordQueueFailure(game.id, .operation(launcherError(error)))
                    // A failed metadata check has no authority to change a queue or installation.
                    self.updateQueue.lastDiscovery = self.eventsNow().addingTimeInterval(-5 * 3600)
                    self.persistUpdateQueue()
                }
            }
        }
    }
}
