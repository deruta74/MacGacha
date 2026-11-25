// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Launch

enum LaunchUIState: Sendable, Equatable {
    case starting(LaunchStage)
    case running
    case ready
    case failed(LaunchFailureInfo)
    case recoveryNeeded(String)
}

extension LaunchUIState {
    /// Starting until the game's window appears (`ready`), not only until its process does.
    var showsDockStarting: Bool {
        switch self {
        case .starting, .running: true
        case .ready, .failed, .recoveryNeeded: false
        }
    }
}

struct LaunchFailureInfo: Sendable, Equatable {
    let stage: LaunchStage
    let message: String
    let hasLog: Bool
    let unverifiedBuild: Bool
    var cause: LaunchFailureCause? = nil
    var diagnosis: LaunchDiagnosis? = nil

    static var locationUnavailableLine: String {
        String(localized: "Install location unavailable — connect the drive it's on")
    }

    static func safeMessage(for failure: LaunchFailure) -> String {
        switch failure.lockBlocker {
        case .runningGame(let id):
            if let game = LauncherGame.all.first(where: { $0.id == id }) {
                return String(localized: "\(game.name) is running")
            }
        case .recoveryInProgress:
            return String(localized: "Launch recovery is in progress")
        case nil: break
        }
        if failure.diagnosis?.reason == .busy { return LauncherError.busy("").userMessage }
        return LauncherError.io(failure.message).userMessage
    }

    func footerLine(gameName: String, locationHint: String? = nil) -> String {
        let reason = diagnosis?.reason ?? .unknown
        if reason == .location { return locationHint ?? Self.locationUnavailableLine }
        if stage == .lock || reason == .busy { return message }
        if reason != .unknown { return LaunchDiagnosticText.explanation(self) }
        return switch stage {
        case .preflight, .lock: message
        case .watch where cause == .antiCheatOffline:
            String(localized: "\(gameName) couldn't reach its servers. School or work Wi-Fi may be blocking them", comment: "Launch failure; the argument is the game's name")
        case .watch: String(localized: "\(gameName) closed during startup", comment: "The argument is the game's name")
        case .prepare, .snapshot: String(localized: "Couldn't prepare Wine for \(gameName)", comment: "The argument is the game's name")
        case .proxy: String(localized: "Couldn't start the network helper for \(gameName)", comment: "The argument is the game's name")
        case .spawn, .restore, .report: String(localized: "\(gameName) couldn't start", comment: "The argument is the game's name")
        }
    }
}
