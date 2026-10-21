// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

/// Scoped work observations for execution diagnostics. No global counters, paths
/// or timing assumptions; normal operations leave the observer unset.
package enum OperationWork: Hashable, Sendable {
    case planValidation, referrerIndexBuild, predictionFile, localRangeHash

    @TaskLocal package static var observer: (@Sendable (OperationWork) -> Void)? = nil

    @inline(__always) static func record(_ work: OperationWork) { observer?(work) }
}
