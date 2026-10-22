// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

/// Scoped work observations for execution diagnostics. No global counters, paths
/// or timing assumptions; normal operations leave the observer unset.
package enum OperationWork: Hashable, Sendable {
    case fetchTaskSubmitted, fetchTaskFinished, ownershipDrainWait
    case planValidation, referrerIndexBuild, predictionFile, localRangeHash, assemblyStarted, assemblyFinished, stagingLeaseReleased

    @TaskLocal package static var observer: (@Sendable (OperationWork) -> Void)? = nil

    @inline(__always) static func record(_ work: OperationWork) { observer?(work) }

    package enum Phase: String, Sendable { case hashing, assembly }
    @TaskLocal package static var timingObserver: (@Sendable (Phase, Duration) -> Void)? = nil
    package static func begin(_ phase: Phase) -> Span? {
        timingObserver.map { Span(phase: phase, observer: $0) }
    }
    package struct Span {
        let phase: Phase
        let observer: @Sendable (Phase, Duration) -> Void
        let start = ContinuousClock.now
        package func end() { observer(phase, start.duration(to: .now)) }
    }
}
