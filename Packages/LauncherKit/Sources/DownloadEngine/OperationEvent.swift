// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

public enum OperationPhase: String, Sendable {
    case checkingSpace, staging, verifying, committing, deleting, cleaningUp, completed, failed, cancelled
}

public enum OperationEvent: Sendable, Equatable {
    case phase(OperationPhase)
    case progress(downloaded: Int64, totalNetwork: Int64, staged: Int64, totalStaged: Int64)
    case fileVerified(SafeRelativePath)
    case failed(LauncherError)
}
