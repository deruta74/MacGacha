// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public enum LauncherError: Error, Sendable, Equatable {
    case unsafePath(String)
    case invalidDigest(String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case digestMismatch(path: String, expected: String, actual: String)
    case insufficientSpace(required: Int64, available: Int64)
    case http(status: Int, url: URL)
    case transport(String)
    case io(String)
    case busy(String)
    case fileTooLarge(path: String, limit: Int)
    case consentRequired(String)
    case processFailed(executable: String, exitCode: Int32, stderrTail: String)
    case cancelled
    case journalCorrupt(String)
}
