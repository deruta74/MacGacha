// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import DownloadEngine
import GameLibrary

struct GameState: Sendable, Equatable {
    var status: GameStatus
    var activity: GameActivity? = nil
    var spaceShortage: GameSpaceShortage? = nil
}

struct GameSpaceShortage: Sendable, Equatable {
    let required: Int64
    let available: Int64
    var purgeable: Int64? = nil
    // LauncherCore uses (1, 0) for unmeasured ENOSPC/EDQUOT allocation
    // failures. Those bytes say nothing about free capacity or macOS-held space.
    var isMeasured: Bool { required != 1 || available != 0 }
    var heldByMacOS: Int64? {
        guard isMeasured else { return nil }
        return SpaceVerdict.heldBytes(required: required, available: available, purgeable: purgeable)
    }
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
    case heldByMacOS(purgeable: Int64)
    static func of(_ estimate: GameEstimate) -> Self {
        let plain = immediate(estimate)
        if plain != .whole, let available = estimate.available,
            let held = heldBytes(required: estimate.diskWhole, available: available, purgeable: estimate.purgeable) {
            return .heldByMacOS(purgeable: held)
        }
        return plain
    }

    /// Buttons use immediately allocatable bytes, even when Finder shows more.
    static func immediate(_ estimate: GameEstimate) -> Self {
        guard let available = estimate.available else { return .whole }
        if available >= estimate.diskWhole { return .whole }
        return available >= estimate.diskMinimum ? .batchedOnly : .insufficient
    }

    static func heldBytes(required: Int64, available: Int64, purgeable: Int64?) -> Int64? {
        guard available < required, let purgeable, purgeable > 0 else { return nil }
        let (combined, overflow) = available.addingReportingOverflow(purgeable)
        return overflow || combined >= required ? purgeable : nil
    }
}
