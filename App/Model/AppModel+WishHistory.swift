// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import HoYoPlayAPI

@MainActor extension AppModel {
    var wishHistoryEnabled: Bool {
        get { globalLaunchSettings.wishHistoryEnabled }
        set {
            setGlobalLaunchPreference(\.wishHistoryEnabled, to: newValue)
            if !wishHistoryEnabled { cancelWishHistoryExport() }
        }
    }

    var wishHistoryExplanation: String {
        String(localized: "MacGacha reads the history link cached when you open wish history in the game, then downloads your history from HoYoverse. The link is private and is never logged.")
    }

    /// Memory-only eligibility. Views hide the menu item while the switch is off.
    func canExportWishHistory(_ id: String) -> Bool {
        wishHistoryEnabled && wishHistoryExportingGame == nil && languageRestart == nil
            && GameDefinition.find(id) != nil && gameRecords[id]?.installed != nil
            && gameOperation?.id != id && gameLocationURL(for: id) != nil
    }

    /// Returns private JSON bytes and edition counts. The view owns NSSavePanel
    /// and writes the data only after the user chooses a destination.
    func exportWishHistory(_ id: String) async throws -> WishHistoryExport {
        guard wishHistoryEnabled else { throw LauncherError.cancelled }
        guard canExportWishHistory(id), let game = GameDefinition.find(id), let record = gameRecords[id] else {
            throw LauncherError.busy("Wish history export is unavailable")
        }
        let generation = UUID(), exporter = wishHistoryExporter
        wishHistoryGeneration = generation; wishHistoryFailure = nil; wishHistoryExportingGame = id
        let request = WishHistoryRequest(game: game, installRoot: record.installPath, installIdentity: record.installIdentity,
            language: HoYoPlayLanguage.content(forInterface: InterfaceLanguageSettings.runningLocalization).rawValue,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        let task = Task { [self] in
            try await flushLaunchSettings()
            try Task.checkCancellation()
            guard wishHistoryEnabled else { throw LauncherError.cancelled }
            let result = try await exporter.export(request) { [weak self] progress in
                await self?.applyWishHistoryProgress(progress, generation: generation)
            }
            try Task.checkCancellation()
            guard wishHistoryEnabled, wishHistoryGeneration == generation else { throw LauncherError.cancelled }
            return result
        }
        wishHistoryTask = task
        defer {
            if wishHistoryGeneration == generation {
                wishHistoryTask = nil; wishHistoryGeneration = nil; wishHistoryProgress = nil; wishHistoryExportingGame = nil
            }
        }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            let failure: LauncherError
            if Task.isCancelled || task.isCancelled || error is CancellationError { failure = .cancelled }
            else if let typed = error as? LauncherError,
                [.wishHistoryNoCachedLink, .wishHistoryLinkExpired, .wishHistoryNetwork, .wishHistoryInvalidData, .cancelled].contains(typed) { failure = typed }
            else { failure = .wishHistoryNetwork }
            if wishHistoryEnabled, failure != .cancelled { wishHistoryFailure = failure }
            throw failure
        }
    }

    func cancelWishHistoryExport() {
        wishHistoryTask?.cancel()
        wishHistoryProgress = nil; wishHistoryFailure = nil
    }

    private func applyWishHistoryProgress(_ progress: WishHistoryProgress, generation: UUID) {
        guard wishHistoryEnabled, wishHistoryGeneration == generation, wishHistoryTask?.isCancelled == false else { return }
        wishHistoryProgress = progress
    }
}
