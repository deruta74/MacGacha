// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public enum LaunchStage: String, Sendable {
    case preflight, lock, snapshot, prepare, proxy, spawn, watch, restore, report
}

/// A likely reason the game itself gave for closing, when it left one.
public enum LaunchFailureCause: String, Sendable, Equatable {
    /// The anti-cheat driver failed at startup, which under Wine means the
    /// game couldn't reach its servers (see `AntiCheatDriverError`).
    case antiCheatOffline
}

public enum LaunchLockBlocker: Sendable, Equatable {
    case runningGame(String)
    case recoveryInProgress
}

public struct LaunchFailure: Error, Sendable {
    public let stage: LaunchStage
    public let message: String
    public let logURL: URL?
    public let unverifiedBuild: Bool
    public let cause: LaunchFailureCause?
    public let diagnosis: LaunchDiagnosis?
    public let lockBlocker: LaunchLockBlocker?
    public init(stage: LaunchStage, message: String, logURL: URL?, unverifiedBuild: Bool, cause: LaunchFailureCause? = nil,
        diagnosis: LaunchDiagnosis? = nil, lockBlocker: LaunchLockBlocker? = nil) {
        self.stage = stage; self.message = message; self.logURL = logURL; self.unverifiedBuild = unverifiedBuild
        self.cause = cause; self.diagnosis = diagnosis; self.lockBlocker = lockBlocker
    }
}

public enum LaunchNote: Sendable, Equatable {
    case starRailSettingsMissing, surroundUnavailable, fpsUnlockUnavailable
}

public enum LaunchEvent: Sendable {
    case stage(LaunchStage), note(LaunchNote), running, ready, ended(normal: Bool), restored(RestoreOutcome), failed(LaunchFailure)
}
