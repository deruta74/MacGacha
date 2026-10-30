// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary

enum LanguageRestartBlocker: Equatable {
    case game(String), runtimeWork, startup, updating, unresumableOperation(String)
    var reason: String {
        switch self {
        case .game: String(localized: "Available after the game closes.")
        case .runtimeWork: String(localized: "Available after the current runtime setup finishes.")
        case .startup: String(localized: "Available after MacGacha finishes starting.")
        case .updating: String(localized: "Available after the app update finishes.")
        case .unresumableOperation: String(localized: "Available after the current game operation finishes.")
        }
    }
}

struct LanguageRestartContinuation: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case resume, verify }
    static let defaultsKey = "languageRestartContinuation"
    static let argument = "-MacGachaLanguageRestart"
    let restartID: UUID
    let gameID: String
    let action: Action
    let planID: String?
}

@MainActor extension AppModel {
    var languageRestartBlocker: LanguageRestartBlocker? {
        if let id = launchSlotOwner { return .game(id) }
        if let id = launchStates.keys.sorted().first(where: {
            if case .recoveryNeeded = launchStates[$0] { true } else { false }
        }) { return .game(id) }
        if let id = liveLaunchGames.sorted().first(where: { !knownEndedLaunchGames.contains($0) }) { return .game(id) }
        if isStarting || launchStartupError != nil { return .startup }
        if updater.isInstallingUpdate { return .updating }
        if isRuntimeOperationRunning || consentRequest != nil || importState != nil ||
            runtimeSetupProgress.values.contains(where: { if case .installing = $0 { true } else { false } }) ||
            !runtimeSetupRosettaChecks.isEmpty { return .runtimeWork }
        if let operation = gameOperation {
            let record = gameRecords[operation.id]
            if operation.isUninstall || record?.uninstalling == true || (record?.pending == nil && !operation.isVerification) {
                return .unresumableOperation(operation.id)
            }
        }
        return nil
    }

    func restartForLanguage() async {
        guard languageRestart == nil, languageRestartBlocker == nil else { return }
        let id = UUID(), operation = gameOperation
        // This reservation spans consumer cancellation, pipeline drainage and the new-app handoff.
        setLanguageRestart(id)
        do {
            var continuation: LanguageRestartContinuation?
            if let operation {
                switch try await stopGameOperation(operation) {
                case .resume(let planID): continuation = .init(restartID: id, gameID: operation.id, action: .resume, planID: planID)
                case .verify: continuation = .init(restartID: id, gameID: operation.id, action: .verify, planID: nil)
                case .finished, .failed: break
                }
            } else if let previous = lastGameConsumerOutcome?.token {
                // A pause can release the UI reservation before its detached workers drain.
                // Join them too, but do not resume an operation the user had already paused.
                try await gameServices.waitUntilIdle(previous.id)
            }
            try await flushLaunchSettings()
            try Task.checkCancellation()
            if let continuation {
                guard let defaults else { throw LauncherError.languageRestartFailed }
                defaults.set(try JSONEncoder().encode(continuation), forKey: LanguageRestartContinuation.defaultsKey)
            } else { defaults?.removeObject(forKey: LanguageRestartContinuation.defaultsKey) }
            try await relaunch([LanguageRestartContinuation.argument, id.uuidString])
            terminateAfterLanguageRestart()
            // Keep the reservation until termination so Sparkle or a queued click cannot slip into the handoff.
        } catch {
            defaults?.removeObject(forKey: LanguageRestartContinuation.defaultsKey)
            setLanguageRestart(nil)
            show(LauncherError.languageRestartFailed)
        }
    }

    func continueLanguageRestart(arguments: [String]) async {
        let data = defaults?.data(forKey: LanguageRestartContinuation.defaultsKey)
        // One-shot even on ordinary launch, malformed data or a stale restart argument.
        defaults?.removeObject(forKey: LanguageRestartContinuation.defaultsKey)
        defer { setLanguageRestart(nil) }
        guard let data, let continuation = try? JSONDecoder().decode(LanguageRestartContinuation.self, from: data),
            let index = arguments.firstIndex(of: LanguageRestartContinuation.argument), arguments.indices.contains(index + 1),
            UUID(uuidString: arguments[index + 1]) == continuation.restartID,
            GameDefinition.find(continuation.gameID) != nil,
            launchStartupError == nil, launchSlotOwner == nil,
            !launchStates.values.contains(where: { if case .recoveryNeeded = $0 { true } else { false } }) else { return }
        do {
            guard let record = try await gameServices.record(continuation.gameID), !record.uninstalling else { return }
            setGameRecord(continuation.gameID, record)
            switch continuation.action {
            case .resume:
                guard let planID = continuation.planID, record.pending?.planID.rawValue == planID else { return }
                setLanguageRestart(nil)
                resumeGame(continuation.gameID)
            case .verify:
                guard continuation.planID == nil, record.installed != nil, record.pending == nil else { return }
                setLanguageRestart(nil)
                verifyGame(continuation.gameID)
            }
        } catch { show(LauncherError.languageRestartFailed) }
    }
}
