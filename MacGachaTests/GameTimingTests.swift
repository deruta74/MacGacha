// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import DownloadEngine
import LauncherCore
import RuntimeManager
import Synchronization
@testable import MacGacha

@MainActor struct GameTimingTests {
    private let start = ContinuousClock.now

    @Test func etaWarmsUpThenMatchesSteadyRate() throws {
        var progress = GameProgress()
        for second in 0...9 {
            let value = progress.update(at: start.advanced(by: .seconds(second)), downloaded: Int64(second * 100),
                network: 10_000, staged: 0, totalStaged: 0)
            #expect(value?.timing.remaining == nil)
        }
        let value = try unwrap(progress.update(at: start.advanced(by: .seconds(10)), downloaded: 1000,
            network: 10_000, staged: 0, totalStaged: 0))
        #expect(abs(seconds(try #require(value.timing.remaining)) - 90) < 0.01)
        #expect(value.speed == 100)
    }

    @Test func oneSecondSpikeHasBoundedEffectOnEta() throws {
        var progress = GameProgress()
        for second in 0...10 {
            _ = progress.update(at: start.advanced(by: .seconds(second)), downloaded: Int64(second * 100),
                network: 10_000, staged: 0, totalStaged: 0)
        }
        let spike = try unwrap(progress.update(at: start.advanced(by: .seconds(11)), downloaded: 2000,
            network: 10_000, staged: 0, totalStaged: 0))
        // A raw one-second rate would predict 8 s. The 20 s EMA stays above 50 s.
        let remaining = seconds(try #require(spike.timing.remaining))
        #expect(remaining > 50 && abs(remaining - 90) < 40)
    }

    @Test func resetAndCounterSwitchRestartWarmupEvenInsideThrottle() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 0, network: 10_000, staged: 0, totalStaged: 0)
        _ = progress.update(at: start.advanced(by: .seconds(10)), downloaded: 1000, network: 10_000, staged: 0, totalStaged: 0)
        #expect(progress.update(at: start.advanced(by: .milliseconds(10_100)), downloaded: 0,
            network: 10_000, staged: 0, totalStaged: 0) == nil)
        let reset = try unwrap(progress.update(at: start.advanced(by: .seconds(11)), downloaded: 1100,
            network: 10_000, staged: 0, totalStaged: 0))
        #expect(reset.timing.remaining == nil)
        let switched = try unwrap(progress.update(at: start.advanced(by: .seconds(22)), downloaded: 1100,
            network: 0, staged: 2000, totalStaged: 10_000))
        #expect(switched.timing.remaining == nil && switched.speed == nil)
        let warmed = try unwrap(progress.update(at: start.advanced(by: .seconds(32)), downloaded: 1100,
            network: 0, staged: 3000, totalStaged: 10_000))
        #expect(abs(seconds(try #require(warmed.timing.remaining)) - 70) < 0.01)
    }

    @Test func zeroRateUnknownTotalAndHugeEtaAreSafe() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 0, network: Int64.max, staged: 0, totalStaged: 0)
        let huge = try unwrap(progress.update(at: start.advanced(by: .seconds(10)), downloaded: 1,
            network: Int64.max, staged: 0, totalStaged: 0))
        #expect(huge.timing.remaining == GameProgress.maximumRemaining)
        let stopped = progress.update(at: start.advanced(by: .seconds(11)), downloaded: 1,
            network: Int64.max, staged: 0, totalStaged: 0)
        #expect(stopped?.timing.remaining == nil)
        let unknown = progress.update(at: start.advanced(by: .seconds(12)), downloaded: 1,
            network: 0, staged: 30, totalStaged: 0)
        #expect(unknown?.timing.remaining == nil && unknown?.timing.hasFraction == false)
    }

    @Test func phaseChangeResetsTimingAndVerifyBytesProduceEta() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 0, network: 1000, staged: 0, totalStaged: 0)
        _ = progress.update(at: start.advanced(by: .seconds(10)), downloaded: 500, network: 1000, staged: 0, totalStaged: 0)
        let phase = start.advanced(by: .seconds(11))
        progress.beginPhase(.verifying, at: phase)
        #expect(progress.timing?.phaseStarted == phase && progress.timing?.lastAdvance == phase)
        #expect(progress.timing?.hasFraction == false)
        _ = progress.update(at: phase, downloaded: 0, network: 0, staged: 0, totalStaged: 2000, phase: .verifying)
        let value = try unwrap(progress.update(at: phase.advanced(by: .seconds(10)), downloaded: 0,
            network: 0, staged: 1000, totalStaged: 2000, phase: .verifying))
        #expect(value.fraction == 0.5 && value.speed == nil)
        #expect(abs(seconds(try #require(value.timing.remaining)) - 10) < 0.01)
    }

    @Test func throttledAdvanceIsObservedButHeartbeatDoesNotAdvance() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 0, network: 1000, staged: 0, totalStaged: 0)
        let advance = start.advanced(by: .milliseconds(100))
        #expect(progress.update(at: advance, downloaded: 100, network: 1000, staged: 0, totalStaged: 0) == nil)
        let heartbeat = try unwrap(progress.update(at: start.advanced(by: .seconds(1)), downloaded: 100,
            network: 1000, staged: 0, totalStaged: 0))
        #expect(heartbeat.timing.lastAdvance == advance)
    }

    @Test func stagingGrowthPreventsNetworkStallEvenInsideThrottle() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 100, network: 1000, staged: 0, totalStaged: 2000)
        let advance = start.advanced(by: .milliseconds(100))
        #expect(progress.update(at: advance, downloaded: 100, network: 1000,
            staged: 10, totalStaged: 2000) == nil)
        let heartbeat = try unwrap(progress.update(at: start.advanced(by: .seconds(1)), downloaded: 100,
            network: 1000, staged: 10, totalStaged: 2000))
        #expect(heartbeat.timing.lastAdvance == advance)
        for second in 2...40 {
            let value = try unwrap(progress.update(at: start.advanced(by: .seconds(second)), downloaded: 100,
                network: 1000, staged: Int64(second * 10), totalStaged: 2000))
            #expect(value.timing.lastAdvance == start.advanced(by: .seconds(second)))
            #expect(value.timing.display(at: start.advanced(by: .seconds(second))) != .slow(elapsed: nil))
        }
    }

    @Test func completedNetworkSwitchesEtaToStagingAndKeepsDownloadFraction() throws {
        var progress = GameProgress()
        _ = progress.update(at: start, downloaded: 0, network: 1000, staged: 0, totalStaged: 4000)
        _ = progress.update(at: start.advanced(by: .seconds(10)), downloaded: 900,
            network: 1000, staged: 900, totalStaged: 4000)
        let switched = try unwrap(progress.update(at: start.advanced(by: .seconds(11)), downloaded: 1000,
            network: 1000, staged: 1000, totalStaged: 4000))
        #expect(switched.fraction == 1)
        #expect(switched.timing.remaining == nil)
        let warming = try unwrap(progress.update(at: start.advanced(by: .seconds(20)), downloaded: 1000,
            network: 1000, staged: 1900, totalStaged: 4000))
        #expect(warming.timing.remaining == nil)
        let warmed = try unwrap(progress.update(at: start.advanced(by: .seconds(21)), downloaded: 1000,
            network: 1000, staged: 2000, totalStaged: 4000))
        #expect(warmed.fraction == 1)
        #expect(abs(seconds(try #require(warmed.timing.remaining)) - 20) < 0.01)
        #expect(warmed.speed == 0)
        #expect(warmed.timing.lastAdvance == start.advanced(by: .seconds(21)))
    }

    @Test func displayThresholdsAreExact() {
        var timing = GameTiming(phaseStarted: start, lastAdvance: start, remaining: nil, hasFraction: false)
        #expect(timing.display(at: start.advanced(by: .seconds(19.999))) == .none)
        #expect(timing.display(at: start.advanced(by: .seconds(20))) == .elapsed(.seconds(20)))
        #expect(timing.display(at: start.advanced(by: .seconds(119.999))) == .elapsed(.seconds(119.999)))
        #expect(timing.display(at: start.advanced(by: .seconds(120))) == .slow(elapsed: .seconds(120)))
        timing.hasFraction = true; timing.remaining = .seconds(50)
        #expect(timing.display(at: start.advanced(by: .seconds(29.999))) == .remaining(.seconds(50)))
        #expect(timing.display(at: start.advanced(by: .seconds(30))) == .slow(elapsed: nil))
        timing.remaining = nil
        #expect(timing.display(at: start) == .none)
    }

    @Test func stateTransitionsAlwaysNormalizeTiming() throws {
        let clock = Mutex(start)
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/timing")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            now: { clock.withLock { $0 } })
        model.setGameState("genshin", GameState(status: .notInstalled,
            activity: .working(.committing, fraction: nil, bytesPerSecond: nil)))
        #expect(model.games["genshin"]?.timing?.phaseStarted == start)
        clock.withLock { $0 = start.advanced(by: .seconds(5)) }
        model.setGameState("genshin", GameState(status: .notInstalled,
            activity: .working(.cleaningUp, fraction: nil, bytesPerSecond: nil)))
        #expect(model.games["genshin"]?.timing?.phaseStarted == start.advanced(by: .seconds(5)))
        var copied = try #require(model.games["genshin"])
        clock.withLock { $0 = start.advanced(by: .seconds(7)) }
        copied.activity = .working(.deleting, fraction: nil, bytesPerSecond: nil)
        model.setGameState("genshin", copied)
        #expect(model.games["genshin"]?.timing?.phaseStarted == start.advanced(by: .seconds(7)))
        copied.activity = .needsApproval(required: 100, available: 1)
        model.setGameState("genshin", copied)
        #expect(model.games["genshin"]?.timing == nil)
        copied.activity = nil; model.setGameState("genshin", copied)
        #expect(model.games["genshin"]?.timing == nil)
    }

    private func unwrap(_ value: GameProgress.Value?) throws -> GameProgress.Value { try #require(value) }

    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}
