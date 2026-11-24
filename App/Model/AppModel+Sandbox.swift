// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import GameLibrary

@MainActor extension AppModel {
    func sandboxState(for id: String) -> SandboxState? { sandboxStates[id] }
    func sandboxFailure(for id: String) -> LauncherError? { sandboxFailures[id] }
    func dismissSandboxFailure(_ id: String) { sandboxFailures[id] = nil }
    func sandboxPhase(for id: String) -> SandboxPhase? { games[id]?.sandboxPhase }
    func isAutomaticallyUpdatingSandbox(_ id: String) -> Bool { games[id]?.isAutomaticSandboxUpdate == true }
    func cancelAutomaticSandboxUpdate(_ id: String) {
        guard isAutomaticallyUpdatingSandbox(id) else { return }
        pauseGame(id)
    }

    func canInstallSandbox(_ id: String) -> Bool {
        guard canOperateSandbox(id), case .notInstalled = sandboxState(for: id) else { return false }
        return true
    }

    func canUpdateSandbox(_ id: String) -> Bool {
        guard canOperateSandbox(id), case .outdated = sandboxState(for: id) else { return false }
        return true
    }

    func canRemoveSandbox(_ id: String) -> Bool {
        canOperateSandbox(id) && gameRecords[id]?.sandbox != nil
    }

    private func canOperateSandbox(_ id: String) -> Bool {
        guard GameDefinition.find(id)?.family == .genshin, canOperateGameDuringPlay(id, isDownload: false),
            languageRestart == nil, !updater.isInstallingUpdate, !storageCleanupInProgress,
            prefixResetGame == nil, !gameMoveRecoveryReservation, runtimeCatalogMutationID == nil,
            launchStartupError == nil, gameOperation == nil, games[id]?.activity == nil,
            gameRecords[id]?.installed != nil, gameRecords[id]?.pending == nil,
            gameRecords[id]?.uninstalling == false, launchSlotOwner != id, launchTasks[id] == nil,
            !liveLaunchGames.contains(id), !launchRecoveryConflicts.contains(id),
            !recoveryNotices.contains(where: { $0.game == id }) else { return false }
        switch launchStates[id] {
        case .starting, .running, .ready, .recoveryNeeded: return false
        case nil, .failed: break
        }
        switch games[id]?.status {
        case .installed, .updateAvailable: return true
        default: return false
        }
    }

    /// The footer can use this instead of the ordinary game's phase label.
    func sandboxPhaseLabel(for id: String) -> String? {
        switch sandboxPhase(for: id) {
        case .downloading: String(localized: "Downloading Miliastra Sandbox…")
        case .extracting: String(localized: "Extracting Miliastra Sandbox…")
        case .finishing: String(localized: "Finishing Miliastra Sandbox…")
        case .removing: String(localized: "Removing Miliastra Sandbox…")
        case .verifying: String(localized: "Verifying Miliastra Sandbox…")
        case nil: nil
        }
    }

    func setSandboxOperationPhase(_ id: String, phase: SandboxPhase) {
        guard gameOperation?.id == id, gameProgress.sandboxPhase != phase else { return }
        gameProgress.beginSandboxPhase(phase)
        let operationPhase: OperationPhase = switch phase {
        case .downloading, .extracting: .staging
        case .finishing: .committing
        case .removing: .deleting
        case .verifying: .verifying
        }
        let time = now()
        setGameState(id, GameState(status: games[id]?.status ?? .unknown,
            activity: .working(operationPhase, fraction: nil, bytesPerSecond: nil),
            timing: GameTiming(phaseStarted: time, lastAdvance: time, remaining: nil, hasFraction: false)))
    }
}
