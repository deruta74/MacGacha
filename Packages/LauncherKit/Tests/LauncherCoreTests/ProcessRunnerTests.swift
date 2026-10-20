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
