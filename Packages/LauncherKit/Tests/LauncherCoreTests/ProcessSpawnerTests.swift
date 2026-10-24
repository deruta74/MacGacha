// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import LauncherCore

@Suite(.timeLimit(.minutes(1))) struct ProcessSpawnerTests {
    @Test func discardOutputRunsChildWithoutLogsOrInheritedDescriptors() async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            let fd = open(temp.url.appendingPathComponent("private").path, O_RDWR | O_CREAT, 0o600)
            try #require(fd >= 0); defer { close(fd) }
            let inherited = fcntl(fd, F_DUPFD, 200)
            try #require(inherited >= 200); defer { close(inherited) }
            let script = "[ -c /dev/fd/1 ] && [ -c /dev/fd/2 ] || exit 2; [ ! -e /dev/fd/\(inherited) ] || exit 3; printf output; printf error >&2; printf done > proof"
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: [:], currentDirectory: temp.url, output: .discard)
            var pid = child.pid
            defer { if pid > 0 { killAndReap(pid) } }
            var status: Int32 = 0
            var result: Int32
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            try #require(result == pid); pid = 0
            #expect(status == 0)
            #expect(try String(contentsOf: temp.url.appendingPathComponent("proof"), encoding: .utf8) == "done")
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: temp.url.path)) == ["private", "proof"])
        }
    }

    @Test func spawnWritesOutputToFile() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("session.log")
            try Data("header\n".utf8).write(to: output)
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo out; echo err >&2"], environment: [:], currentDirectory: temp.url, outputFile: output)
            defer { killAndReap(child.pid) }
            try await waitUntil { !SystemProcessInspector().isAlive(child) }
            #expect(try String(contentsOf: output, encoding: .utf8) == "header\nout\nerr\n")
            // An exited, unreaped child is a zombie, not a live game.
            let info = try #require(SystemProcessKernel().process(pid: child.pid))
            #expect(Int32(info.kp_proc.p_stat) == SZOMB)
        }
    }

    @Test func spawnedEnvironmentIsExact() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("environment")
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                environment: ["A": "1"], currentDirectory: temp.url, outputFile: output)
            defer { killAndReap(child.pid) }
            try await waitUntil { !SystemProcessInspector().isAlive(child) }
            #expect(try String(contentsOf: output, encoding: .utf8) == "A=1\n")
        }
    }

    @Test func childHasNoInheritedDescriptorsAndHasItsOwnProcessGroup() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("probe")
            let descriptor = open(temp.url.appendingPathComponent("private").path, O_RDWR | O_CREAT, 0o600)
            try #require(descriptor >= 0); defer { close(descriptor) }
            let inherited = fcntl(descriptor, F_DUPFD, 200)
            try #require(inherited >= 200); defer { close(inherited) }
            try #require(fcntl(inherited, F_GETFD) & FD_CLOEXEC == 0)
            let script = "if [ -e /dev/fd/\(inherited) ]; then echo inherited; fi; if read -r line; then echo input; else echo eof; fi; /bin/pwd; /bin/ps -o pgid= -p $$"
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: [:], currentDirectory: temp.url, outputFile: output)
            defer { killAndReap(child.pid) }
            try await waitUntil { !SystemProcessInspector().isAlive(child) }
            let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
            try #require(lines.count == 3 && lines.first == "eof")
            let actual = try FileManager.default.attributesOfItem(atPath: lines[1])
            let requested = try FileManager.default.attributesOfItem(atPath: temp.url.path)
            #expect(actual[.systemFileNumber] as? NSNumber == requested[.systemFileNumber] as? NSNumber)
            #expect(lines.last?.trimmingCharacters(in: .whitespaces) == String(child.pid))
        }
    }

    @Test func spawnFailuresThrowLauncherError() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("log")
            #expect(throws: LauncherError.processSpawnFailed(errno: ENOENT)) {
                try SystemProcessSpawner().spawn(temp.url.appendingPathComponent("missing"), arguments: [], environment: [:],
                    currentDirectory: temp.url, output: .discard)
            }
            for executable in [temp.url.appendingPathComponent("missing"), temp.url] {
                #expect(throws: LauncherError.self) {
                    try SystemProcessSpawner().spawn(executable, arguments: [], environment: [:], currentDirectory: temp.url, outputFile: output)
                }
            }
            #expect(throws: LauncherError.self) {
                try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                    currentDirectory: temp.url.appendingPathComponent("missing"), outputFile: output)
            }
            #expect(throws: LauncherError.self) {
                try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                    currentDirectory: temp.url, outputFile: temp.url)
            }
        }
    }

    @Test func argumentsPathsAndEnvironmentValuesAreLiteral() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let cwd = temp.url.appendingPathComponent("working: with spaces")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false)
            let output = cwd.appendingPathComponent("session: log.txt")
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s\\n' \"$1\" \"$CUSTOM_VALUE\"", "sh", "literal ' : $ value"],
                environment: ["CUSTOM_VALUE": "a=b : value"], currentDirectory: cwd, outputFile: output)
            defer { killAndReap(child.pid) }
            try await waitUntil { !SystemProcessInspector().isAlive(child) }
            #expect(try String(contentsOf: output, encoding: .utf8) == "literal ' : $ value\na=b : value\n")
        }
    }

    @Test func invalidCStringInputsFailBeforeCreatingAChild() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("log")
            for (arguments, environment) in [(["bad\0argument"], [String: String]()),
                (["30"], ["BAD=KEY": "value"]), (["30"], ["": "value"]),
                (["30"], ["KEY": "bad\0value"]), (["30"], ["bad\0key": "value"])] {
                #expect(throws: LauncherError.self) {
                    let unexpected = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sleep"),
                        arguments: arguments, environment: environment, currentDirectory: temp.url, outputFile: output)
                    killAndReap(unexpected.pid)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func outputMustBeARegularFileRatherThanAPipe() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let fifo = temp.url.appendingPathComponent("pipe")
            try #require(mkfifo(fifo.path, 0o600) == 0)
            let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
            try #require(reader >= 0); defer { close(reader) }
            #expect(throws: LauncherError.self) {
                let unexpected = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: [:], currentDirectory: temp.url, outputFile: fifo)
                killAndReap(unexpected.pid)
            }
        }
    }

    @Test func symlinkOutputIsRejectedBeforeSpawningAndTargetIsUnchanged() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), reachedIdentity = Mutex(false)
            let target = temp.url.appendingPathComponent("unrelated"), output = temp.url.appendingPathComponent("session.log")
            let original = Data("keep this content\n".utf8)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
            let spawner = SystemProcessSpawner(readIdentity: { pid in
                reachedIdentity.withLock { $0 = true }
                return SystemProcessKernel().process(pid: pid)?.processIdentity
            })
            #expect(throws: LauncherError.self) {
                let unexpected = try spawner.spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo changed"],
                    environment: [:], currentDirectory: temp.url, outputFile: output)
                killAndReap(unexpected.pid)
            }
            #expect(!reachedIdentity.withLock { $0 })
            #expect(try Data(contentsOf: target) == original)
        }
    }

    @Test(arguments: [SIGTERM, SIGPIPE]) func childResetsInheritedSignals(signal: Int32) async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            let harness = Bundle(for: ProcessSpawnerBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
            // Only the isolated supervisor alters signal dispositions/masks.
            let result = try await SystemProcessRunner().run(harness,
                arguments: ["spawn-inherited-signals", String(signal), temp.url.appendingPathComponent("child.log").path],
                environment: [:], currentDirectory: temp.url)
            #expect(result.exitCode == 0, "Supervisor failed: \(result)")
        }
    }

    @Test func failedIdentityLookupDoesNotAbandonAChild() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let spawnedPID = Mutex<Int32?>(nil)
            let spawner = SystemProcessSpawner(readIdentity: { pid in spawnedPID.withLock { $0 = pid }; return nil })
            defer { if let pid = spawnedPID.withLock({ $0 }) { killAndReap(pid) } }
            #expect(throws: LauncherError.io("Cannot read spawned process identity")) {
                try spawner.spawn(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                    currentDirectory: temp.url, outputFile: temp.url.appendingPathComponent("log"))
            }
            let pid = try #require(spawnedPID.withLock { $0 })
            let exists = kill(pid, 0), error = errno
            // Do not signal this PID again after proving the spawner reaped it.
            if exists == -1 && error == ESRCH { spawnedPID.withLock { $0 = nil } }
            #expect(exists == -1 && error == ESRCH)
        }
    }

    @Test func rapidlyExitingChildrenStillHaveKernelIdentityAndRemainOwnerReapable() async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            for _ in 0..<50 {
                let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: [:], currentDirectory: temp.url, outputFile: temp.url.appendingPathComponent("log"))
                defer { killAndReap(child.pid) }
                try await waitUntil { !SystemProcessInspector().isAlive(child) }
                #expect(SystemProcessKernel().process(pid: child.pid)?.processIdentity == child)
            }
        }
    }

    @Test func logDescriptorsCloseOnBothSpawnSuccessAndFailure() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let output = temp.url.appendingPathComponent("log")
            for _ in 0..<20 {
                let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: [:], currentDirectory: temp.url, outputFile: output)
                killAndReap(child.pid)
                #expect(throws: LauncherError.self) {
                    let unexpected = try SystemProcessSpawner().spawn(temp.url.appendingPathComponent("missing"), arguments: [],
                        environment: [:], currentDirectory: temp.url, outputFile: output)
                    killAndReap(unexpected.pid)
                }
            }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            for fd in 0..<getdtablesize() {
                let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
                if result == 0 {
                    let name = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    #expect(!name.hasSuffix("/\(temp.url.lastPathComponent)/log"), "Leaked process log descriptor \(fd)")
                }
            }
        }
    }

    @Test func inspectorFindsProcessByEnvironment() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(); let tag = UUID().uuidString
            // SIP hides the environment of Apple's platform /bin/sleep. Use an
            // ad-hoc signed temporary copy, like the third-party Wine processes
            // this inspector will discover. The system binary stays untouched.
            let executable = temp.url.appendingPathComponent("sleep")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
            let signature = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", executable.path], environment: [:], currentDirectory: nil)
            try #require(signature.exitCode == 0)
            let child = try SystemProcessSpawner().spawn(executable, arguments: ["30"],
                environment: ["MACGACHA_TEST_TAG": tag], currentDirectory: temp.url, outputFile: temp.url.appendingPathComponent("log"))
            defer { killAndReap(child.pid) }
            var result: [InspectedProcess] = []
            try await waitUntil {
                result = try SystemProcessInspector().processes(environmentContains: "MACGACHA_TEST_TAG", value: tag,
                    scope: ProcessInspectionScope(executableRoots: [temp.url], processGroupIDs: [child.pid]))
                return !result.isEmpty
            }
            #expect(result.map(\.identity) == [child])
            #expect(result.first?.executablePath.hasSuffix("/sleep") == true)
            #expect(result.first?.arguments == [executable.path, "30"])
        }
    }

    @Test func childSurvivesSupervisorDeath() async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            let harness = Bundle(for: ProcessSpawnerBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
            try #require(FileManager.default.isExecutableFile(atPath: harness.path))
            let output = temp.url.appendingPathComponent("child.log")
            let identityFile = temp.url.appendingPathComponent("identity.json")
            let stopFile = temp.url.appendingPathComponent("stop")
            let published = try FileAppearanceEvent(identityFile)
            let supervisor = try SystemProcessSpawner().spawn(harness,
                arguments: ["spawn-writer", output.path, identityFile.path, stopFile.path], environment: [:], currentDirectory: temp.url,
                outputFile: temp.url.appendingPathComponent("supervisor.log"))
            var ownsSupervisor = true
            defer { if ownsSupervisor { stopWriterSupervisor(supervisor.pid, stopFile: stopFile) } }
            try await published.wait()
            let child = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: identityFile))
            // After SIGKILL the orphan is adopted/reaped by launchd, not by this
            // test. Kill the entire writer group; reap the supervisor we own.
            defer { if SystemProcessInspector().isAlive(child) { _ = kill(-child.pid, SIGKILL) } }
            let initialSize = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            try #require(kill(supervisor.pid, SIGKILL) == 0)
            var status: Int32 = 0
            var reaped: Int32
            repeat { reaped = waitpid(supervisor.pid, &status, 0) } while reaped < 0 && errno == EINTR
            try #require(reaped == supervisor.pid); ownsSupervisor = false
            try await Task.sleep(for: .seconds(2))
            #expect(SystemProcessInspector().isAlive(child))
            try await waitUntil {
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                return (attributes[.size] as? NSNumber)?.int64Value ?? 0 > initialSize + (1 << 20)
            }
            _ = kill(-child.pid, SIGKILL)
            try await waitUntil { SystemProcessKernel().process(pid: child.pid) == nil }
        }
    }

    @Test func supervisorCleanupBeforeReadingIdentityStopsTheWriter() async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            let harness = Bundle(for: ProcessSpawnerBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
            let identityFile = temp.url.appendingPathComponent("identity.json"), stopFile = temp.url.appendingPathComponent("stop")
            let published = try FileAppearanceEvent(identityFile)
            let supervisor = try SystemProcessSpawner().spawn(harness,
                arguments: ["spawn-writer", temp.url.appendingPathComponent("child.log").path, identityFile.path, stopFile.path],
                environment: [:], currentDirectory: temp.url, outputFile: temp.url.appendingPathComponent("supervisor.log"))
            var ownsSupervisor = true
            defer { if ownsSupervisor { stopWriterSupervisor(supervisor.pid, stopFile: stopFile) } }
            try await published.wait()
            // Observe the child only for the assertion. The cleanup routine does
            // not receive it, as on cancellation/read/decode failure in the controller.
            let child = try JSONDecoder().decode(ProcessIdentity.self, from: Data(contentsOf: identityFile))
            defer { if SystemProcessInspector().isAlive(child) { _ = kill(-child.pid, SIGKILL) } }
            stopWriterSupervisor(supervisor.pid, stopFile: stopFile); ownsSupervisor = false
            #expect(SystemProcessKernel().process(pid: child.pid) == nil)
            if SystemProcessInspector().isAlive(child) { _ = kill(-child.pid, SIGKILL) }
            try await waitUntil { SystemProcessKernel().process(pid: child.pid) == nil }
        }
    }
}

private final class ProcessSpawnerBundleToken: NSObject {}

private func stopWriterSupervisor(_ pid: Int32, stopFile: URL) {
    // Do not SIGKILL before learning the writer's identity: it owns a separate
    // process group. Let the supervisor kill/reap it before reaping the supervisor.
    // Its 45-second failsafe also bounds cleanup if creating the marker fails.
    try? Data().write(to: stopFile, options: .atomic)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
}

func killAndReap(_ pid: Int32) {
    guard pid > 0 else { return }
    _ = kill(-pid, SIGKILL); _ = kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
}

func waitUntil(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while try !condition() {
        try #require(ContinuousClock.now < deadline, "Process condition did not become true")
        try await Task.sleep(for: .milliseconds(10))
    }
}
