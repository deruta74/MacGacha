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
    case consentRequired(String)
    case processFailed(executable: String, exitCode: Int32, stderrTail: String)
    case cancelled
    case journalCorrupt(String)
}
