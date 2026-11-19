// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

public enum OperationPhase: String, Sendable {
    case checkingSpace, staging, verifying, committing, deleting, cleaningUp, completed, failed, cancelled
}

public enum OperationEvent: Sendable, Equatable {
    case sandboxPhase(SandboxPhase)
    /// A chained optional package failed after the game itself succeeded.
    case sandboxFailed(LauncherError)
    /// The game has an update and must go first. No sandbox transfer started.
    case sandboxDeferred
    case phase(OperationPhase)
    case progress(downloaded: Int64, totalNetwork: Int64, staged: Int64, totalStaged: Int64)
    case fileVerified(SafeRelativePath)
    case failed(LauncherError)
    case needsBatchApproval(required: Int64, available: Int64)
}

public enum SandboxPhase: String, Sendable {
    case downloading, extracting, finishing, removing, verifying
}
