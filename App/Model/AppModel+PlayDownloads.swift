// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import GameLibrary
import LauncherCore

/// Before metadata publishes a plan, retain the user's exact delivery request
/// and the source record. A changed installation never inherits that request.
struct PlayUnplannedDownload: Sendable, Equatable {
    enum Request: Sendable, Equatable { case install(Set<String>, URL, Bool), update, preDownload(PreDownloadInfo) }
    let request: Request
    let record: GameRecord?
}

/// A one-shot continuation exists only for work stopped by this Play attempt.
struct PlayPausedDownload {
    enum Plan { case game(PendingOperation), preDownload(String, Digest), unresolved(PlayUnplannedDownload) }
    let token: GameOperationToken
    let plan: Plan
}

@MainActor extension AppModel {
    /// A session keeps its own edition exclusive, including preparation/recovery.
    /// Only delivery work on another edition can share the session.
    func canOperateGameDuringPlay(_ id: String, isDownload: Bool) -> Bool {
        guard launchSlotOwner != id, launchTasks[id] == nil, !liveLaunchGames.contains(id) else { return false }
        switch launchStates[id] {
        case .starting, .running, .ready, .recoveryNeeded: return false
        case .failed, nil: break
        }
        let hasSession = launchSlotOwner != nil || !launchTasks.isEmpty || !liveLaunchGames.isEmpty || launchStates.values.contains {
            switch $0 {
            case .starting, .running, .ready, .recoveryNeeded: true
            case .failed: false
            }
        }
        guard hasSession else { return true }
        guard isDownload, globalLaunchSettings.downloadWhilePlaying else { return false }
        // Unknown/recovering processes retain the ordinary safety exclusion.
        return !launchStates.values.contains { if case .recoveryNeeded = $0 { true } else { false } }
    }

    func canPlayAlongsideGameOperation(_ id: String) -> Bool {
        guard let operation = gameOperation else { return true }
        if operation.id == id { return operation.yieldsToPlay }
        return operation.permitsOtherGamePlay || operation.automaticSandboxVersion != nil
    }

    func cancelPlayDownloadResume(for id: String) {
        playDownloadResumeInvalidations[id] = UUID()
        guard pausedDownloadForPlay?.token.id == id else { return }
        playDownloadResumeWatchID = nil
        pausedDownloadForPlay = nil
    }

    func pauseDownloadForPlay(_ token: GameOperationToken) async throws {
        let intent = playDownloadResumeInvalidations[token.id]
        let outcome = try await stopGameOperation(token)
        guard playDownloadResumeInvalidations[token.id] == intent else { return }
        // A space-approval pause belongs to the queue's explicit Retry flow.
        // Do not install an ineligible continuation after its consumer drains.
        if token.isQueuedUpdate, updateQueue.entries.first(where: { $0.id == token.id })?.paused != false { return }
        switch outcome {
        case .preDownload(let planID, let digest):
            pausedDownloadForPlay = PlayPausedDownload(token: token, plan: .preDownload(planID, digest))
        case .resume(let planID):
            guard let pending = gameRecords[token.id]?.pending, pending.planID.rawValue == planID else { return }
            pausedDownloadForPlay = PlayPausedDownload(token: token, plan: .game(pending))
        case .finished:
            if let initial = token.unplannedDownload, lastGameConsumerOutcome?.token == token,
                lastGameConsumerOutcome?.outcome == .stopped, gameRecords[token.id] == initial.record {
                pausedDownloadForPlay = PlayPausedDownload(token: token, plan: .unresolved(initial))
            }
        case .verify, .failed: break
        }
        resumeDownloadAfterPlayIfPossible()
    }

    /// Called only once the core confirms finalization, or a preflight failure
    /// releases its slot. Durable identity is rechecked immediately before start.
    func resumeDownloadAfterPlayIfPossible() {
        guard let saved = pausedDownloadForPlay else { return }
        guard canResumePlayDownload(saved), !isResumingPlayDownload else { watchPlayDownloadResume(saved); return }
        playDownloadResumeWatchID = nil
        isResumingPlayDownload = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isResumingPlayDownload = false }
            guard self.canResumePlayDownload(saved) else { self.watchPlayDownloadResume(saved); return }
            do {
                switch saved.plan {
                case .game(let pending):
                    let record = try await self.gameServices.record(saved.token.id)
                    guard self.canResumePlayDownload(saved) else { self.watchPlayDownloadResume(saved); return }
                    guard record?.pending == pending, record?.uninstalling == false else { self.discardPlayDownloadResume(saved); return }
                    self.setGameRecord(saved.token.id, record)
                    if saved.token.isQueuedUpdate { self.beginQueuedGame(saved.token.id, pending: pending) }
                    else { self.resumeGame(saved.token.id, expectedPending: pending) }
                case .unresolved(let initial):
                    let record = try await self.gameServices.record(saved.token.id)
                    guard self.canResumePlayDownload(saved) else { self.watchPlayDownloadResume(saved); return }
                    guard record == initial.record, record?.pending == nil, record?.uninstalling != true else {
                        self.discardPlayDownloadResume(saved); return
                    }
                    if case .preDownload(let offer) = initial.request {
                        let current = try await self.gameServices.preDownloadInfo(saved.token.id, refresh: false)
                        guard self.canResumePlayDownload(saved) else { self.watchPlayDownloadResume(saved); return }
                        guard current == offer else { self.discardPlayDownloadResume(saved); return }
                    }
                    self.setGameRecord(saved.token.id, record)
                    if saved.token.isQueuedUpdate { self.beginQueuedGame(saved.token.id, initial: initial) }
                    else { self.resumeUnplannedDownload(initial, for: saved.token.id) }
                case .preDownload(let planID, let digest):
                    let info = try await self.gameServices.preDownloadInfo(saved.token.id, refresh: false)
                    guard self.canResumePlayDownload(saved) else { self.watchPlayDownloadResume(saved); return }
                    guard info.state == .paused, info.planID?.rawValue == planID, info.planDigest == digest else {
                        self.discardPlayDownloadResume(saved); return
                    }
                    self.preDownloads[saved.token.id] = PreDownloadOverlay(info: info)
                    self.resumePreDownload(saved.token.id, expectedPlanID: planID, expectedPlanDigest: digest)
                }
            } catch {
                // A suspended read belongs to this saved token. A newer pause
                // may already have replaced it while that read was in flight.
                guard self.pausedDownloadForPlay?.token == saved.token else { return }
                self.discardPlayDownloadResume(saved)
                if saved.token.isQueuedUpdate { self.holdQueuedUpdate(saved.token.id, failure: .operation(launcherError(error))) }
                else { self.show(error) }
            }
        }
    }

    private func discardPlayDownloadResume(_ saved: PlayPausedDownload) {
        guard pausedDownloadForPlay?.token == saved.token else { return }
        cancelPlayDownloadResume(for: saved.token.id)
    }

    /// Called by the global preference observer; the consumer joins its pipeline
    /// before the one-shot continuation can become eligible again.
    func downloadWhilePlayingChanged() {
        if globalLaunchSettings.downloadWhilePlaying {
            resumeDownloadAfterPlayIfPossible()
            return
        }
        guard playDownloadPauseTask == nil, let operation = gameOperation,
            operation.permitsOtherGamePlay, let owner = launchSlotOwner, owner != operation.id else { return }
        playDownloadPauseTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playDownloadPauseTask = nil }
            do { try await self.pauseDownloadForPlay(operation) }
            catch {
                if operation.isQueuedUpdate { self.holdQueuedUpdate(operation.id, failure: .operation(launcherError(error))) }
                else { self.show(error) }
            }
            self.resumeDownloadAfterPlayIfPossible()
        }
    }

    /// A runtime reservation or another game's operation can win during a
    /// durable read. Keep the continuation and retry when its blocker changes.
    private func watchPlayDownloadResume(_ saved: PlayPausedDownload) {
        guard playDownloadResumeWatchID == nil else { return }
        let generation = UUID()
        playDownloadResumeWatchID = generation
        withObservationTracking {
            _ = canResumePlayDownload(saved)
            _ = isResumingPlayDownload
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.playDownloadResumeWatchID == generation else { return }
                self.playDownloadResumeWatchID = nil
                self.resumeDownloadAfterPlayIfPossible()
            }
        }
    }

    private func playDownloadCanResumeInCurrentSession(_ id: String) -> Bool {
        if launchSlotOwner == nil, launchTasks.isEmpty, liveLaunchGames.isEmpty,
            !launchStates.values.contains(where: {
                switch $0 {
                case .starting, .running, .ready, .recoveryNeeded: true
                case .failed: false
                }
            }) { return true }
        return globalLaunchSettings.downloadWhilePlaying && canOperateGameDuringPlay(id, isDownload: true)
    }

    private func canResumePlayDownload(_ saved: PlayPausedDownload) -> Bool {
        pausedDownloadForPlay?.token == saved.token && queuedPlayContinuationPermitted(saved.token) && gameOperation == nil && playDownloadCanResumeInCurrentSession(saved.token.id) &&
            languageRestart == nil && !updater.isInstallingUpdate && !storageCleanupInProgress && prefixResetGame == nil &&
            !gameMoveRecoveryReservation && runtimeCatalogMutationID == nil
    }
}
