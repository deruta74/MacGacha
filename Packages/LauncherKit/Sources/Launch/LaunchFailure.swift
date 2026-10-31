// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public enum LaunchStage: String, Sendable {
    case preflight, lock, snapshot, prepare, proxy, spawn, watch, restore, report
}

public struct LaunchFailure: Error, Sendable {
    public let stage: LaunchStage
    public let message: String
    public let logURL: URL?
    public let unverifiedBuild: Bool
    public init(stage: LaunchStage, message: String, logURL: URL?, unverifiedBuild: Bool) {
        self.stage = stage; self.message = message; self.logURL = logURL; self.unverifiedBuild = unverifiedBuild
    }
}

public enum LaunchNote: Sendable, Equatable {
    case starRailSettingsMissing
}

public enum LaunchEvent: Sendable {
    case stage(LaunchStage), note(LaunchNote), running, ready, ended(normal: Bool), restored(RestoreOutcome), failed(LaunchFailure)
}
