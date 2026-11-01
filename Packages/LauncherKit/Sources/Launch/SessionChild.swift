// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Synchronization
import LauncherCore

package enum SessionChildStatus: Sendable, Equatable {
    case running, exited(Int32?)
}

/// Only for a child returned by this manager's spawner. A retained zombie keeps
/// its PID from reuse until waitpid consumes it. Reattached PIDs never enter here.
package final class OwnedSessionChild: Sendable {
    package let identity: ProcessIdentity
    private let status = Mutex(SessionChildStatus.running)
    private let read: @Sendable (ProcessIdentity) throws -> SessionChildStatus
    package init(identity: ProcessIdentity, read: @escaping @Sendable (ProcessIdentity) throws -> SessionChildStatus) {
        self.identity = identity; self.read = read
    }
    package func poll() async throws -> SessionChildStatus {
        try await BlockingIO.run {
            try self.status.withLock { status in
                if case .exited = status { return status }
                let next = try self.read(self.identity)
                status = next
                return next
            }
        }
    }
    package static func systemStatus(_ identity: ProcessIdentity) throws -> SessionChildStatus {
        var status: Int32 = 0
        while true {
            let result = waitpid(identity.pid, &status, WNOHANG)
            if result == 0 { return .running }
            if result == identity.pid { return decodeWaitStatus(status) }
            if errno == EINTR { continue }
            if errno == ECHILD { return .exited(nil) }
            throw LauncherError.io("Cannot inspect owned child exit status")
        }
    }
    package static func decodeWaitStatus(_ status: Int32) -> SessionChildStatus {
        let signal = status & 0x7f
        if signal == 0x7f { return .running } // A traced stop/continue is not an exit.
        return .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }
}
