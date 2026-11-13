// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

enum GameMovePhase: Sendable, Equatable {
    case copying, verifying, finishing
    var label: String {
        switch self {
        case .copying: String(localized: "Copying game…")
        case .verifying: String(localized: "Verifying moved files…")
        case .finishing: String(localized: "Finishing move…")
        }
    }
}

@MainActor extension AppModel {
    /// The footer retains the ordinary GameActivity fraction and cancellation.
    func gameMovePhase(for id: String) -> GameMovePhase? {
        guard gameOperation?.id == id, gameOperation?.isMoving == true,
            case .working(let phase, _, _, _, _) = games[id]?.activity else { return nil }
        switch phase {
        case .staging: return .copying
        case .verifying: return .verifying
        default: return .finishing
        }
    }
}
