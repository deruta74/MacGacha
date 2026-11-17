// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
}
