import Darwin
import Foundation
import Testing
import LauncherCore

@Test
func processRunnerCapturesOutput() async throws {
    let runner = SystemProcessRunner()
    let result = try await runner.run(
        URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo out; echo err >&2; exit 3"],
        environment: [:],
        currentDirectory: nil
    )
    #expect(result.exitCode == 3)
    #expect(result.stdout == Data("out\n".utf8))
    #expect(result.stderr == Data("err\n".utf8))

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environmentResult = try await runner.run(
        URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '%s' \"$MACGACHA_TEST_VALUE\"; /bin/pwd -P"],
        environment: ["MACGACHA_TEST_VALUE": "child-value:"],
        currentDirectory: directory
    )
    #expect(environmentResult.exitCode == 0)
    let output = String(decoding: environmentResult.stdout, as: UTF8.self)
    #expect(output.hasPrefix("child-value:"))
    let childDirectory = URL(fileURLWithPath: String(output.dropFirst("child-value:".count))
        .trimmingCharacters(in: .newlines))
    #expect(childDirectory.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    #expect(environmentResult.stderr.isEmpty)

    // Each stream exceeds pipe capacity: both must be drained while the child runs.
    let largeOutput = try await runner.run(
        URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "/usr/bin/head -c 262144 /dev/zero; /usr/bin/head -c 262144 /dev/zero >&2"],
        environment: [:],
        currentDirectory: nil
    )
    #expect(largeOutput.exitCode == 0)
    #expect(largeOutput.stdout == Data(repeating: 0, count: 262_144))
    #expect(largeOutput.stderr == Data(repeating: 0, count: 262_144))
}

@Test
func processRunnerRejectsCancellationBeforeLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")

    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SystemProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf launched > \"$MACGACHA_LAUNCH_MARKER\""],
            environment: ["MACGACHA_LAUNCH_MARKER": marker.path],
            currentDirectory: nil
        )
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test
func processRunnerCancelsAndReapsChild() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("child.pid")

    let task = Task {
        try await SystemProcessRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            // exec preserves the PID, so the recorded process becomes /bin/sleep itself.
            arguments: ["-c", "printf '%s' \"$$\" > \"$MACGACHA_CHILD_PID\"; exec /bin/sleep 30"],
            environment: ["MACGACHA_CHILD_PID": pidFile.path],
            currentDirectory: nil
        )
    }
    defer { task.cancel() }
    let clock = ContinuousClock()
    let launchDeadline = clock.now.advanced(by: .seconds(5))
    var childPID: Int32?
    while clock.now < launchDeadline {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text), pid > 0 {
            childPID = pid
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try #require(childPID, "The child must launch and publish its PID")
    defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
    try await Task.sleep(for: .milliseconds(200))

    // Bound the failing implementation's runtime and clean up its child.
    let watchdog = Task {
        try await Task.sleep(for: .seconds(5))
        kill(pid, SIGKILL)
    }
    defer { watchdog.cancel() }
    let cancelledAt = clock.now
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(cancelledAt.duration(to: clock.now) < .seconds(5))
    let childStatus = kill(pid, 0)
    let childError = errno
    #expect(childStatus == -1)
    #expect(childError == ESRCH)
}

@Test
func processRunnerReportsLaunchFailure() async throws {
    let missingExecutable = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("missing-executable")
    do {
        _ = try await SystemProcessRunner().run(
            missingExecutable,
            arguments: [],
            environment: [:],
            currentDirectory: nil
        )
        Issue.record("A missing executable must fail to launch")
    } catch LauncherError.io {
        // Launch failures must also release the pending pipe readers.
    }
}
