// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import DownloadEngine
import GameLibrary

enum GameUpdateCheckResult: Sendable, Equatable {
    case checking, upToDate(Date), updateAvailable, failed(LauncherError)
}

struct GameOperationToken: Sendable, Equatable {
    let id: String; let generation: UUID
    var kind: OtherRegionActivity = .downloading
    var notificationCompletion: GameNotificationKind? = nil
    var isVerification = false
    var isUninstall = false
    var isDownload = false
    var unplannedDownload: PlayUnplannedDownload? = nil
    var isPreDownload = false
    var isMoving = false
    var isSandbox = false
    var automaticSandboxVersion: String? = nil
    var moveDestination: URL? = nil
    var installPath: URL? = nil

    var permitsOtherGamePlay: Bool { isDownload || (isPreDownload && !isUninstall) }
    var yieldsToPlay: Bool { (isPreDownload && !isUninstall) || automaticSandboxVersion != nil }
}
private enum GameRequest: Sendable {
    case install(Set<String>, URL, Bool), adopt(URL, Set<String>), update, resume(Bool), verify, voices(Set<String>), uninstall, move(URL)
    case installSandbox, updateSandbox, removeSandbox
    case automaticSandboxUpdate(String)
    func isDownload(record: GameRecord?) -> Bool {
        switch self {
        case .install, .update: true
        case .resume: record?.pending?.kind == .install || record?.pending?.kind == .update
        default: false
        }
    }
    func unplannedDownload(record: GameRecord?) -> PlayUnplannedDownload? {
        guard record?.pending == nil else { return nil }
        switch self {
        case .install(let voices, let location, let approved):
            return PlayUnplannedDownload(request: .install(voices, location, approved), record: record)
        case .update: return PlayUnplannedDownload(request: .update, record: record)
        default: return nil
        }
    }
    var isSandbox: Bool {
        switch self { case .installSandbox, .updateSandbox, .removeSandbox, .automaticSandboxUpdate: true; default: false }
    }
    var automaticSandboxVersion: String? {
        if case .automaticSandboxUpdate(let version) = self { return version }
        return nil
    }
    var refreshCanStartSandbox: Bool {
        switch self {
        case .install, .adopt, .update, .verify, .resume: true
        default: false
        }
    }
    var isMoving: Bool { if case .move = self { true } else { false } }
    var isUninstall: Bool { if case .uninstall = self { true } else { false } }
    var installPath: URL? {
        switch self {
        case .install(_, let path, _), .adopt(let path, _): path
        default: nil
        }
    }
    func notificationCompletion(record: GameRecord?) -> GameNotificationKind? {
        switch self {
        case .install: .installFinished
        case .update: .updateFinished
        case .verify: .repairFinished
        case .resume:
            switch record?.pending?.kind {
            case .install: .installFinished
            case .update: .updateFinished
            case .repair: .repairFinished
            default: nil
            }
        default: nil
        }
    }
    func activity(record: GameRecord?) -> OtherRegionActivity {
        switch self {
        case .verify, .adopt: .verifying
        case .update, .uninstall, .move, .updateSandbox, .removeSandbox, .automaticSandboxUpdate: .updating
        case .resume: record?.pending?.kind == .update ? .updating : record?.pending?.kind == .repair ? .verifying : .downloading
        case .install, .voices, .installSandbox: .downloading
        }
    }
}
enum GameStopOutcome: Sendable, Equatable {
    case resume(planID: String), preDownload(planID: String, planDigest: Digest), verify, finished, failed
}
enum GameConsumerOutcome: Sendable { case stopped, completed, failed }
private struct GameSnapshot: Sendable {
    let status: GameStatus
    let record: GameRecord?
    var error: LauncherError? = nil
    var sandbox: Result<SandboxState?, LauncherError> = .success(nil)
}
@concurrent private func readSandbox(_ services: any GameServices, id: String, status: GameStatus, record: GameRecord?) async -> Result<SandboxState?, LauncherError> {
    guard record?.installed != nil else { return .success(nil) }
    if case .locationUnavailable = status { return .failure(.installVolumeUnavailable) }
    do { return .success(try await services.sandboxState(id)) }
    catch { return .failure(launcherError(error)) }
}
@concurrent private func readGameDetails(_ services: any GameServices, id: String, status: GameStatus) async throws -> GameSnapshot {
    var record = try await services.record(id)
    let sandbox = await readSandbox(services, id: id, status: status, record: record)
    if record?.sandbox == nil {
        // Discovery can persist a package already on disk during the status read.
        switch sandbox {
        case .success(.installed), .success(.outdated): record = try await services.record(id)
        default: break
        }
    }
    return GameSnapshot(status: status, record: record, sandbox: sandbox)
}
@concurrent private func readGame(_ services: any GameServices, id: String, draining: Bool = false) async -> GameSnapshot {
    if draining {
        do { try await services.waitUntilIdle(id) }
        catch {
            let error = launcherError(error)
            return GameSnapshot(status: await services.status(id), record: try? await services.record(id), error: error, sandbox: .failure(error))
        }
    }
    let status = await services.status(id)
    do {
        return try await readGameDetails(services, id: id, status: status)
    } catch {
        let error = launcherError(error)
        return GameSnapshot(status: status, record: nil, error: error, sandbox: .failure(error))
    }
}

@concurrent private func readAfterAutomaticSandbox(_ services: any GameServices, id: String,
    previousStatus: GameStatus, publishedVersion: String?) async -> GameSnapshot {
    do {
        try await services.waitForSandboxDrain(id)
        let status = try await services.locationStatus(id)
        let record = try await services.record(id)
        // The operation owns its offer. Retain cached state unless the durable
        // installed version confirms completion or the game was removed.
        let sandbox: Result<SandboxState?, LauncherError>
        if record?.installed == nil { sandbox = .success(nil) }
        else if let publishedVersion, record?.sandbox?.version == publishedVersion { sandbox = .success(.installed(version: publishedVersion)) }
        else { sandbox = .failure(.cancelled) }
        return GameSnapshot(status: status, record: record, sandbox: sandbox)
    } catch {
        let error = launcherError(error)
        return GameSnapshot(status: previousStatus, record: try? await services.record(id), error: error, sandbox: .failure(error))
    }
}

@MainActor extension AppModel {
    func checkForGameUpdate(_ id: String) {
        guard gameUpdateCheckTasks[id] == nil, canCheckGameUpdate(id) else { return }
        let revision = UUID()
        gameRevisions[id] = revision // Supersede any older automatic status read.
        gameUpdateCheck[id] = .checking
        let startup = ensureGameStartup(), services = gameServices
        gameUpdateCheckTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.gameUpdateCheckTasks[id] = nil }
            do {
                await startup.value
                try Task.checkCancellation()
                guard self.isCurrentGameUpdateCheck(id, revision: revision) else {
                    self.clearCheckingGameUpdate(id); return
                }
                if let error = self.launchStartupError { throw error }
                let status = try await services.checkForUpdate(id)
                let snapshot = try await readGameDetails(services, id: id, status: status)
                try Task.checkCancellation()
                guard self.isCurrentGameUpdateCheck(id, revision: revision) else {
                    self.clearCheckingGameUpdate(id); return
                }
                self.applyGame(snapshot, id: id, activity: nil)
                if case .updateAvailable(_, let version) = status { self.notify(.updateAvailable, gameID: id, version: version) }
                self.gameRevisions[id] = UUID() // Invalidate automatic reads begun during the check.
                switch status {
                case .installed: self.gameUpdateCheck[id] = .upToDate(self.eventsNow())
                case .updateAvailable: self.gameUpdateCheck[id] = .updateAvailable
                default: break // A missing or paused installation is not an up-to-date claim.
                }
                self.startAutomaticSandboxIfEligible(id, status: status, offer: snapshot.sandbox)
            } catch {
                guard self.isCurrentGameUpdateCheck(id, revision: revision) else {
                    self.clearCheckingGameUpdate(id); return
                }
                self.gameUpdateCheck[id] = .failed(launcherError(error))
            }
        }
    }

    private func canCheckGameUpdate(_ id: String) -> Bool {
        guard GameDefinition.find(id) != nil, languageRestart == nil, !updater.isInstallingUpdate,
            gameOperation?.id != id, games[id]?.activity == nil, gameRecords[id]?.pending == nil,
            gameRecords[id]?.uninstalling != true, launchSlotOwner != id, launchTasks[id] == nil,
            !liveLaunchGames.contains(id) else { return false }
        switch launchStates[id] {
        case .starting, .running, .ready, .recoveryNeeded: return false
        case nil, .failed: return true
        }
    }

    private func isCurrentGameUpdateCheck(_ id: String, revision: UUID) -> Bool {
        gameRevisions[id] == revision && gameUpdateCheck[id] == .checking && canCheckGameUpdate(id)
    }

    private func clearCheckingGameUpdate(_ id: String) {
        if gameUpdateCheck[id] == .checking { gameUpdateCheck[id] = nil }
    }

    func refreshGames() async {
        await refreshGames(in: region)
    }

    func refreshGames(in region: Region) async {
        let time = now()
        guard !gameRefreshInFlight.contains(region), gameLastRefresh[region].map({ $0.duration(to: time) >= .seconds(600) }) ?? true else { return }
        gameRefreshInFlight.insert(region); gameLastRefresh[region] = time
        defer { gameRefreshInFlight.remove(region) }
        await ensureGameStartup().value
        guard !Task.isCancelled, launchStartupError == nil else { return }
        let revisions = gameRevisions, services = gameServices
        let ids = GameDefinition.inRegion(region).map(\.id).filter { $0 != gameOperation?.id }
        let results = await withTaskGroup(of: (String, GameSnapshot).self) { group in
            for id in ids { group.addTask { (id, await readGame(services, id: id)) } }
            var result: [(String, GameSnapshot)] = []
            for await value in group { result.append(value) }
            return result
        }
        guard !Task.isCancelled else { return }
        // A manual check in flight owns this game's status until it finishes,
        // so a cached automatic read cannot discard its fresh result.
        for (id, snapshot) in results where gameRevisions[id] == revisions[id] && gameUpdateCheckTasks[id] == nil {
            applyGame(snapshot, id: id, activity: games[id]?.activity)
            if case .updateAvailable(_, let version) = snapshot.status { notify(.updateAvailable, gameID: id, version: version) }
            startAutomaticSandboxIfEligible(id, status: snapshot.status, offer: snapshot.sandbox)
        }
        await refreshPreDownloads(in: region)
        // Records are local; only the selected region performs remote status reads.
        let others = GameDefinition.all.filter { $0.region != region && $0.id != gameOperation?.id }.map(\.id)
        let records = await withTaskGroup(of: (String, GameRecord?, LauncherError?).self) { group in
            for id in others {
                group.addTask {
                    do { return (id, try await services.record(id), nil) }
                    catch { return (id, nil, launcherError(error)) }
                }
            }
            var result: [(String, GameRecord?, LauncherError?)] = []
            for await value in group { result.append(value) }
            return result
        }
        guard !Task.isCancelled else { return }
        for (id, record, error) in records where gameRevisions[id] == revisions[id] {
            setGameRecord(id, record)
            if let error { show(error) }
        }
    }

    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        await ensureGameStartup().value
        try Task.checkCancellation()
        if let launchStartupError { throw launchStartupError }
        let value = try await gameServices.estimate(id, voices: voices, at: location)
        try Task.checkCancellation()
        return value
    }

    func installGame(_ id: String, voices: Set<String>, at location: URL, approved: Bool) { beginGame(id, .install(voices, location, approved)) }
    func adoptGame(_ id: String, folder: URL, voices: Set<String>) { beginGame(id, .adopt(folder, voices)) }
    func updateGame(_ id: String) { beginGame(id, .update) }
    func resumeGame(_ id: String, expectedPending: PendingOperation? = nil) { beginGame(id, .resume(false), expectedPending: expectedPending) }
    func resumeUnplannedDownload(_ initial: PlayUnplannedDownload, for id: String) {
        if case .preDownload = initial.request { restartUnplannedPreDownload(id, initial: initial); return }
        let request: GameRequest
        switch initial.request {
        case .install(let voices, let location, let approved): request = .install(voices, location, approved)
        case .update: request = .update
        case .preDownload: return
        }
        beginGame(id, request, expectedUnplanned: initial)
    }
    func verifyGame(_ id: String) { beginGame(id, .verify) }
    func setVoices(_ id: String, _ voices: Set<String>) { beginGame(id, .voices(voices)) }
    func installSandbox(_ id: String) { if canInstallSandbox(id) { beginGame(id, .installSandbox) } }
    func updateSandbox(_ id: String) { if canUpdateSandbox(id) { beginGame(id, .updateSandbox) } }
    func removeSandbox(_ id: String) { if canRemoveSandbox(id) { beginGame(id, .removeSandbox) } }
    private func startAutomaticSandboxIfEligible(_ id: String, status: GameStatus, offer: Result<SandboxState?, LauncherError>) {
        guard case .installed = status, case .success(.outdated(_, let version, _)) = offer,
            canUpdateSandbox(id), automaticSandboxAttempts[id]?.contains(version) != true else { return }
        if beginGame(id, .automaticSandboxUpdate(version)) != nil {
            automaticSandboxAttempts[id, default: []].insert(version)
        }
    }
    func pauseGame(_ id: String) {
        cancelPlayDownloadResume(for: id)
        if gameOperation?.id == id { gameTask?.cancel() }
    }
    func approveBatches(_ id: String) {
        guard case .needsApproval = games[id]?.activity else { return }
        beginGame(id, .resume(true)) // Resume the exact saved plan; never rebuild it.
    }
    func canMoveGame(_ id: String) -> Bool {
        guard GameDefinition.find(id) != nil, canOperateGameDuringPlay(id, isDownload: false), !isStarting, !gameMoveRecoveryReservation, languageRestart == nil, !updater.isInstallingUpdate,
            launchStartupError == nil, runtimeCatalogMutationID == nil,
            gameRecords[id]?.installed != nil, gameRecords[id]?.pending == nil,
            gameRecords[id]?.uninstalling == false, launchSlotOwner != id, launchTasks[id] == nil,
            !liveLaunchGames.contains(id), !launchRecoveryConflicts.contains(id),
            !recoveryNotices.contains(where: { $0.game == id }),
            gameOperation == nil || (gameOperation?.id == id && gameOperation?.isPreDownload == true && gameOperation?.isUninstall == false) else { return false }
        switch launchStates[id] {
        case .starting, .running, .ready, .recoveryNeeded: return false
        case nil, .failed: break
        }
        switch games[id]?.status {
        case .installed, .updateAvailable: return true
        default: return false
        }
    }

    func moveGame(_ id: String, to folder: URL) {
        guard canMoveGame(id) else { return }
        beginGame(id, .move(folder))
    }

    func uninstallGame(_ id: String) async { await beginGame(id, .uninstall)?.value }
    func installedVoices(_ id: String) -> Set<String> { gameRecords[id]?.installed?.voices ?? [] }
    func gameRecord(_ id: String) -> GameRecord? { gameRecords[id] }

    func observeGameActivation() {
        let center = activationCenter
        gameActivationTask = Task { [weak self] in
            let events = center.notifications(named: NSApplication.didBecomeActiveNotification).map { _ in true }
            for await _ in events {
                guard !Task.isCancelled else { return }
                self?.revalidateGameEvents()
                self?.scheduleRuntimeCatalogRefresh()
                await self?.refreshRosetta()
                if self?.gameStartupTask != nil { await self?.refreshGames() }
            }
        }
    }

    func ensureGameStartup() -> Task<Void, Never> {
        if let task = gameStartupTask { return task }
        let services = gameServices
        let task = Task { [weak self] in
            await self?.reattachOnStart()
            guard self?.launchStartupError == nil else { return }
            await services.start()
        }
        gameStartupTask = task
        return task
    }

    private func reserveGame(_ id: String, activity: GameActivity, kind: OtherRegionActivity, isVerification: Bool, isUninstall: Bool, installPath: URL?, isMoving: Bool = false, isSandbox: Bool = false, automaticSandboxVersion: String? = nil, moveDestination: URL? = nil, notificationCompletion: GameNotificationKind? = nil, isDownload: Bool = false, unplannedDownload: PlayUnplannedDownload? = nil) -> GameOperationToken? {
        guard canBeginGameOrRuntimeOperation(), canOperateGameDuringPlay(id, isDownload: isDownload) else { return nil }
        guard GameDefinition.all.contains(where: { $0.id == id }) else { show(LauncherError.io("Unknown game")); return nil }
        guard gameOperation == nil || (isMoving && gameOperation?.id == id && gameOperation?.isPreDownload == true && gameOperation?.isUninstall == false) else { show(LauncherError.busy("another game operation is running")); return nil }
        let token = GameOperationToken(id: id, generation: UUID(), kind: kind, notificationCompletion: notificationCompletion, isVerification: isVerification, isUninstall: isUninstall, isDownload: isDownload, unplannedDownload: unplannedDownload, isMoving: isMoving, isSandbox: isSandbox, automaticSandboxVersion: automaticSandboxVersion, moveDestination: moveDestination, installPath: installPath)
        cancelPlayDownloadResume(for: id)
        gameOperation = token; gameRevisions[id] = token.generation
        gameProgress = GameProgress()
        sandboxFailures[id] = nil
        if automaticSandboxVersion == nil { dismissError() }
        setGameState(id, GameState(status: games[id]?.status ?? .unknown, activity: activity))
        return token
    }

    @discardableResult private func beginGame(_ id: String, _ request: GameRequest, expectedPending: PendingOperation? = nil, expectedUnplanned: PlayUnplannedDownload? = nil) -> Task<Void, Never>? {
        let previousPreDownload = request.isMoving && gameOperation?.id == id && gameOperation?.isPreDownload == true ? gameTask : nil
        let destination: URL? = if case .move(let folder) = request { folder } else { nil }
        guard let token = reserveGame(id, activity: request.isUninstall ? .working(.deleting, fraction: nil, bytesPerSecond: nil) : .resolving,
            kind: request.activity(record: gameRecords[id]), isVerification: { if case .verify = request { true } else { false } }(), isUninstall: request.isUninstall, installPath: request.installPath ?? gameRecords[id]?.installPath, isMoving: request.isMoving, isSandbox: request.isSandbox, automaticSandboxVersion: request.automaticSandboxVersion, moveDestination: destination, notificationCompletion: request.notificationCompletion(record: gameRecords[id]), isDownload: request.isDownload(record: gameRecords[id]), unplannedDownload: request.unplannedDownload(record: gameRecords[id])) else { return nil }
        previousPreDownload?.cancel()
        let services = gameServices, startup = ensureGameStartup()
        let task = Task { [weak self] in
            var approval: (required: Int64, available: Int64)?
            var failure: LauncherError?
            var completed = false
            var sandboxDeferred = false
            var notificationCompletion = token.notificationCompletion
            do {
                if let previousPreDownload {
                    await previousPreDownload.value
                    try await services.waitForPreDownloadDrain(id)
                }
                await startup.value
                try Task.checkCancellation()
                if let error = self?.launchStartupError { throw error }
                if case .resume = request {
                    // A cached pending record can outlive its completed durable plan.
                    let current = try? await services.record(id)
                    notificationCompletion = request.notificationCompletion(record: current)
                    guard self?.canOperateGameDuringPlay(id, isDownload: request.isDownload(record: current)) != false else { throw LauncherError.cancelled }
                }
                if let expectedUnplanned {
                    let current = try await services.record(id)
                    guard current == expectedUnplanned.record, current?.pending == nil, current?.uninstalling != true else { throw LauncherError.cancelled }
                }
                if let expectedPending {
                    guard try await services.record(id)?.pending == expectedPending else { throw LauncherError.cancelled }
                }
                switch request {
                case .update, .resume, .verify, .voices, .uninstall, .move, .installSandbox, .updateSandbox, .removeSandbox: try await self?.recheckGameLocation(id)
                case .install, .adopt, .automaticSandboxUpdate: break
                }
                self?.gameLocationPauseReasons[id] = nil
                try Task.checkCancellation()
                let stream = await gameStream(services, id: id, request: request)
                events: for try await event in stream {
                    try Task.checkCancellation()
                    guard self?.gameOperation == token else { return }
                    switch event {
                    case .phase(.completed): completed = true; break events
                    case .phase(.cancelled): throw LauncherError.cancelled
                    case .phase(.failed): throw LauncherError.io("Game operation failed")
                    case .failed(let error): throw error
                    case .sandboxPhase(let phase): self?.setSandboxOperationPhase(id, phase: phase)
                    case .sandboxFailed(let error): self?.sandboxFailures[id] = error
                    case .sandboxDeferred: sandboxDeferred = true
                    case .needsBatchApproval(let required, let available):
                        // Approval becomes actionable only after the stream and
                        // durable snapshot finish and we release the reservation.
                        approval = (required, available)
                    case .phase(let phase):
                        if let record = try? await services.record(id), self?.gameOperation == token {
                            self?.setGameRecord(id, record)
                        }
                        self?.setGameOperationPhase(id, phase: phase)
                    case .progress(let downloaded, let network, let staged, let totalStaged):
                        self?.updateGameProgress(id, downloaded: downloaded, network: network, staged: staged, totalStaged: totalStaged)
                    case .fileVerified: break
                    }
                }
                // Nil without completed is a pause; OperationRunner owns the receipt proof.
            } catch {
                let error = launcherError(error)
                if approval != nil, case .insufficientSpace = error { /* Expected approval pair. */ }
                else { failure = error }
            }
            guard self?.gameOperation == token else { return }
            if let self, let version = token.automaticSandboxVersion {
                await self.finishAutomaticSandbox(token, version: version, completed: completed,
                    deferredForGameUpdate: sandboxDeferred, failure: failure)
                return
            }
            // Retire older location reads before capture, preserving later events.
            let finalizationRevision = UUID()
            self?.gameRevisions[id] = finalizationRevision
            var snapshotRevision: UUID? = finalizationRevision
            // Cancellation may have raced with publication. Read the durable state
            // in an uncancelled task, retaining services rather than the model.
            let ejectPause = failure == .installVolumeUnavailable || self?.gameLocationPauseReasons[id] == .installVolumeUnavailable
            // Moves and eject pauses retain the reservation through drainage.
            let initialDrain = ejectPause || token.isMoving
            var drained = initialDrain
            var snapshot = await Task.detached { await readGame(services, id: id, draining: initialDrain) }.value
            guard let self, self.gameOperation == token else { return }
            let cacheInfo = try? await services.preDownloadInfo(id, refresh: false)
            guard self.gameOperation == token else { return }
            // Recheck after every read: a mount may finish its refresh already,
            // or queue behind this consumer. Late ejects still require drainage.
            while self.gameRevisions[id] != snapshotRevision ||
                (!drained && self.gameLocationPauseReasons[id] == .installVolumeUnavailable) {
                let needsDrain = !drained && self.gameLocationPauseReasons[id] == .installVolumeUnavailable
                snapshotRevision = self.gameRevisions[id]
                snapshot = await Task.detached { await readGame(services, id: id, draining: needsDrain) }.value
                drained = drained || needsDrain
                guard self.gameOperation == token else { return }
            }
            let moveStoppedByEject = token.isMoving && ejectPause && !completed
            if token.isMoving {
                // A move rolls back rather than publishing a resumable plan.
                // Its transient eject marker must not become a download hint.
                self.gameLocationPauseReasons[id] = nil
                if moveStoppedByEject {
                    self.showMoveVolumeUnavailable(originalFolder: snapshot.record?.installPath == token.installPath)
                } else if let failure { self.show(failure) }
            } else {
                if failure == .installVolumeUnavailable { self.gameLocationPauseReasons[id] = .installVolumeUnavailable }
                if let reason = self.gameLocationPauseReasons[id], !completed { self.show(reason) }
                else if let failure { self.show(failure) }
            }
            let activity: GameActivity?
            if !completed, failure == nil, let approval { activity = .needsApproval(required: approval.required, available: approval.available) }
            else { activity = nil }
            // Publish for the latest observed revision without replacing it.
            // No suspension may separate this publication from releasing the token.
            let finalRevision = snapshotRevision
            self.applyGame(snapshot, id: id, activity: activity, reportError: failure == nil && !moveStoppedByEject)
            if let cacheInfo {
                self.preDownloadRevisions[id] = UUID()
                self.preDownloads[id] = PreDownloadOverlay(info: cacheInfo)
            }
            if case .insufficientSpace(let required, let available) = failure, case .paused = snapshot.status {
                var state = self.games[id] ?? GameState(status: snapshot.status)
                state.spaceShortage = GameSpaceShortage(required: required, available: available)
                self.setGameState(id, state)
            } else if !completed, failure == nil, let approval, case .paused = snapshot.status {
                var state = self.games[id] ?? GameState(status: snapshot.status)
                state.spaceShortage = GameSpaceShortage(required: approval.required, available: approval.available)
                self.setGameState(id, state)
            }
            let failed = failure.map { $0 != .cancelled } ?? false
            self.lastGameConsumerOutcome = (token, failed || snapshot.error != nil ? .failed : completed ? .completed : .stopped)
            self.releaseGame(token, activity: activity)
            if let completion = notificationCompletion {
                if completed { self.notify(completion, gameID: id) }
                else if approval != nil { self.notify(.pausedForSpace, gameID: id) }
                else if case .insufficientSpace = failure { self.notify(.pausedForSpace, gameID: id) }
                else if failed { self.notify(.operationFailed, gameID: id) }
            }
            if completed, request.refreshCanStartSandbox, self.sandboxFailures[id] == nil {
                self.startAutomaticSandboxIfEligible(id, status: snapshot.status, offer: snapshot.sandbox)
            }
            // CacheDelete is advisory and potentially slow. Query only this pause,
            // after releasing the operation slot, never from the progress stream.
            if let shortage = self.games[id]?.spaceShortage, shortage.isMeasured,
                let location = snapshot.record?.installPath {
                let probe = self.purgeableSpace
                let important = try? await BlockingIO.run { probe.importantUsageBytes(at: location) }
                guard self.gameRevisions[id] == finalRevision,
                    var state = self.games[id], state.activity == activity, state.spaceShortage == shortage else { return }
                state.spaceShortage?.purgeable = important.map { max(0, max(0, $0) - max(0, shortage.available)) }
                self.setGameState(id, state)
            }
        }
        gameTask = task
        return task
    }

    private func finishAutomaticSandbox(_ token: GameOperationToken, version: String, completed: Bool,
        deferredForGameUpdate: Bool, failure: LauncherError?) async {
        let id = token.id, services = gameServices
        let status = games[id]?.status ?? .unknown
        let revision = gameRevisions[id]
        let phase = sandboxPhase(for: id)
        let publishedVersion = completed && phase == .finishing ? version : nil
        let snapshot = await Task.detached {
            await readAfterAutomaticSandbox(services, id: id, previousStatus: status, publishedVersion: publishedVersion)
        }.value
        guard gameOperation == token else { return }
        // Play and transient admission failures can retry on a later refresh.
        // An explicit stop or a failed attempt holds the version for this session.
        let deferred: Bool = switch failure {
        case .busy, .installVolumeUnavailable: phase == nil
        default: false
        }
        let stopped = !completed && (failure == nil || failure == .cancelled)
        let yieldedToPlay = automaticSandboxYieldingToPlay == token.generation
        if yieldedToPlay { automaticSandboxYieldingToPlay = nil }
        if deferredForGameUpdate || deferred || (stopped && yieldedToPlay) { automaticSandboxAttempts[id]?.remove(version) }
        if let error = snapshot.error { sandboxFailures[id] = error }
        else if let failure, !deferred, !stopped { sandboxFailures[id] = failure }
        if gameRevisions[id] == revision {
            applyGame(snapshot, id: id, activity: nil, reportError: false)
        } else {
            // Leave a newer volume observation in place.
            if case .success(let state) = snapshot.sandbox { sandboxStates[id] = state }
        }
        let outcome: GameConsumerOutcome = sandboxFailures[id] != nil ? .failed : completed ? .completed : .stopped
        lastGameConsumerOutcome = (token, outcome)
        releaseGame(token, activity: nil)
    }

    func stopGameOperation(_ token: GameOperationToken) async throws -> GameStopOutcome {
        if token.isPreDownload { return try await stopPreDownloadOperation(token) }
        let task = gameOperation == token ? gameTask : nil
        task?.cancel()
        await task?.value
        try await gameServices.waitUntilIdle(token.id)
        let record = try await gameServices.record(token.id)
        setGameRecord(token.id, record)
        guard let final = lastGameConsumerOutcome, final.token == token else { return .failed }
        switch final.outcome {
        case .failed: return .failed
        case .completed: return .finished
        case .stopped:
            if let pending = record?.pending { return .resume(planID: pending.planID.rawValue) }
            if token.isVerification, record?.installed != nil, record?.uninstalling == false { return .verify }
            return .finished
        }
    }

    private func applyGame(_ snapshot: GameSnapshot, id: String, activity: GameActivity?, reportError: Bool = true) {
        setGameRecord(id, snapshot.record)
        if case .success(let state) = snapshot.sandbox { sandboxStates[id] = state }
        if snapshot.record?.installed == nil {
            preDownloadRevisions[id] = UUID()
            preDownloads[id] = nil
        }
        let shortage: GameSpaceShortage?
        if case .paused = snapshot.status { shortage = games[id]?.spaceShortage } else { shortage = nil }
        setGameState(id, GameState(status: snapshot.status, activity: activity, spaceShortage: shortage))
        if reportError, let error = snapshot.error { show(error) }
    }
    private func releaseGame(_ token: GameOperationToken, activity: GameActivity?) {
        guard gameOperation == token else { return }
        var state = games[token.id] ?? GameState(status: .unknown)
        state.activity = activity
        gameProgress = GameProgress()
        setGameState(token.id, state)
        gameOperation = nil; gameTask = nil
        resumeDownloadAfterPlayIfPossible()
    }
    func setGameOperationPhase(_ id: String, phase: OperationPhase) {
        // Batch transitions retain the operation bar, while the actual phase
        // still governs whether pausing is safe during a commit.
        if let state = games[id], case .working(let previous, let fraction, let speed, let downloaded, let total) = state.activity,
            [.staging, .checkingSpace, .committing].contains(previous),
            [.staging, .checkingSpace, .committing].contains(phase) {
            setGameState(id, GameState(status: state.status,
                activity: .working(phase, fraction: fraction, bytesPerSecond: speed, downloaded: downloaded, total: total),
                timing: state.timing))
            return
        }
        setGameState(id, GameState(status: games[id]?.status ?? .unknown,
            activity: .working(phase, fraction: nil, bytesPerSecond: nil)))
    }
    private func updateGameProgress(_ id: String, downloaded: Int64, network: Int64, staged: Int64, totalStaged: Int64) {
        if case .needsApproval = games[id]?.activity { return }
        let phase: OperationPhase
        if case .working(let current, _, _, _, _) = games[id]?.activity { phase = current } else { phase = .staging }
        guard let value = gameProgress.update(at: now(), downloaded: downloaded, network: network, staged: staged,
            totalStaged: totalStaged, phase: GameProgress.trackingPhase(for: phase)) else { return }
        let downloading = phase == .staging && network > 0 && downloaded < network
        setGameState(id, GameState(status: games[id]?.status ?? .unknown,
            activity: .working(phase, fraction: value.fraction, bytesPerSecond: value.speed,
                downloaded: downloading ? downloaded : nil, total: downloading ? network : nil), timing: value.timing))
    }
}

private func gameStream(_ services: any GameServices, id: String, request: GameRequest) async -> GameEventStream {
    switch request {
    case .installSandbox: return await services.installSandbox(id)
    case .updateSandbox: return await services.updateSandbox(id)
    case .automaticSandboxUpdate(let version): return await services.automaticallyUpdateSandbox(id, expectedVersion: version)
    case .removeSandbox: return await services.removeSandbox(id)
    case .install(let voices, let location, let approved): return await services.install(id, voices: voices, at: location, approved: approved)
    case .adopt(let folder, let voices): return await services.adopt(id, folder: folder, voices: voices)
    case .update: return await services.update(id, approved: false)
    case .resume(let approved): return await services.resume(id, approved: approved)
    case .verify: return await services.verify(id, mode: .full)
    case .voices(let voices): return await services.setVoices(id, voices)
    case .move(let folder): return await services.move(id, to: folder)
    case .uninstall:
        do { try await services.uninstall(id); return GameEventStream { $0.yield(.phase(.completed)); $0.finish() } }
        catch { return GameEventStream { $0.finish(throwing: error) } }
    }
}
