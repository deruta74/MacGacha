// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

public enum CrashPoint: String, CaseIterable, Sendable {
    case afterObjectVerified
    case afterFileStagedBeforeJournal
    case afterRenameBeforeJournal
    case midJournalWrite
    case afterCommitStartedBeforeFirstRename
    case beforeCompleted
    case afterOperationCompleted
    case duringCompletionReceiptWrite
    case duringGamePlanWrite
    case afterCompletionReceipt
    case afterEngineCleanup
    case afterGamePlanSaved
    case afterGamePendingSaved
    case afterGameRecordSaved
    case afterGamePlanDeleted
    case afterReceiptAcknowledged
    case afterGameFolderRemoved
    case afterUninstallPlanDeleted
    case afterUninstallManifestCacheDeleted
    case afterUninstallBranchDeleted
    case afterUninstallManagedPathsDeleted
    case afterUninstallCleanupDeleted
    case afterUninstallRecordDeleted
    case beforeGameRecordDeleted
}

/// Explicit injection only: normal callers use .none and never split journal writes.
/// The engine contains no environment switch or process-termination code.
public struct CrashHooks: Sendable {
    private let point: CrashPoint?
    private let action: (@Sendable () -> Void)?
    public static let none = CrashHooks()
    private init() { point = nil; action = nil }
    public init(at point: CrashPoint, action: @escaping @Sendable () -> Void) {
        self.point = point; self.action = action
    }
    func enabled(_ point: CrashPoint) -> Bool { self.point == point }
    @inline(__always) package func reach(_ point: CrashPoint) { if self.point == point { action?() } }
}
