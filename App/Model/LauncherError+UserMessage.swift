// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension LauncherError {
    /// Associated payloads never appear in alerts or row labels; logs use approved structured fields only.
    var userMessage: String {
        switch self {
        case .unsafePath: "The selected files contain an unsafe path or link. Choose another source."
        case .invalidDigest: "The download information is invalid. Try again after updating MacGacha."
        case .sizeMismatch, .digestMismatch: "The downloaded files failed verification. Please try again."
        case .insufficientSpace: "There is not enough free disk space. Free some space and try again."
        case .http: "The download server could not complete the request. Please try again later."
        case .transport: "The download could not finish. Check your connection and try again."
        case .io: "The operation could not finish. Check access to the selected folder and try again."
        case .busy: "Another operation is already running. Wait for it to finish and try again."
        case .fileTooLarge: "A file exceeds the supported size limit. Choose another source."
        case .consentRequired: "Accept the license terms before installing this component."
        case .processFailed: "A required tool could not finish. Check Diagnostics for details."
        case .cancelled: "The operation was cancelled."
        case .journalCorrupt: "The saved operation could not be recovered. Check Diagnostics for details."
        }
    }
}

func launcherError(_ error: any Error) -> LauncherError {
    if let error = error as? LauncherError { return error }
    if error is CancellationError { return .cancelled }
    return .io(String(describing: error))
}
