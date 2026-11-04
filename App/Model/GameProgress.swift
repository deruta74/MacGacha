// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import DownloadEngine

struct GameProgress {
    static let etaWarmup: Duration = .seconds(10)
    static let emaTimeConstant: Duration = .seconds(20)
    static let maximumRemaining: Duration = .seconds(99 * 60 * 60)
    static let uiUpdateInterval: Duration = .milliseconds(250)
    static let speedWindow: Duration = .seconds(5)
    static let maximumSpeedSamples = 32

    struct Value { let fraction: Double?; let speed: Int64?; let timing: GameTiming }
    private struct Sample { let time: ContinuousClock.Instant; let bytes: Int64 }
    private enum Counter { case network, staged }
    private var phase: OperationPhase?
    private var counter: Counter?
    private var lastObservedBytes: Int64?
    private var lastObservedDownloaded: Int64?
    private var lastObservedStaged: Int64?
    private var rateSample: Sample?
    private var batchStarted: ContinuousClock.Instant?
    private var emaRate: Double?
    private var lastUpdate: ContinuousClock.Instant?
    private var speedSamples: [Sample] = []
    private(set) var timing: GameTiming?

    static func trackingPhase(for phase: OperationPhase) -> OperationPhase {
        [.checkingSpace, .committing].contains(phase) ? .staging : phase
    }

    mutating func beginPhase(_ phase: OperationPhase, at time: ContinuousClock.Instant) {
        let phase = Self.trackingPhase(for: phase)
        guard self.phase != phase else { return }
        self.phase = phase; counter = nil; lastObservedBytes = nil
        lastObservedDownloaded = nil; lastObservedStaged = nil
        rateSample = nil; batchStarted = nil; emaRate = nil; speedSamples = []
        timing = GameTiming(phaseStarted: time, lastAdvance: time, remaining: nil, hasFraction: false)
    }

    mutating func update(at time: ContinuousClock.Instant, downloaded: Int64, network: Int64, staged: Int64,
        totalStaged: Int64, phase: OperationPhase = .staging) -> Value? {
        beginPhase(phase, at: time)
        // The engine retains network totals while the final objects assemble.
        let usesNetwork = network > 0 && (downloaded < network || totalStaged <= 0)
        let source: Counter = usesNetwork ? .network : .staged
        let total = usesNetwork ? network : totalStaged, count = max(0, usesNetwork ? downloaded : staged)
        let reset = lastObservedBytes.map { count < $0 } ?? false
        if counter != source || reset {
            if counter != nil { timing?.lastAdvance = time }
            counter = source; batchStarted = time; emaRate = nil
            rateSample = Sample(time: time, bytes: count); speedSamples = []
        } else if let previous = rateSample {
            let dt = seconds(previous.time.duration(to: time))
            if dt > 0 {
                let rate = Double(max(0, count - previous.bytes)) / dt
                let alpha = 1 - exp(-dt / seconds(Self.emaTimeConstant))
                emaRate = emaRate.map { $0 + alpha * (rate - $0) } ?? rate
                rateSample = Sample(time: time, bytes: count)
            }
        }
        // Observe every event before throttling: growth, batch resets and source
        // switches can all occur within one UI interval.
        let downloaded = max(0, downloaded), staged = max(0, staged)
        let downloadAdvanced = lastObservedDownloaded.map { downloaded > $0 } ?? (downloaded > 0)
        let stagingAdvanced = lastObservedStaged.map { staged > $0 } ?? (staged > 0)
        if downloadAdvanced || stagingAdvanced { timing?.lastAdvance = time }
        lastObservedDownloaded = downloaded; lastObservedStaged = staged
        lastObservedBytes = count
        timing?.hasFraction = total > 0
        let estimate = remaining(at: time, count: count, total: total)
        timing?.remaining = estimate
        guard let timing else { return nil }
        if let previous = lastUpdate, previous.duration(to: time) < Self.uiUpdateInterval { return nil }
        lastUpdate = time
        // Count both delivery and local assembly across the whole operation.
        // Adopted cache bytes are delivered, but still need local installation.
        let combinesWork = phase == .staging
        let shownTotal = combinesWork ? Double(max(0, network)) + Double(max(0, totalStaged))
            : Double(max(0, network > 0 ? network : totalStaged))
        let shownCount = combinesWork
            ? Double(min(max(0, network), downloaded)) + Double(min(max(0, totalStaged), staged))
            : Double(network > 0 ? downloaded : staged)
        let fraction = shownTotal > 0 ? min(1, shownCount / shownTotal) : nil
        return Value(fraction: fraction, speed: usesNetwork
            ? speed(at: time, bytes: downloaded, network: network) : nil, timing: timing)
    }

    private func remaining(at time: ContinuousClock.Instant, count: Int64, total: Int64) -> Duration? {
        // Only the average decides: events between chunks often carry no new bytes,
        // and a real stop is reported by the stall threshold instead.
        guard total > 0, let batchStarted, batchStarted.duration(to: time) >= Self.etaWarmup,
            let emaRate, emaRate > 0, emaRate.isFinite else { return nil }
        let seconds = Double(max(0, total - count)) / emaRate
        return .seconds(min(seconds, self.seconds(Self.maximumRemaining)))
    }

    /// Keep the existing network-only five-second window, with one preceding
    /// sample for interpolation and a bounded sample count.
    private mutating func speed(at time: ContinuousClock.Instant, bytes: Int64, network: Int64) -> Int64? {
        guard network > 0 else { speedSamples = []; return nil }
        speedSamples.append(Sample(time: time, bytes: bytes))
        let cutoff = time.advanced(by: .zero - Self.speedWindow)
        while speedSamples.count > 2 && speedSamples[1].time <= cutoff { speedSamples.removeFirst() }
        if speedSamples.count > Self.maximumSpeedSamples { speedSamples.removeFirst(speedSamples.count - Self.maximumSpeedSamples) }
        guard let first = speedSamples.first, speedSamples.count > 1 else { return nil }
        var start = first.time, startBytes = Double(first.bytes)
        if start < cutoff {
            let next = speedSamples[1], span = seconds(start.duration(to: next.time))
            if span > 0 {
                startBytes += (Double(next.bytes) - startBytes) * seconds(start.duration(to: cutoff)) / span
                start = cutoff
            }
        }
        let elapsed = seconds(start.duration(to: time))
        guard elapsed > 0 else { return nil }
        let rate = max(0, (Double(bytes) - startBytes) / elapsed)
        return rate >= Double(Int64.max) ? Int64.max : Int64(rate)
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
