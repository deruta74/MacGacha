// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

public extension LauncherError {
    /// Stable, path-free case names shared by operational logs.
    var logCase: String {
        switch self {
        case .unsafePath: "unsafePath"
        case .invalidDigest: "invalidDigest"
        case .sizeMismatch: "sizeMismatch"
        case .digestMismatch: "digestMismatch"
        case .insufficientSpace: "insufficientSpace"
        case .http: "http"
        case .transport: "transport"
        case .io: "io"
        case .busy: "busy"
        case .fileTooLarge: "fileTooLarge"
        case .consentRequired: "consentRequired"
        case .processSpawnFailed: "processSpawnFailed"
        case .processFailed: "processFailed"
        case .gameEditionMismatch: "gameEditionMismatch"
        case .gameEditionUnknown: "gameEditionUnknown"
        case .gameDistributionUnsupported: "gameDistributionUnsupported"
        case .rosettaMissing: "rosettaMissing"
        case .rosettaInstallerUnavailable: "rosettaInstallerUnavailable"
        case .cancelled: "cancelled"
        case .journalCorrupt: "journalCorrupt"
        }
    }

    /// Only typed numeric payloads may contribute reasons. Never inspect error text.
    var logReason: String? {
        switch self {
        case .processSpawnFailed(let code):
            switch code {
            case E2BIG: "E2BIG"
            case EACCES: "EACCES"
            case EAGAIN: "EAGAIN"
            case EBADF: "EBADF"
            case EBADARCH: "EBADARCH"
            case EBADEXEC: "EBADEXEC"
            case EBADMACHO: "EBADMACHO"
            case EINVAL: "EINVAL"
            case EIO: "EIO"
            case ELOOP: "ELOOP"
            case EMFILE: "EMFILE"
            case ENAMETOOLONG: "ENAMETOOLONG"
            case ENFILE: "ENFILE"
            case ENOENT: "ENOENT"
            case ENOEXEC: "ENOEXEC"
            case ENOMEM: "ENOMEM"
            case ENOTDIR: "ENOTDIR"
            case ENOTSUP: "ENOTSUP"
            case EPERM: "EPERM"
            case ETXTBSY: "ETXTBSY"
            default: "errno \(code)"
            }
        case .processFailed(_, let exitCode, _): "exit code \(exitCode)"
        default: nil
        }
    }
}

extension LauncherError {
    /// Foundation can wrap posix_spawn's errno in a Cocoa error. Keep only the
    /// typed code; localized descriptions often contain the executable's path.
    static func processLaunchFailure(_ error: any Error) -> LauncherError {
        var cause = error as NSError
        for _ in 0..<4 {
            if cause.domain == NSPOSIXErrorDomain, let code = Int32(exactly: cause.code) {
                return .processSpawnFailed(errno: code)
            }
            if cause.domain == NSCocoaErrorDomain {
                // Process.run also performs its own file/architecture checks.
                switch cause.code {
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .processSpawnFailed(errno: ENOENT)
                case NSFileReadNoPermissionError: return .processSpawnFailed(errno: EACCES)
                case NSExecutableArchitectureMismatchError: return .processSpawnFailed(errno: EBADARCH)
                default: break
                }
            }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = underlying
        }
        return .io(error.localizedDescription)
    }
}
