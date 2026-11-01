// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Synchronization
import Testing
import LauncherCore
@testable import Launch

@Suite struct SessionChildTests {
    @Test func decodesPOSIXExitSignalAndStopStatuses() {
        #expect(OwnedSessionChild.decodeWaitStatus(13 << 8) == .exited(13))
        #expect(OwnedSessionChild.decodeWaitStatus(9) == .exited(137))
        #expect(OwnedSessionChild.decodeWaitStatus(0x137f) == .running)
        #expect(OwnedSessionChild.decodeWaitStatus(0xffff) == .running)
    }
    @Test func concurrentObserversReapExactlyOnceAndRetainExitCode() async throws {
        let polls = Mutex(0), identity = ProcessIdentity(pid: 42, startTime: 7)
        let child = OwnedSessionChild(identity: identity) { observed in
            #expect(observed == identity); polls.withLock { $0 += 1 }; return .exited(13)
        }
        async let first = child.poll()
        async let second = child.poll()
        #expect(try await first == .exited(13))
        #expect(try await second == .exited(13))
        #expect(polls.withLock { $0 } == 1)
    }
    @Test func runningIsNotTerminationAndInspectionFailureCanRetry() async throws {
        let polls = Mutex(0)
        let child = OwnedSessionChild(identity: ProcessIdentity(pid: 42, startTime: 7)) { _ in
            let count = polls.withLock { $0 += 1; return $0 }
            if count == 1 { throw LauncherError.io("injected wait failure") }
            return count == 2 ? .running : .exited(nil)
        }
        await #expect(throws: LauncherError.self) { _ = try await child.poll() }
        #expect(try await child.poll() == .running)
        #expect(try await child.poll() == .exited(nil))
        #expect(try await child.poll() == .exited(nil))
        #expect(polls.withLock { $0 } == 3)
    }
}
