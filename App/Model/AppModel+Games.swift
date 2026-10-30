// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import DownloadEngine
import GameLibrary

struct GameOperationToken: Sendable, Equatable {
    let id: String; let generation: UUID
    var kind: OtherRegionActivity = .downloading
    var isVerification = false
    var isUninstall = false
}
private enum GameRequest: Sendable {
    case install(Set<String>, URL, Bool), adopt(URL, Set<String>), update, resume(Bool), verify, voices(Set<String>), uninstall
    var isUninstall: Bool { if case .uninstall = self { true } else { false } }
    func activity(record: GameRecord?) -> OtherRegionActivity {
        switch self {
        case .verify, .adopt: .verifying
        case .update, .uninstall: .updating
        case .resume: record?.pending?.kind == .update ? .updating : record?.pending?.kind == .repair ? .verifying : .downloading
        case .install, .voices: .downloading
        }
    }
}
enum GameStopOutcome: Sendable, Equatable {
    case resume(planID: String), verify, finished, failed
}
enum GameConsumerOutcome: Sendable { case stopped, completed, failed }
private struct GameSnapshot: Sendable {
    let status: GameStatus
    let record: GameRecord?
    var error: LauncherError? = nil
}
@concurrent private func readGame(_ services: any GameServices, id: String) async -> GameSnapshot {
    let status = await services.status(id)
    do { return GameSnapshot(status: status, record: try await services.record(id)) }
    catch { return GameSnapshot(status: status, record: nil, error: launcherError(error)) }
}

@MainActor extension AppModel {
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
        for (id, snapshot) in results where gameRevisions[id] == revisions[id] {
            applyGame(snapshot, id: id, activity: games[id]?.activity)
        }
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
    func resumeGame(_ id: String) { beginGame(id, .resume(false)) }
    func verifyGame(_ id: String) { beginGame(id, .verify) }
    func setVoices(_ id: String, _ voices: Set<String>) { beginGame(id, .voices(voices)) }
    func pauseGame(_ id: String) { if gameOperation?.id == id { gameTask?.cancel() } }
    func approveBatches(_ id: String) {
        guard case .needsApproval = games[id]?.activity else { return }
        beginGame(id, .resume(true)) // Resume the exact saved plan; never rebuild it.
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

    private func reserveGame(_ id: String, activity: GameActivity, kind: OtherRegionActivity, isVerification: Bool, isUninstall: Bool) -> GameOperationToken? {
        guard canBeginGameOrRuntimeOperation() else { return nil }
        guard GameDefinition.all.contains(where: { $0.id == id }) else { show(LauncherError.io("Unknown game")); return nil }
        guard gameOperation == nil else { show(LauncherError.busy("another game operation is running")); return nil }
        let token = GameOperationToken(id: id, generation: UUID(), kind: kind, isVerification: isVerification, isUninstall: isUninstall)
        gameOperation = token; gameRevisions[id] = token.generation
        gameProgress = GameProgress()
        dismissError()
        setGameState(id, GameState(status: games[id]?.status ?? .unknown, activity: activity))
        return token
    }

    @discardableResult private func beginGame(_ id: String, _ request: GameRequest) -> Task<Void, Never>? {
        guard let token = reserveGame(id, activity: request.isUninstall ? .working(.deleting, fraction: nil, bytesPerSecond: nil) : .resolving,
            kind: request.activity(record: gameRecords[id]), isVerification: { if case .verify = request { true } else { false } }(), isUninstall: request.isUninstall) else { return nil }
        let services = gameServices, startup = ensureGameStartup()
        let task = Task { [weak self] in
            var approval: (required: Int64, available: Int64)?
            var failure: LauncherError?
            var completed = false
            do {
                await startup.value
                try Task.checkCancellation()
                if let error = self?.launchStartupError { throw error }
                let stream = await gameStream(services, id: id, request: request)
                events: for try await event in stream {
                    try Task.checkCancellation()
                    guard self?.gameOperation == token else { return }
                    switch event {
                    case .phase(.completed): completed = true; break events
                    case .phase(.cancelled): throw LauncherError.cancelled
                    case .phase(.failed): throw LauncherError.io("Game operation failed")
                    case .failed(let error): throw error
                    case .needsBatchApproval(let required, let available):
                        // Approval becomes actionable only after the stream and
                        // durable snapshot finish and we release the reservation.
                        approval = (required, available)
                    case .phase(let phase):
                        if let record = try? await services.record(id), self?.gameOperation == token {
                            self?.setGameRecord(id, record)
                        }
                        self?.setGameState(id, GameState(status: self?.games[id]?.status ?? .unknown,
                            activity: .working(phase, fraction: nil, bytesPerSecond: nil)))
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
            // Cancellation may have raced with publication. Read the durable state
            // in an uncancelled task, retaining services rather than the model.
            let snapshot = await Task.detached { await readGame(services, id: id) }.value
            guard let self, self.gameOperation == token else { return }
            if let failure { self.show(failure) }
            let activity: GameActivity?
            if !completed, failure == nil, let approval { activity = .needsApproval(required: approval.required, available: approval.available) }
            else { activity = nil }
            self.applyGame(snapshot, id: id, activity: activity, reportError: failure == nil)
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
            // CacheDelete is advisory and potentially slow. Query only this pause,
            // after releasing the operation slot, never from the progress stream.
            if let shortage = self.games[id]?.spaceShortage, shortage.isMeasured,
                let location = snapshot.record?.installPath {
                let probe = self.purgeableSpace
                let important = try? await BlockingIO.run { probe.importantUsageBytes(at: location) }
                guard self.gameRevisions[id] == token.generation,
                    var state = self.games[id], state.activity == activity, state.spaceShortage == shortage else { return }
                state.spaceShortage?.purgeable = important.map { max(0, max(0, $0) - max(0, shortage.available)) }
                self.setGameState(id, state)
            }
        }
        gameTask = task
        return task
    }

    func stopGameOperation(_ token: GameOperationToken) async throws -> GameStopOutcome {
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
        let shortage: GameSpaceShortage?
        if case .paused = snapshot.status { shortage = games[id]?.spaceShortage } else { shortage = nil }
        setGameState(id, GameState(status: snapshot.status, activity: activity, spaceShortage: shortage))
        if reportError, let error = snapshot.error { show(error) }
    }
    private func releaseGame(_ token: GameOperationToken, activity: GameActivity?) {
        guard gameOperation == token else { return }
        var state = games[token.id] ?? GameState(status: .unknown)
        state.activity = activity
        setGameState(token.id, state)
        gameOperation = nil; gameTask = nil; gameProgress = GameProgress()
    }
    private func updateGameProgress(_ id: String, downloaded: Int64, network: Int64, staged: Int64, totalStaged: Int64) {
        if case .needsApproval = games[id]?.activity { return }
        let phase: OperationPhase
        if case .working(let current, _, _, _, _) = games[id]?.activity { phase = current } else { phase = .staging }
        guard let value = gameProgress.update(at: now(), downloaded: downloaded, network: network, staged: staged,
            totalStaged: totalStaged, phase: phase) else { return }
        let downloading = phase == .staging && network > 0
        setGameState(id, GameState(status: games[id]?.status ?? .unknown,
            activity: .working(phase, fraction: value.fraction, bytesPerSecond: value.speed,
                downloaded: downloading ? downloaded : nil, total: downloading ? network : nil), timing: value.timing))
    }
}

private func gameStream(_ services: any GameServices, id: String, request: GameRequest) async -> GameEventStream {
    switch request {
    case .install(let voices, let location, let approved): return await services.install(id, voices: voices, at: location, approved: approved)
    case .adopt(let folder, let voices): return await services.adopt(id, folder: folder, voices: voices)
    case .update: return await services.update(id, approved: false)
    case .resume(let approved): return await services.resume(id, approved: approved)
    case .verify: return await services.verify(id, mode: .full)
    case .voices(let voices): return await services.setVoices(id, voices)
    case .uninstall:
        do { try await services.uninstall(id); return GameEventStream { $0.yield(.phase(.completed)); $0.finish() } }
        catch { return GameEventStream { $0.finish(throwing: error) } }
    }
}
