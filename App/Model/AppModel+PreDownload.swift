// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import GameLibrary

struct PreDownloadProgress: Sendable, Equatable {
    var phase: OperationPhase = .staging
    var isResolving = true
    var downloaded: Int64 = 0
    var total: Int64 = 0
    var fraction: Double?
    var bytesPerSecond: Int64?
    var timing: GameTiming?
}

/// Delivery cache state never replaces the installed game's primary action.
struct PreDownloadOverlay: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case unavailable, available(version: String, bytes: Int64), downloading(PreDownloadProgress), paused, ready(version: String)
    }
    var state: State
    var info: PreDownloadInfo
    var canDelete: Bool { info.canDelete }
    var progress: PreDownloadProgress? { if case .downloading(let progress) = state { progress } else { nil } }
    init(info: PreDownloadInfo = .unavailable) {
        self.info = info
        state = switch info.state {
        case .unavailable: .unavailable
        case .available: .available(version: info.version ?? "", bytes: info.bytes)
        case .paused: .paused
        case .ready: .ready(version: info.version ?? "")
        }
    }
}

@MainActor extension AppModel {
    func preDownloadState(for id: String) -> PreDownloadOverlay { preDownloads[id] ?? PreDownloadOverlay() }

    func refreshPreDownloads(in region: Region) async {
        let services = gameServices, revisions = preDownloadRevisions
        let ids = GameDefinition.inRegion(region).map(\.id).filter { gameOperation?.id != $0 }
        let results = await withTaskGroup(of: (String, PreDownloadInfo?).self) { group in
            for id in ids { group.addTask { (id, try? await services.preDownloadInfo(id, refresh: true)) } }
            var results: [(String, PreDownloadInfo?)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard !Task.isCancelled else { return }
        for (id, info) in results where preDownloadRevisions[id] == revisions[id] && gameOperation?.id != id {
            if let info { preDownloads[id] = PreDownloadOverlay(info: info) }
        }
    }

    func startPreDownload(_ id: String) { beginPreDownload(id, resume: false) }
    func resumePreDownload(_ id: String, expectedPlanID: String? = nil, expectedPlanDigest: Digest? = nil) {
        beginPreDownload(id, resume: true, expectedPlanID: expectedPlanID, expectedPlanDigest: expectedPlanDigest)
    }
    func pausePreDownload(_ id: String) {
        guard gameOperation?.id == id, gameOperation?.isPreDownload == true, gameOperation?.isUninstall == false else { return }
        gameTask?.cancel()
    }

    func deletePreDownload(_ id: String) async {
        guard preDownloadState(for: id).canDelete,
            let token = reservePreDownload(id, deleting: true) else { return }
        let services = gameServices, startup = ensureGameStartup()
        let task = Task { [weak self] in
            do {
                await startup.value
                try Task.checkCancellation()
                if let error = self?.launchStartupError { throw error }
                try await services.deletePreDownload(id)
            } catch { self?.show(error) }
            await self?.finishPreDownload(token, services: services, completed: false, failed: false)
        }
        gameTask = task
        await task.value
    }

    private func reservePreDownload(_ id: String, deleting: Bool = false) -> GameOperationToken? {
        guard canBeginGameOrRuntimeOperation(), GameDefinition.find(id) != nil else { return nil }
        guard gameOperation == nil else { show(LauncherError.busy("another game operation is running")); return nil }
        guard launchSlotOwner != id, launchTasks[id] == nil, !liveLaunchGames.contains(id) else { return nil }
        if case .recoveryNeeded = launchStates[id] { return nil }
        let token = GameOperationToken(id: id, generation: UUID(), isUninstall: deleting, isPreDownload: true)
        gameOperation = token; gameRevisions[id] = token.generation; preDownloadRevisions[id] = token.generation
        gameUpdateCheck[id] = nil
        gameProgress = GameProgress(); dismissError()
        if !deleting {
            var overlay = preDownloadState(for: id)
            overlay.state = .downloading(PreDownloadProgress(downloaded: overlay.info.downloaded, total: overlay.info.bytes))
            preDownloads[id] = overlay
        }
        return token
    }

    private func beginPreDownload(_ id: String, resume: Bool, expectedPlanID: String? = nil, expectedPlanDigest: Digest? = nil) {
        guard let token = reservePreDownload(id) else { return }
        let services = gameServices, startup = ensureGameStartup()
        let savedID = expectedPlanID ?? preDownloads[id]?.info.planID?.rawValue
        gameTask = Task { [weak self] in
            var completed = false, failed = false
            do {
                await startup.value
                try Task.checkCancellation()
                if let error = self?.launchStartupError { throw error }
                if let expectedPlanDigest {
                    let info = try await services.preDownloadInfo(id, refresh: false)
                    guard info.state == .paused, info.planID?.rawValue == savedID, info.planDigest == expectedPlanDigest else {
                        throw LauncherError.cancelled
                    }
                }
                let stream = if resume { await services.resumePreDownload(id, expectedPlanID: savedID) }
                    else { await services.preDownload(id) }
                events: for try await event in stream {
                    try Task.checkCancellation()
                    guard self?.gameOperation == token else { return }
                    switch event {
                    case .phase(.completed): completed = true; break events
                    case .phase(.cancelled): throw LauncherError.cancelled
                    case .phase(.failed): throw LauncherError.io("Game operation failed")
                    case .failed(let error): throw error
                    case .needsBatchApproval(let required, let available):
                        throw LauncherError.insufficientSpace(required: required, available: available)
                    case .phase(let phase):
                        self?.updatePreDownloadPhase(id, phase: phase)
                    case .progress(let downloaded, let network, _, _):
                        self?.updatePreDownloadProgress(id, downloaded: downloaded, total: network)
                    case .fileVerified: break
                    }
                }
            } catch {
                let error = launcherError(error)
                failed = error != .cancelled
                self?.show(error)
            }
            await self?.finishPreDownload(token, services: services, completed: completed, failed: failed)
        }
    }

    private func updatePreDownloadPhase(_ id: String, phase: OperationPhase) {
        var overlay = preDownloadState(for: id), progress = preDownloadState(for: id).progress ?? PreDownloadProgress()
        progress.phase = phase; progress.isResolving = false
        overlay.state = .downloading(progress); preDownloads[id] = overlay
    }

    private func updatePreDownloadProgress(_ id: String, downloaded: Int64, total: Int64) {
        var overlay = preDownloadState(for: id), progress = preDownloadState(for: id).progress ?? PreDownloadProgress()
        progress.isResolving = false; progress.downloaded = downloaded; progress.total = total
        progress.fraction = total > 0 ? min(1, max(0, Double(downloaded) / Double(total))) : nil
        if let value = gameProgress.update(at: now(), downloaded: downloaded, network: total, staged: 0,
            totalStaged: 0, phase: progress.phase) {
            progress.bytesPerSecond = value.speed; progress.timing = value.timing
        }
        overlay.state = .downloading(progress); preDownloads[id] = overlay
    }

    private func finishPreDownload(_ token: GameOperationToken, services: any GameServices, completed: Bool, failed: Bool) async {
        // Cancellation of the consumer must not cancel the pipeline join or local status read.
        let (drained, result) = await Task.detached { () -> (Bool, Result<PreDownloadInfo, LauncherError>) in
            do { try await services.waitUntilIdle(token.id) }
            catch { return (false, .failure(launcherError(error))) }
            do { return (true, .success(try await services.preDownloadInfo(token.id, refresh: false))) }
            catch { return (true, .failure(launcherError(error))) }
        }.value
        guard gameOperation == token else { return }
        switch result {
        case .success(let info):
            preDownloads[token.id] = PreDownloadOverlay(info: info)
            lastGameConsumerOutcome = (token, failed ? .failed : completed ? .completed : .stopped)
            gameOperation = nil; gameTask = nil; gameProgress = GameProgress()
        case .failure(let error):
            lastGameConsumerOutcome = (token, .failed)
            if drained {
                var overlay = preDownloadState(for: token.id)
                overlay.state = .paused; preDownloads[token.id] = overlay
                gameOperation = nil; gameTask = nil; gameProgress = GameProgress()
            }
            // Only unknown drainage retains the reservation. A cache-read error
            // cannot hold every unrelated game/runtime operation indefinitely.
            show(error)
        }
    }

    func stopPreDownloadOperation(_ token: GameOperationToken) async throws -> GameStopOutcome {
        let task = gameOperation == token ? gameTask : nil
        task?.cancel(); await task?.value
        try await gameServices.waitUntilIdle(token.id)
        let info = try await gameServices.preDownloadInfo(token.id, refresh: false)
        preDownloads[token.id] = PreDownloadOverlay(info: info)
        // A successful retry can release a reservation retained after a failed drain.
        if gameOperation == token { gameOperation = nil; gameTask = nil; gameProgress = GameProgress() }
        guard let final = lastGameConsumerOutcome, final.token == token else { return .failed }
        guard final.outcome != .failed else { return .failed }
        if info.state == .paused, let planID = info.planID, let digest = info.planDigest {
            return .preDownload(planID: planID.rawValue, planDigest: digest)
        }
        return .finished
    }
}
