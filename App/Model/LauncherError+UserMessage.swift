// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

extension LauncherError {
    /// Associated payloads never appear in alerts or row labels; logs use approved structured fields only.
    var userMessage: String {
        switch self {
        case .unsafePath: String(localized: "The selected files contain an unsafe path or link. Choose another source.")
        case .invalidDigest: String(localized: "The download information is invalid. Try again after updating MacGacha.")
        case .sizeMismatch, .digestMismatch: String(localized: "The downloaded files failed verification. Please try again.")
        case .insufficientSpace: String(localized: "There is not enough free disk space. Free some space and try again.")
        case .http: String(localized: "The download server could not complete the request. Please try again later.")
        case .transport: String(localized: "The download could not finish. Check your connection and try again.")
        case .io: String(localized: "The operation could not finish. Check access to the selected folder and try again.")
        case .busy: String(localized: "Another operation is already running. Wait for it to finish and try again.")
        case .fileTooLarge: String(localized: "A file exceeds the supported size limit. Choose another source.")
        case .consentRequired: String(localized: "Accept the license terms before installing this component.")
        case .processFailed: String(localized: "A required tool could not finish. Check Diagnostics for details.")
        case .cancelled: String(localized: "The operation was cancelled.")
        case .journalCorrupt: String(localized: "The saved operation could not be recovered. Check Diagnostics for details.")
        }
    }
}

func launcherError(_ error: any Error) -> LauncherError {
    if let error = error as? LauncherError { return error }
    if error is CancellationError { return .cancelled }
    return .io(String(describing: error))
}
