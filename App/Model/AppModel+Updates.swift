// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import LauncherCore

@MainActor protocol AppUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var isInstallingUpdate: Bool { get }
    func start(isBusy: @escaping @MainActor () -> Bool)
    func checkForUpdates()
}

/// Preview and test models never create Sparkle's controller or perform checks.
@MainActor @Observable final class InertAppUpdater: AppUpdating {
    let canCheckForUpdates = false
    let isInstallingUpdate = false
    var automaticallyChecksForUpdates = false
    func start(isBusy: @escaping @MainActor () -> Bool) {}
    func checkForUpdates() {}
}

@MainActor extension AppModel {
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func canBeginGameOrRuntimeOperation() -> Bool {
        guard !updater.isInstallingUpdate else {
            show(LauncherError.busy("Application update is installing"))
            return false
        }
        return true
    }

    /// Reservations outlive UI progress and keep draining or recovering work safe.
    var isBusyForUpdates: Bool {
        isStarting || launchSlotOwner != nil || liveSessionGameName != nil ||
            launchStates.values.contains { if case .recoveryNeeded = $0 { true } else { false } } ||
            isGameOperationRunning || isRuntimeOperationRunning || consentRequest != nil || importState != nil ||
            runtimeSetupProgress.values.contains { if case .installing = $0 { true } else { false } }
    }
}

/// Sparkle's install handler is single-use. Re-read reservations on delivery,
/// since another operation may have started since the idle notification.
@MainActor @Observable final class UpdateRelaunchGate {
    private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private var pendingRelaunch: (() -> Void)?
    private(set) var isInstallingUpdate = false
    init(isBusy: @escaping @MainActor () -> Bool) { self.isBusy = isBusy }

    func postponeRelaunch(_ resume: @escaping () -> Void) -> Bool {
        guard isBusy() else { isInstallingUpdate = true; return false }
        pendingRelaunch = resume
        refresh()
        return true
    }

    func refresh() {
        guard pendingRelaunch != nil else { return }
        let busy = withObservationTracking { isBusy() } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        guard !busy else { return }
        let resume = pendingRelaunch
        pendingRelaunch = nil
        isInstallingUpdate = true
        resume?()
    }

    func installationAborted() {
        pendingRelaunch = nil
        isInstallingUpdate = false
    }
}
