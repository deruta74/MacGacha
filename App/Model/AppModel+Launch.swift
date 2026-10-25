// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Foundation
import LauncherCore
import Launch
import GameLibrary
import RuntimeManager

@MainActor extension AppModel {
    func launchState(for id: String) -> LaunchUIState? { launchStates[id] }
    func launchSettings(for id: String) -> LaunchSettings { launchSettingsCache[id] ?? .defaults(for: id) }

    /// The synchronous view API validates immediately and updates its observable
    /// snapshot. Serialized durable writes leave the main actor; Play and export
    /// join the queue, and a write failure is surfaced rather than launching with
    /// an unpersisted setting.
    func saveLaunchSettings(_ settings: LaunchSettings, for id: String) throws {
        guard GameDefinition.all.contains(where: { $0.id == id }),
            settings.frameLimit.map({ [30, 60, 120].contains($0) }) ?? true else {
            throw LauncherError.io("Invalid launch settings")
        }
        let revision = UUID(), preferences = launchPreferences
        launchSettingsRevision = revision; launchSettingsRevisions[id] = revision; launchSettingsCache[id] = settings
        enqueueSettingsWrite(key: id) {
            try preferences.save(settings, game: id)
        } didCommit: { [weak self] in self?.durableLaunchSettings[id] = settings } rollback: { [weak self] in
            guard let self, self.launchSettingsRevisions[id] == revision else { return }
            self.launchSettingsCache[id] = self.durableLaunchSettings[id] ?? .defaults(for: id)
        }
    }

    var sessionLogsEnabled: Bool {
        get { globalLaunchSettings.sessionLogsEnabled }
        set {
            let preferences = launchPreferences
            globalLaunchSettings.sessionLogsEnabled = newValue
            let settings = globalLaunchSettings, revision = UUID()
            launchSettingsRevision = revision; launchSettingsRevisions["global"] = revision
            enqueueSettingsWrite(key: "global") { try preferences.saveGlobal(settings) } didCommit: { [weak self] in
                self?.durableGlobalLaunchSettings = settings
            } rollback: { [weak self] in
                guard let self, self.launchSettingsRevisions["global"] == revision else { return }
                self.globalLaunchSettings = self.durableGlobalLaunchSettings
            }
        }
    }

    private func enqueueSettingsWrite(key: String, _ write: @escaping @Sendable () throws -> Void,
        didCommit: @escaping @MainActor () -> Void, rollback: @escaping @MainActor () -> Void) {
        let previous = settingsWriteTask
        settingsWriteTask = Task { [weak self] in
            await previous?.value
            do { try await BlockingIO.run(write); didCommit(); self?.settingsWriteErrors[key] = nil }
            catch { rollback(); self?.settingsWriteErrors[key] = launcherError(error); self?.show(error) }
        }
    }
    func flushLaunchSettings() async throws {
        // A view can enqueue another write while this task is suspended.
        while let task = settingsWriteTask {
            let revision = launchSettingsRevision
            await task.value
            if launchSettingsRevision == revision { break }
        }
        if let error = settingsWriteErrors.sorted(by: { $0.key < $1.key }).first?.value { throw error }
    }

    func reattachOnStart() async {
        if let task = launchStartupTask { await task.value; return }
        let services = launchServices, preferences = launchPreferences
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // Recovery runs first even if launch preferences are corrupt.
                let startup = try await services.startupReattachment()
                for id in startup.unresolved.sorted() {
                    self.liveLaunchGames.insert(id)
                    self.showRecovery(id)
                    self.monitorUncertainLaunch(id)
                }
                for (id, session) in startup.sessions {
                    await self.applySession(session, id: id)
                    if self.launchSlotOwner == id { self.monitorReattached(id) }
                }
                self.recoveryNotices = try await services.notices()
                try await self.flushLaunchSettings()
                let revisions = self.launchSettingsRevisions
                let settings = try await BlockingIO.run {
                    (try preferences.loadGames(), try preferences.loadGlobal())
                }
                for (id, value) in settings.0 where revisions[id] == self.launchSettingsRevisions[id] {
                    self.launchSettingsCache[id] = value; self.durableLaunchSettings[id] = value
                }
                if revisions["global"] == self.launchSettingsRevisions["global"] {
                    self.globalLaunchSettings = settings.1; self.durableGlobalLaunchSettings = settings.1
                }
            } catch { self.launchStartupError = launcherError(error); self.show(error) }
        }
        launchStartupTask = task
        await task.value
    }

    func play(_ id: String) {
        guard canBeginGameOrRuntimeOperation() else { return }
        guard launchSlotOwner == nil, launchTasks.isEmpty, gameOperation?.id != id,
            let game = GameDefinition.all.first(where: { $0.id == id }) else { return }
        if case .recoveryNeeded = launchStates[id] { return }
        // Reserve before any await, and assume potentially live before spawning.
        // A post-spawn journal write may suspend before the .watch event arrives.
        launchSlotOwner = id; liveLaunchGames.insert(id)
        launchLogURLs[id] = nil; launchFailures[id] = nil
        knownEndedLaunchGames.remove(id); launchRecoveryConflicts.remove(id)
        launchObservationGenerations[id] = UUID()
        launchStates[id] = .starting(.preflight)
        let generation = UUID(); launchTaskGenerations[id] = generation
        let services = launchServices
        launchTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.launchTaskGenerations[id] == generation { self.launchTasks[id] = nil; self.launchTaskGenerations[id] = nil }
            }
            do {
                await self.reattachOnStart()
                if let error = self.launchStartupError { throw error }
                await self.refreshRosetta()
                if self.rosetta == .missing { throw LauncherError.rosettaMissing }
                guard self.launchSlotOwner == id, self.launchTaskGenerations[id] == generation else {
                    if self.launchSlotOwner != id { self.launchStates[id] = nil; self.liveLaunchGames.remove(id) }
                    return
                }
                try await self.flushLaunchSettings()
                guard let record = self.gameRecords[id] else { throw LauncherError.io("Game is not installed") }
                for await event in try await services.launch(game: game, record: record) {
                    if Task.isCancelled { return } // Detaches the observer; core supervision survives.
                    await self.handleLaunch(event, id: id)
                }
                // .restored may be delivered before the core releases its context.
                _ = await self.refreshLaunchSession(id)
            } catch {
                self.recordLaunchFailure(LaunchFailureInfo(stage: .preflight,
                    message: launcherError(error).userMessage, hasLog: false, unverifiedBuild: false), id: id)
                _ = await self.refreshLaunchSession(id)
            }
        }
    }

    func handleLaunch(_ event: LaunchEvent, id: String) async {
        switch event {
        case .stage(let stage):
            guard stage != .report else { return }
            if case .recoveryNeeded = launchStates[id] { return }
            launchStates[id] = .starting(stage)
            await captureLog(id)
        case .running:
            launchSlotOwner = id; liveLaunchGames.insert(id)
            if launchStates[id] != .ready { launchStates[id] = .running }
            await captureLog(id)
            observeGameWindow(id)
        case .ready: launchStates[id] = .ready; launchWindows.ready(gameID: id)
        case .ended: recordVerifiedEnd(id)
        case .restored(let outcome):
            switch outcome {
            case .pending:
                showRecovery(id)
                // The core may still be supervising uncertain process state.
                // Only its guarded path can decide whether restoring is safe.
                if !knownEndedLaunchGames.contains(id) { liveLaunchGames.insert(id) }
                monitorUncertainLaunch(id)
            case .conflict:
                launchRecoveryConflicts.insert(id)
                showRecovery(id)
                _ = await refreshLaunchSession(id)
            case .clean:
                _ = await refreshLaunchSession(id)
            }
        case .failed(let failure):
            if sessionLogsEnabled { launchLogURLs[id] = failure.logURL ?? launchLogURLs[id] }
            else { launchLogURLs[id] = nil }
            recordLaunchFailure(LaunchFailureInfo(stage: failure.stage,
                message: LauncherError.io(failure.message).userMessage,
                hasLog: sessionLogsEnabled && launchLogURLs[id] != nil, unverifiedBuild: failure.unverifiedBuild), id: id)
            _ = await refreshLaunchSession(id)
        }
    }

    private func recordLaunchFailure(_ failure: LaunchFailureInfo, id: String) {
        // Recovery owns the visible state until durable finalization, but its
        // completion must not discard the launch failure or its current log.
        launchFailures[id] = failure
        if case .recoveryNeeded = launchStates[id] {} else { launchStates[id] = .failed(failure) }
    }

    private func captureLog(_ id: String) async {
        guard sessionLogsEnabled else { launchLogURLs[id] = nil; return }
        let generation = launchObservationGenerations[id]
        if let url = await launchServices.session(id)?.sessionLogURL,
            launchObservationGenerations[id] == generation { launchLogURLs[id] = url }
    }
    func observeGameWindow(_ id: String) {
        let services = launchServices
        launchWindows.running(gameID: id, processIDs: { await services.gameProcessIDs(id) },
            markReady: { [weak self] in
                await services.markReady(id)
                await self?.windowBecameReady(id)
            })
    }
    private func windowBecameReady(_ id: String) {
        guard liveLaunchGames.contains(id), launchStates[id] == .running else { return }
        launchStates[id] = .ready
    }
    var liveSessionGameName: String? {
        guard let id = liveLaunchGames.sorted().first else { return nil }
        return LauncherGame.all.first { $0.id == id }?.name
    }

    func openLaunchLog(_ id: String) {
        guard sessionLogsEnabled, let url = launchLogURLs[id] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func revealRecovery(_ notice: RecoveryNotice) { NSWorkspace.shared.activateFileViewerSelecting(notice.movedTo) }
    func acknowledge(_ notice: RecoveryNotice) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await launchServices.acknowledge(notice.id)
                recoveryNotices = try await launchServices.notices()
            } catch { show(error) }
        }
    }
    func missingComponents(for id: String) -> Bool {
        runtimeSetupRequirements(for: id).map { !$0.isEmpty } ?? true
    }
}
