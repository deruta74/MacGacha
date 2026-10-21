// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import DownloadEngine
import GameLibrary

struct GameState: Sendable, Equatable {
    var status: GameStatus
    var activity: GameActivity? = nil
}

enum GameActivity: Sendable, Equatable {
    case resolving
    case working(OperationPhase, fraction: Double?, bytesPerSecond: Int64?, downloaded: Int64? = nil, total: Int64? = nil)
    case needsApproval(required: Int64, available: Int64)
}

enum PrimaryAction: Sendable, Equatable {
    case preparing, progress, continueInParts, install, resume, finishUninstall
    case update(to: String)
    case setUpRuntimes, locationUnavailable, playUnavailable

    static func resolve(_ state: GameState, runtimesReady: Bool) -> Self {
        switch state.activity {
        case .resolving: return .preparing
        case .working: return .progress
        case .needsApproval: return .continueInParts
        case nil: break
        }
        switch state.status {
        case .locationUnavailable: return .locationUnavailable
        case .notInstalled: return .install
        case .paused: return .resume
        case .uninstallPaused: return .finishUninstall
        case .updateAvailable(_, let to): return .update(to: to)
        case .installed, .unknown: return runtimesReady ? .playUnavailable : .setUpRuntimes
        }
    }
}

enum SpaceVerdict: Sendable, Equatable {
    case whole, batchedOnly, insufficient
    static func of(_ estimate: GameEstimate) -> Self {
        guard let available = estimate.available else { return .whole }
        if available >= estimate.diskWhole { return .whole }
        return available >= estimate.diskMinimum ? .batchedOnly : .insufficient
    }
}
