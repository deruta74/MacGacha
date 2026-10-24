// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
@testable import LauncherCore

struct LauncherErrorLoggingTests {
    @Test(arguments: [ENOEXEC, EBADARCH, ENOENT])
    func foundationSpawnFailuresKeepOnlyTypedErrno(code: Int32) {
        let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "/Users/private-person/wine token=planted-secret"])
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSExecutableLoadError,
            userInfo: [NSUnderlyingErrorKey: cause, NSFilePathErrorKey: "/Users/private-person/wine"])
        for error in [cause, wrapped] {
            #expect(LauncherError.processLaunchFailure(error) == .processSpawnFailed(errno: code))
        }
        let reason = LauncherError.processSpawnFailed(errno: code).logReason
        #expect(reason == (code == ENOEXEC ? "ENOEXEC" : code == EBADARCH ? "EBADARCH" : "ENOENT"))
    }

    @Test func cocoaArchitectureFailureKeepsSafeReason() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSExecutableArchitectureMismatchError,
            userInfo: [NSFilePathErrorKey: "/Users/private-person/wine"])
        #expect(LauncherError.processLaunchFailure(error) == .processSpawnFailed(errno: EBADARCH))
    }

    @Test func unknownErrnoIsNumericAndFreeFormMessagesAreNotReasons() {
        #expect(LauncherError.processSpawnFailed(errno: .max).logReason == "errno 2147483647")
        #expect(LauncherError.io("Spawning process: EBADARCH /Users/private-person token=planted-secret").logReason == nil)
        #expect(LauncherError.transport("planted-secret").logReason == nil)
    }
}
