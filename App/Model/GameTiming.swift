// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

struct GameTiming: Sendable, Equatable {
    static let elapsedThreshold: Duration = .seconds(20)
    static let fractionStallThreshold: Duration = .seconds(30)
    static let indeterminateSlowThreshold: Duration = .seconds(120)

    var phaseStarted: ContinuousClock.Instant
    var lastAdvance: ContinuousClock.Instant
    var remaining: Duration?
    var hasFraction: Bool

    func display(at now: ContinuousClock.Instant) -> GameTimingDisplay {
        if hasFraction {
            if lastAdvance.duration(to: now) >= Self.fractionStallThreshold { return .slow(elapsed: nil) }
            return remaining.map(GameTimingDisplay.remaining) ?? .none
        }
        let elapsed = max(.zero, phaseStarted.duration(to: now))
        if elapsed >= Self.indeterminateSlowThreshold { return .slow(elapsed: elapsed) }
        return elapsed >= Self.elapsedThreshold ? .elapsed(elapsed) : .none
    }
}

enum GameTimingDisplay: Sendable, Equatable {
    case none
    case remaining(Duration)
    case elapsed(Duration)
    case slow(elapsed: Duration?)
}
