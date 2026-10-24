// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import TestSupport

@Suite struct RosettaTests {
    @Test(arguments: [Int32(0), 1, 126])
    func exitMapping(code: Int32) async {
        let runner = RosettaRunner(result: .success(ProcessResult(exitCode: code, stdout: Data(), stderr: Data())))
        #expect(await SystemRosettaProbe(runner: runner).status() == (code == 0 ? .installed : .unknown))
    }
    @Test(arguments: ["arch: posix_spawnp: /usr/bin/true: Bad CPU type in executable", "Exec format error"])
    func architectureFailuresAreMissing(message: String) async {
        let runner = RosettaRunner(result: .success(ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(message.utf8))))
        #expect(await SystemRosettaProbe(runner: runner).status() == .missing)
    }
    @Test(arguments: [Int32(EBADARCH), ENOEXEC, EACCES, ENOENT])
    func execErrorsAreDistinguishedFromUncertainty(code: Int32) async {
        let runner = RosettaRunner(result: .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        #expect(await SystemRosettaProbe(runner: runner).status() == ([EBADARCH, ENOEXEC].contains(code) ? .missing : .unknown))
    }
    @Test func wrappedBadCPUErrorIsMissing() async {
        let runner = RosettaRunner(result: .failure(LauncherError.io("Bad CPU type in executable")))
        #expect(await SystemRosettaProbe(runner: runner).status() == .missing)
    }
    @Test func deadlineCancelsAndJoinsProbe() async throws {
        let runner = HangingRosettaRunner()
        let probe = SystemRosettaProbe(runner: runner, timeoutWait: { duration in
            #expect(duration == .seconds(5)); try await runner.entered.wait()
        })
        #expect(await probe.status() == .unknown)
        try await runner.cancelled.wait()
    }
}

private struct RosettaRunner: ProcessRunner {
    let result: Result<ProcessResult, any Error>
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        #expect(executable.path == "/usr/bin/arch")
        #expect(arguments == ["-x86_64", "/usr/bin/true"])
        #expect(environment["LC_ALL"] == "C")
        #expect(currentDirectory == nil)
        return try result.get()
    }
}
private final class HangingRosettaRunner: ProcessRunner, Sendable {
    let entered = TestEvent(), cancelled = TestEvent(), hold = TestEvent()
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        entered.signal()
        do { try await hold.wait(); return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
        catch { cancelled.signal(); throw error }
    }
}
