// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch

@MainActor extension AppModel {
    /// Explicit retries, activation and the backoff ticker all use the same
    /// guarded core path. A watcher that still owns the session returns busy.
    func retryRecovery(_ id: String) {
        guard case .recoveryNeeded = launchStates[id], recoveryInFlight[id] == nil else { return }
        let generation = observationGeneration(id)
        recoveryInFlight[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.launchObservationGenerations[id] == generation { self.recoveryInFlight[id] = nil } }
            do { try await self.launchServices.recover(id) }
            catch { /* Busy or unavailable storage retains ownership and retries. */ }
            guard !Task.isCancelled, self.launchObservationGenerations[id] == generation else { return }
            _ = await self.refreshLaunchSession(id)
        }
    }

    func retryRecoveriesOnActivation() {
        for id in launchStates.keys.sorted() {
            if case .recoveryNeeded = launchStates[id] { retryRecovery(id) }
        }
    }

    func recordVerifiedEnd(_ id: String) {
        knownEndedLaunchGames.insert(id)
        liveLaunchGames.remove(id)
        switch launchStates[id] {
        case .starting, .running, .ready: launchStates[id] = nil
        case .failed, .recoveryNeeded, nil: break
        }
        launchWindows.ended(gameID: id)
        // Keep the reservation: file recovery and final directory sync can fail.
    }

    func showRecovery(_ id: String) {
        launchSlotOwner = id
        if launchRecoveryConflicts.contains(id) {
            launchStates[id] = .recoveryNeeded(String(localized: "Some game files aren't back yet. MacGacha keeps trying — or choose Try Restoring Again in the … menu."))
        } else {
            launchStates[id] = .recoveryNeeded(String(localized: "MacGacha is putting the game's files back. You can play when it's done."))
        }
        scheduleRecoveryRetry(id)
    }

    func applySession(_ session: LaunchSession, id: String) async {
        launchObservationGenerations[id] = UUID()
        knownEndedLaunchGames.remove(id); launchFailures[id] = nil
        launchSlotOwner = id; liveLaunchGames.insert(id)
        launchLogURLs[id] = session.sessionLogURL
        _ = await refreshLaunchSession(id)
    }

    /// Nil is authoritative finalization, rather than an inferred outcome from
    /// .conflict or .clean. Throwing observations never authorize clearing state.
    @discardableResult func refreshLaunchSession(_ id: String) async -> Bool {
        let generation = observationGeneration(id)
        do {
            let observation = try await launchServices.observation(id)
            guard !Task.isCancelled, launchObservationGenerations[id] == generation else { return true }
            guard let observation else {
                recordVerifiedEnd(id)
                // Load notices before cancelling this observer's ticker, so its
                // cancellation cannot suppress the BlockingIO-backed notice read.
                let notices = try? await launchServices.notices()
                guard !Task.isCancelled, launchObservationGenerations[id] == generation else { return true }
                finishLaunchObservation(id)
                recoveryNotices = notices ?? recoveryNotices
                return true
            }
            launchSlotOwner = id
            // A read captured before termination may return after a newer end
            // observation. Verified end is irreversible until the next attempt.
            let hasEnded = observation.hasEnded || knownEndedLaunchGames.contains(id)
            if hasEnded { recordVerifiedEnd(id) }
            else { liveLaunchGames.insert(id) }
            switch observation.session.state {
            case .running where !hasEnded:
                if launchStates[id] != .ready && launchStates[id] != .running {
                    launchStates[id] = .running; observeGameWindow(id)
                }
                recoveryRetryTasks[id]?.cancel(); recoveryRetryTasks[id] = nil
            case .recoveryConflict:
                launchRecoveryConflicts.insert(id); showRecovery(id)
            case .recoveryPending, .restoring, .done, .ending:
                showRecovery(id)
            default:
                if hasEnded { showRecovery(id) }
                else if case .recoveryNeeded = launchStates[id] {} else { launchStates[id] = .starting(.watch) }
            }
            monitorUncertainLaunch(id)
        } catch {
            guard !Task.isCancelled, launchObservationGenerations[id] == generation else { return true }
            showRecovery(id); monitorUncertainLaunch(id)
        }
        return false
    }

    private func finishLaunchObservation(_ id: String) {
        // Retire every in-flight observation of this session before releasing
        // its slot; an older read must not resurrect a finalized context.
        launchObservationGenerations[id] = UUID()
        recoveryInFlight[id] = nil
        recordVerifiedEnd(id)
        launchRecoveryPolls[id]?.cancel(); launchRecoveryPolls[id] = nil
        recoveryRetryTasks[id]?.cancel(); recoveryRetryTasks[id] = nil
        if reattachedLaunchMonitors.remove(id) != nil {
            launchTasks[id]?.cancel(); launchTasks[id] = nil; launchTaskGenerations[id] = nil
        }
        if let failure = launchFailures[id] { launchStates[id] = .failed(failure) }
        else if case .failed = launchStates[id] {} else { launchStates[id] = nil }
        if launchSlotOwner == id {
            launchSlotOwner = launchStates.keys.sorted().first { game in
                guard game != id else { return false }
                switch launchStates[game] {
                case .starting, .running, .ready, .recoveryNeeded: return true
                case .failed, nil: return false
                }
            }
        }
        launchRecoveryConflicts.remove(id)
    }

    private func observationGeneration(_ id: String) -> UUID {
        if let generation = launchObservationGenerations[id] { return generation }
        let generation = UUID(); launchObservationGenerations[id] = generation
        return generation
    }

    private func scheduleRecoveryRetry(_ id: String) {
        guard recoveryRetryTasks[id] == nil else { return }
        let generation = observationGeneration(id), sleep = recoverySleep
        recoveryRetryTasks[id] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay: Duration = attempt == 0 ? .seconds(5) : attempt == 1 ? .seconds(15) : .seconds(60)
                do { try await sleep(delay) } catch { return }
                guard let self, !Task.isCancelled, self.launchObservationGenerations[id] == generation else { return }
                guard case .recoveryNeeded = self.launchStates[id] else { return }
                self.retryRecovery(id)
                await self.recoveryInFlight[id]?.value
                attempt += 1
            }
        }
    }

    func monitorUncertainLaunch(_ id: String) {
        guard launchRecoveryPolls[id] == nil, !reattachedLaunchMonitors.contains(id) else { return }
        let generation = observationGeneration(id), sleep = launchSleep
        launchRecoveryPolls[id] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep() } catch { return }
                guard let self, !Task.isCancelled, self.launchObservationGenerations[id] == generation else { return }
                if await self.refreshLaunchSession(id) { return }
            }
        }
    }

    func monitorReattached(_ id: String) {
        let generation = UUID(), observation = observationGeneration(id), sleep = launchSleep
        launchTaskGenerations[id] = generation; reattachedLaunchMonitors.insert(id)
        launchRecoveryPolls[id]?.cancel(); launchRecoveryPolls[id] = nil
        launchTasks[id] = Task { [weak self] in
            defer {
                if self?.launchTaskGenerations[id] == generation {
                    self?.launchTasks[id] = nil; self?.launchTaskGenerations[id] = nil; self?.reattachedLaunchMonitors.remove(id)
                }
            }
            while !Task.isCancelled {
                do { try await sleep() } catch { return }
                guard let self, !Task.isCancelled, self.launchObservationGenerations[id] == observation else { return }
                if await self.refreshLaunchSession(id) { return }
            }
        }
    }
}
