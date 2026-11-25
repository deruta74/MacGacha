// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import LauncherCore
import GameLibrary

@MainActor extension AppModel {
    var keepsUpdateQueueRunning: Bool {
        updateQueue.enabled && (updateQueue.entries.contains { !$0.paused } || hasAutomaticQueueDiscovery)
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

    func queueFailure(for id: String) -> UpdateQueueFailure? {
        if let approval = updateQueue.entries.first(where: { $0.id == id })?.approval {
            return .approvalRequired(required: approval.required, available: approval.available)
        }
        return updateQueueFailures[id]
    }

    var installLaterLabel: String { String(localized: "Install Later") }

    func scheduledInstall(for id: String) -> ScheduledInstallState? {
        guard let entry = updateQueue.entries.first(where: { $0.id == id }), let request = entry.plannedInstall else { return nil }
        return ScheduledInstallState(request: request, isHeld: entry.paused,
            isRunning: gameOperation?.id == id && gameOperation?.isQueuedUpdate == true, failure: queueFailure(for: id))
    }

    private var canEditUpdateQueue: Bool {
        (updateQueueStore == nil || updateQueueLoaded) && languageRestart == nil && !updateQueueShuttingDown
    }

    func scheduleInstall(_ id: String, voices: Set<String>, at location: URL, approved: Bool, startDate: Date) async throws {
        guard canEditUpdateQueue else { throw LauncherError.busy("Queue settings are unavailable during startup or restart") }
        guard GameDefinition.find(id) != nil, location.isFileURL, location.host == nil || location.host == "localhost",
            startDate.timeIntervalSinceReferenceDate.isFinite else { throw LauncherError.io("Invalid scheduled install") }
        guard gameRecords[id] == nil, gameOperation?.id != id, !updateQueue.entries.contains(where: { $0.id == id }) else {
            throw LauncherError.busy("This edition already has an installation or queued work")
        }
        let request = UpdateQueue.PlannedInstall(startDate: startDate, location: location, voices: voices, approved: approved)
        updateQueueUncommittedInstalls.insert(id)
        defer {
            updateQueueUncommittedInstalls.remove(id)
            refreshUpdateQueueEnvironment()
        }
        saveUpdateQueue { $0.entries.append(.init(id: id, ownershipID: UUID(), plannedInstall: request)) }
        await flushUpdateQueueWrites()
        if let updateQueuePersistenceFailure {
            updateQueue.entries.removeAll { $0.id == id && $0.plannedInstall == request }
            throw updateQueuePersistenceFailure
        }
    }

    func cancelScheduledInstall(_ id: String) {
        guard scheduledInstall(for: id) != nil else { return }
        removeQueuedUpdate(id)
    }

    var keepMacAwakeForScheduledDownloads: Bool { updateQueue.keepMacAwakeForScheduledDownloads }

    var keepMacAwakeForScheduledDownloadsLabel: String {
        String(localized: "Keep this Mac awake for scheduled downloads")
    }

    var scheduledDownloadsSleepExplanation: String {
        String(localized: "The display can sleep. Closing the lid still puts this Mac to sleep.")
    }

    func setKeepMacAwakeForScheduledDownloads(_ enabled: Bool) {
        saveUpdateQueue { $0.keepMacAwakeForScheduledDownloads = enabled }
    }

    var updateQueueSleepHint: UpdateQueueSleepHint? {
        guard keepAwakeCandidate(at: eventsNow()) != nil else { return nil }
        if updateQueueOnAC == false { return .onBattery }
        if updateQueueOnAC == nil { return .powerUnknown }
        if !keepMacAwakeForScheduledDownloads { return .disabled }
        return isKeepingMacAwakeForQueue ? nil : .unavailable
    }

    private func keepAwakeCandidate(at date: Date) -> String? {
        guard updateQueue.enabled, !updateQueueShuttingDown else { return nil }
        if let token = gameOperation, token.isScheduledQueueDownload,
            updateQueue.entries.contains(where: { $0.id == token.id && !$0.paused }) {
            return token.id
        }
        return updateQueue.entries.first {
            !$0.paused && !updateQueueUncommittedInstalls.contains($0.id) && ($0.plannedInstall != nil || (updateQueue.scheduled && updateQueue.isInsideDailyWindow(at: date)))
        }?.id
    }

    private func refreshQueuePowerAssertion() {
        guard keepMacAwakeForScheduledDownloads, updateQueueOnAC == true,
            let game = keepAwakeCandidate(at: eventsNow()), let name = queueEditionDisplayName(game) else {
            releaseQueuePowerAssertion()
            return
        }
        guard updateQueueAssertionGame != game else { return }
        releaseQueuePowerAssertion()
        let reason = String(localized: "MacGacha is waiting to download \(name)")
        if updateQueuePowerAssertion?.acquire(reason: reason) == true {
            updateQueueAssertionGame = game
            isKeepingMacAwakeForQueue = true
        }
    }

    private func releaseQueuePowerAssertion() {
        guard updateQueueAssertionGame != nil else { return }
        updateQueuePowerAssertion?.release()
        updateQueueAssertionGame = nil
        isKeepingMacAwakeForQueue = false
    }

    func saveUpdateQueue(_ edit: (inout UpdateQueue) -> Void) {
        guard canEditUpdateQueue else { return }
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
        saveUpdateQueue { $0.entries.append(.init(id: id, source: gameRecords[id], ownershipID: UUID())) }
    }

    func removeQueuedUpdate(_ id: String) {
        guard canEditUpdateQueue else { return }
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
        let date = updateQueueObservedDate ?? eventsNow()
        if let entry = nextQueuedUpdate ?? updateQueue.entries.first(where: { !$0.paused }) {
            return queueWaiting(entry, at: date)
        }
        return queueWaiting(nil, at: date)
    }

    func queueWaiting(for id: String) -> UpdateQueueWaiting? {
        guard let entry = updateQueue.entries.first(where: { $0.id == id && !$0.paused }),
            !(gameOperation?.id == id && gameOperation?.isQueuedUpdate == true) else { return nil }
        return queueWaiting(entry, at: updateQueueObservedDate ?? eventsNow())
    }

    private func queueWaiting(_ entry: UpdateQueue.Entry?, at date: Date) -> UpdateQueueWaiting? {
        if let start = entry?.plannedInstall?.startDate, start > date { return .scheduledInstall(start) }
        if !updateQueueNetworkAllowed { return .connection }
        if updateQueue.requiresAC && updateQueueOnAC != true { return .acPower }
        if entry?.plannedInstall == nil, !updateQueue.isInsideDailyWindow(at: date) { return .dailyWindow }
        let needsIdle = updateQueue.requiresIdle || entry?.plannedInstall != nil || (entry?.automatic ?? hasAutomaticQueueDiscovery)
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

    func retryQueuedUpdate(_ id: String, approved: Bool = false) {
        guard canEditUpdateQueue,
            let entry = updateQueue.entries.first(where: { $0.id == id && $0.paused }), gameOperation?.id != id else { return }
        updateQueueFailures[id] = nil
        saveUpdateQueue { queue in
            guard let index = queue.entries.firstIndex(where: { $0.id == id }) else { return }
            if approved, entry.approval != nil { queue.entries[index].approvedRetry = true }
            queue.entries[index].approval = nil
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

    func flushUpdateQueueWrites() async {
        while let write = updateQueueWriteTask { await write.value }
    }

    func stopUpdateQueuePreparation() async {
        let preparation = updateQueueTask
        preparation?.cancel()
        await preparation?.value
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
        releaseQueuePowerAssertion()
        let transfer = gameOperation?.isQueuedUpdate == true ? gameTask : nil
        transfer?.cancel()
        guard discovery != nil || transfer != nil || updateQueueWriteTask != nil else { return nil }
        return Task {
            await discovery?.value
            await transfer?.value
            await flushUpdateQueueWrites()
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
        if updateQueueSignals == nil {
            updateQueueEnvironment.start { [weak self] in self?.refreshUpdateQueueEnvironment() }
        }
        guard updateQueueTimer == nil else { return }
        let delay = nextUpdateQueueDelay()
        updateQueueTimer = Task { [weak self] in
            guard let sleep = self?.eventsSleep else { return }
            do { try await sleep(.seconds(delay)) }
            catch { return }
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
        guard !updateQueueShuttingDown, languageRestart == nil, updateQueue.enabled,
            !automatic || (updateQueue.automatic && automaticQueueHasNoGameSession) else { return false }
        let signals = queueSignals()
        return signals.network && (!updateQueue.requiresAC || signals.onAC == true)
    }

    private func queueEnvironmentPermits(automatic: Bool, install: UpdateQueue.PlannedInstall? = nil) -> Bool {
        guard queueCanContinue(automatic: automatic) else { return false }
        let signals = queueSignals()
        let date = eventsNow()
        guard install.map({ $0.startDate <= date }) ?? updateQueue.isInsideDailyWindow(at: date),
            !(updateQueue.requiresIdle || automatic || install != nil) || signals.idle >= queueIdleThreshold else { return false }
        return true
    }

    private var automaticQueueHasNoGameSession: Bool {
        launchSlotOwner == nil && launchTasks.isEmpty && liveLaunchGames.isEmpty &&
            !launchStates.values.contains {
                switch $0 {
                case .starting, .running, .ready, .recoveryNeeded: true
                default: false
                }
            }
    }

    func queuedPlayContinuationPermitted(_ token: GameOperationToken) -> Bool {
        guard token.isQueuedUpdate else { return true }
        guard let entry = updateQueue.entries.first(where: { $0.id == token.id }), !entry.paused else { return false }
        return (!entry.automatic || updateQueue.automaticGames.contains(entry.id)) && queueEnvironmentPermits(automatic: entry.automatic, install: entry.plannedInstall)
    }

    func evaluateUpdateQueue() {
        guard startupFinished, !updateQueueShuttingDown else { return }
        let signals = queueSignals()
        updateQueueNetworkAllowed = signals.0
        updateQueueOnAC = signals.1
        updateQueueIdleSeconds = signals.2
        updateQueueObservedDate = eventsNow()
        refreshQueuePowerAssertion()
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
            guard queueEnvironmentPermits(automatic: entry.automatic, install: entry.plannedInstall),
                canOperateGameDuringPlay(entry.id, isDownload: true), gameUpdateCheckTasks[entry.id] == nil else { return }
            updateQueueTaskIsAutomatic = entry.automatic
            updateQueueTask = Task { [weak self] in
                guard let self else { return }
                defer { self.updateQueueTask = nil; self.refreshUpdateQueueEnvironment() }
                await self.prepareQueuedEntry(entry)
            }
        } else {
            discoverQueuedUpdatesIfNeeded()
        }
    }

    private func prepareQueuedEntry(_ selected: UpdateQueue.Entry) async {
        var entry = selected
        do {
            // A migrated entry may predate ownership identifiers. A fresh
            // publication must always have a matching durable queue intent.
            if entry.ownershipID == nil, let index = updateQueue.entries.firstIndex(of: entry) {
                entry.ownershipID = UUID()
                updateQueue.entries[index] = entry
                persistUpdateQueue()
            }
            await flushUpdateQueueWrites()
            try Task.checkCancellation()
            guard queueEntryCanStart(entry) else { return }
            if let updateQueuePersistenceFailure { throw updateQueuePersistenceFailure }

            try await gameServices.waitUntilIdle(entry.id)
            let record = try await gameServices.record(entry.id)
            try Task.checkCancellation()
            guard queueEntryCanStart(entry) else { return }
            setGameRecord(entry.id, record)
            if let record, let pending = record.pending {
                guard entry.ownsPlan(in: record) else {
                    holdQueuedUpdate(entry.id, failure: .pendingOperation)
                    return
                }
                beginQueuedGame(entry.id, pending: pending)
                return
            }
            // Completion retains the publication owner, so it can be
            // recognized even if the app never observed the pending plan.
            if let record, let installed = record.installed, !record.uninstalling, entry.matchesLocation(record),
                entry.ownsPublication(in: record) || (record.deliveryQueueOwner == nil && entry.pending?.target == installed) {
                removeQueuedUpdate(entry.id)
                return
            }
            if let request = entry.plannedInstall {
                guard record == nil, entry.pending == nil else {
                    holdQueuedUpdate(entry.id, failure: .installationChanged)
                    return
                }
                beginQueuedGame(entry.id, initial: .init(request: .install(request.voices, request.location, entry.spaceApproved), record: nil))
                return
            }
            guard let record, entry.matchesLocation(record), record.installed != nil, !record.uninstalling,
                record.installed == entry.source?.installed, entry.pending == nil else {
                holdQueuedUpdate(entry.id, failure: .installationChanged)
                return
            }
            let status = try await gameServices.checkForUpdate(entry.id)
            try Task.checkCancellation()
            guard queueEntryCanStart(entry) else { return }
            switch status {
            case .updateAvailable: beginQueuedGame(entry.id, initial: .init(request: .update, record: record))
            case .installed: removeQueuedUpdate(entry.id)
            case .locationUnavailable: holdQueuedUpdate(entry.id, failure: .operation(.installVolumeUnavailable))
            default: holdQueuedUpdate(entry.id, failure: .installationChanged)
            }
        } catch {
            if !Task.isCancelled, queueEntryCanStart(entry) {
                holdQueuedUpdate(entry.id, failure: .operation(launcherError(error)))
            }
        }
    }

    private func queueEntryCanStart(_ entry: UpdateQueue.Entry) -> Bool {
        nextQueuedUpdate == entry && gameOperation == nil && !isRuntimeOperationRunning &&
            queueEnvironmentPermits(automatic: entry.automatic, install: entry.plannedInstall) &&
            canBeginGameOrRuntimeOperation(reportBusy: false) && canOperateGameDuringPlay(entry.id, isDownload: true)
    }

    func recordQueueFailure(_ id: String, _ failure: UpdateQueueFailure) {
        updateQueueFailures[id] = failure
        updateQueueLog?.post(.warning, "update-queue", "Queued work failed",
            metadata: ["game": GameDefinition.find(id)?.id ?? "unknown", "case": failure.logCase])
    }

    func holdQueuedUpdate(_ id: String, failure: UpdateQueueFailure) {
        guard let index = updateQueue.entries.firstIndex(where: { $0.id == id }) else { return }
        updateQueue.entries[index].paused = true
        if case .approvalRequired(let required, let available) = failure {
            updateQueue.entries[index].approval = .init(required: required, available: available)
        }
        recordQueueFailure(id, failure)
        persistUpdateQueue()
    }

    func recordQueuedPlan(_ token: GameOperationToken, record: GameRecord?) {
        guard token.isQueuedUpdate, gameOperation == token,
            let index = updateQueue.entries.firstIndex(where: { $0.id == token.id }),
            let record, let pending = record.pending, updateQueue.entries[index].pending == nil,
            updateQueue.entries[index].ownsPlan(in: record) else { return }
        if updateQueue.entries[index].source == nil { updateQueue.entries[index].source = record }
        updateQueue.entries[index].pending = pending
        updateQueue.entries[index].planID = pending.planID.rawValue
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
        } else if let failure {
            holdQueuedUpdate(token.id, failure: .operation(failure))
        }
        Task { [weak self] in self?.refreshUpdateQueueEnvironment() }
    }

    private var nextQueuedUpdate: UpdateQueue.Entry? {
        let date = eventsNow()
        return updateQueue.entries.first { entry in
            !entry.paused && !updateQueueUncommittedInstalls.contains(entry.id) && (entry.plannedInstall.map { $0.startDate <= date } ?? updateQueue.isInsideDailyWindow(at: date))
        }
    }

    private func watchUpdateQueueReservations() {
        guard keepsUpdateQueueRunning, updateQueueWatchID == nil else { return }
        let generation = UUID()
        updateQueueWatchID = generation
        withObservationTracking {
            _ = isStarting; _ = gameOperation; _ = launchSlotOwner; _ = launchTasks; _ = liveLaunchGames; _ = launchStates
            _ = languageRestart; _ = storageCleanupInProgress; _ = prefixResetGame
            _ = gameMoveRecoveryReservation; _ = runtimeCatalogMutationID; _ = isRuntimeOperationRunning
            _ = globalLaunchSettings; _ = updater.isInstallingUpdate; _ = gameUpdateCheck
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
        let date = eventsNow()
        if gameOperation?.isQueuedUpdate == true { return 30 }

        var deadlines = updateQueue.entries.compactMap { entry -> Date? in
            guard !entry.paused, let start = entry.plannedInstall?.startDate, start > date else { return nil }
            return start
        }
        if updateQueue.scheduled, updateQueue.startMinute != updateQueue.endMinute,
            hasAutomaticQueueDiscovery || updateQueue.entries.contains(where: { !$0.paused && $0.plannedInstall == nil }) {
            let minute = updateQueue.isInsideDailyWindow(at: date) ? updateQueue.endMinute : updateQueue.startMinute
            let wallTime = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
            if let boundary = Calendar.current.nextDate(after: date, matching: wallTime, matchingPolicy: .nextTime) {
                deadlines.append(boundary)
            }
        }

        if updateQueueNetworkAllowed, !updateQueue.requiresAC || updateQueueOnAC == true {
            if nextQueuedUpdate != nil { deadlines.append(date.addingTimeInterval(30)) }
            if hasAutomaticQueueDiscovery, updateQueue.isInsideDailyWindow(at: date) {
                let discoveryAt = updateQueue.lastDiscovery?.addingTimeInterval(6 * 3600) ?? date
                deadlines.append(max(date.addingTimeInterval(30), discoveryAt))
            }
        }
        return max(1, deadlines.min().map { date.distance(to: $0) } ?? 3600)
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
                    let current = try await self.gameServices.record(game.id)
                    guard !Task.isCancelled, self.updateQueue.automatic, self.updateQueue.automaticGames.contains(game.id),
                        self.queueEnvironmentPermits(automatic: true), self.gameOperation == nil,
                        !self.updateQueue.entries.contains(where: { $0.id == game.id }), current == record else { continue }
                    self.updateQueueFailures[game.id] = nil
                    if case .updateAvailable = status {
                        self.updateQueue.entries.append(.init(id: game.id, source: record, automatic: true, ownershipID: UUID()))
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
