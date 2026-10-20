import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import Diagnostics

@Test
func bundleContainsExpectedFiles() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let original = "failure: token=planted-secret\n"
    try Data(original.utf8).write(to: logs.appendingPathComponent("macgacha.log"))
    try Data(#"{"metadata":{"TOKEN":"planted-secret"},"message":"Authorization: Bearer planted-secret"}"#.utf8)
        .write(to: logs.appendingPathComponent("macgacha.1.log"))
    try Data("{\n  \"token\":\n    \"planted-secret\"\n}\n".utf8).write(to: logs.appendingPathComponent("legacy.log"))
    try Data("ordinary text\n{\n\"token\":\n\"planted-secret\"\n}\n\n".utf8)
        .write(to: logs.appendingPathComponent("mixed.log"))
    let outside = root.appendingPathComponent("outside.log")
    try Data("must not be copied".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("symlink.log"), withDestinationURL: outside)
    let zip = root.appendingPathComponent("diagnostics.zip")
    let info = diagnosticFixtureInfo()
    try await DiagnosticBundle(logDirectory: logs, runner: SystemProcessRunner()).export(
        to: zip, systemInfo: info, runtimes: ["wine": "11.0", "TOKEN": "planted-secret"], failureStage: .download)
    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", zip.path, extracted.path], environment: [:], currentDirectory: nil)
    #expect(result.exitCode == 0)
    let decoded = try JSONDecoder().decode(SystemInfo.self, from: Data(contentsOf: extracted.appendingPathComponent("system.json")))
    #expect(decoded.appVersion == info.appVersion)
    #expect(decoded.memoryBytes == info.memoryBytes)
    let runtimes = try JSONDecoder().decode([String: String].self,
        from: Data(contentsOf: extracted.appendingPathComponent("runtimes.json")))
    #expect(runtimes["wine"] == "11.0")
    #expect(runtimes["TOKEN"] == "<redacted>")
    #expect(try String(contentsOf: extracted.appendingPathComponent("failure.txt"), encoding: .utf8) == "download\n")
    #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("logs/macgacha.log").path))
    #expect(!FileManager.default.fileExists(atPath: extracted.appendingPathComponent("logs/symlink.log").path))
    #expect(try String(contentsOf: extracted.appendingPathComponent("logs/mixed.log"), encoding: .utf8).hasSuffix("\n\n"))
    for file in try diagnosticRegularFiles(under: extracted) {
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("planted-secret"))
    }
    #expect(try String(contentsOf: logs.appendingPathComponent("macgacha.log"), encoding: .utf8) == original)
}

@Test
func bundleSkipsLogRotatedAwayBeforeOpen() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data("rotating".utf8).write(to: logs.appendingPathComponent("rotating.log"))
    try Data("stable\n".utf8).write(to: logs.appendingPathComponent("stable.log"))
    let removed = Mutex(false)
    let runner = DiagnosticTestRunner { arguments in
        let stagedLogs = URL(fileURLWithPath: arguments[3]).appendingPathComponent("logs")
        #expect(!FileManager.default.fileExists(atPath: stagedLogs.appendingPathComponent("rotating.log").path))
        #expect(try String(contentsOf: stagedLogs.appendingPathComponent("stable.log"), encoding: .utf8) == "stable\n")
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let bundle = DiagnosticBundle(logDirectory: logs, runner: runner, openLog: { file in
        if file.lastPathComponent == "rotating.log" {
            removed.withLock { $0 = unlink(file.path) == 0 }
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        let openError = errno
        errno = EACCES // The caller must use the captured errno, not thread-local state after return.
        return (fd, openError)
    })
    try await bundle.export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(),
        runtimes: [:], failureStage: nil)
    #expect(removed.withLock { $0 })
    #expect(try Data(contentsOf: root.appendingPathComponent("bundle.zip")) == Data("archive".utf8))
}

@Test
func bundleRedactsErrorsAndCleansUpFailedExports() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("existing.zip")
    try Data("existing archive".utf8).write(to: zip)
    let staging = Mutex<URL?>(nil)
    let runner = DiagnosticTestRunner { arguments in
        staging.withLock { $0 = URL(fileURLWithPath: arguments[3]) }
        return ProcessResult(exitCode: 2, stdout: Data(), stderr: Data("failed: token=planted-secret".utf8))
    }
    do {
        try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner).export(
            to: zip, systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: .verify)
        Issue.record("A failed archiver must throw")
    } catch LauncherError.processFailed(_, let exitCode, let stderrTail) {
        #expect(exitCode == 2)
        #expect(!stderrTail.contains("planted-secret"))
        #expect(stderrTail.contains("<redacted>"))
    }
    #expect(try Data(contentsOf: zip) == Data("existing archive".utf8))
    let staged = try #require(staging.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test
func bundleCancellationCleansUpAndPreservesDestination() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("existing.zip")
    try Data("existing archive".utf8).write(to: zip)
    let staging = Mutex<URL?>(nil)
    let runner = DiagnosticTestRunner { arguments in
        staging.withLock { $0 = URL(fileURLWithPath: arguments[3]) }
        try await Task.sleep(for: .seconds(30))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let task = Task {
        try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner).export(
            to: zip, systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
    }
    defer { task.cancel() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while staging.withLock({ $0 == nil }) {
        guard clock.now < deadline else { throw LauncherError.io("Timed out waiting for archiver") }
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(try Data(contentsOf: zip) == Data("existing archive".utf8))
    #expect(!FileManager.default.fileExists(atPath: try #require(staging.withLock { $0 }).path))
}

@Test
func bundleRejectsAlreadyCancelledExportBeforeRunningProcess() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ran = Mutex(false)
    let runner = DiagnosticTestRunner { _ in
        ran.withLock { $0 = true }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await DiagnosticBundle(logDirectory: root, runner: runner).export(to: root.appendingPathComponent("cancelled.zip"),
            systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(!ran.withLock { $0 })
}

@Test
func bundleTruncatesOversizedLogsAtALineBoundary() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("oversized.log")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 11 << 20)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("discard-partial-line\nlast complete line token=planted-secret\n".utf8))
    try handle.close()
    // Non-logs must not consume the 100-log allowance.
    for index in 0..<101 { try Data("ignored".utf8).write(to: logs.appendingPathComponent("other\(index).txt")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let copied = try String(contentsOf: staging.appendingPathComponent("logs/oversized.log"), encoding: .utf8)
        #expect(copied == "last complete line token=<redacted>\n")
        let skipped = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(skipped.contains("oversized.log"))
        #expect(skipped.contains("truncated"))
        #expect(skipped.contains("other0.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("logs").path) == ["oversized.log"])
        #expect(try String(contentsOf: staging.appendingPathComponent("failure.txt"), encoding: .utf8) == "none\n")
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
    #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 10 << 20)
}

@Test
func bundlePreservesLauncherErrorsAndRedactsForeignErrors() async throws {
    struct ForeignError: Error, CustomStringConvertible {
        var description: String { "failed: game_token=foreign-private" }
    }
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for expected in [LauncherError.insufficientSpace(required: 100, available: 1),
        .io("already structured"), .processFailed(executable: "tool", exitCode: 2, stderrTail: "already structured")] {
        let runner = DiagnosticTestRunner { _ in throw expected }
        await #expect(throws: expected) {
            try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner)
                .export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
        }
    }
    let runner = DiagnosticTestRunner { _ in throw ForeignError() }
    do {
        try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner)
            .export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
        Issue.record("Foreign error must throw")
    } catch LauncherError.io(let message) {
        #expect(!message.contains("foreign-private"))
        #expect(message.contains("<redacted>"))
    }
}

@Test
func realEventLogRoundTripsThroughBundleWithoutSecrets() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    let planted = "roundtrip-private-credential"
    let log = EventLog(directory: logs, maxFileBytes: 1024, keepFiles: 3)
    for index in 0..<8 {
        await log.log(.error, "test", "LoginResponse(game_token: \"\(planted)\", id: \(index))",
            metadata: ["ltmid_v2": planted, "header": "x-rpc-combo_token: \(planted) other-private"])
    }
    let zip = root.appendingPathComponent("bundle.zip")
    try await DiagnosticBundle(logDirectory: logs, runner: SystemProcessRunner()).export(to: zip,
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
    let extracted = root.appendingPathComponent("extracted")
    let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", zip.path, extracted.path], environment: [:], currentDirectory: nil)
    #expect(result.exitCode == 0)
    for file in try diagnosticRegularFiles(under: extracted) {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains(planted))
        #expect(!text.contains("other-private"))
    }
    #expect(try String(contentsOf: extracted.appendingPathComponent("failure.txt"), encoding: .utf8) == "none\n")
    let outputLogs = try FileManager.default.contentsOfDirectory(atPath: extracted.appendingPathComponent("logs").path)
    #expect(!outputLogs.isEmpty)
}

@Test
func systemInfoAndFailureStageAreCodable() throws {
    let info = SystemInfo.current(appVersion: "1.0-test")
    let version = ProcessInfo.processInfo.operatingSystemVersion
    #expect(info.macOSVersion == "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    #expect(!info.macOSBuild.isEmpty)
    #expect(!info.hardwareModel.isEmpty)
    #expect(!info.chip.isEmpty)
    #expect(info.memoryBytes > 0)
    #expect(info.appVersion == "1.0-test")
    _ = try JSONDecoder().decode(SystemInfo.self, from: JSONEncoder().encode(info))
    #expect(try JSONDecoder().decode(FailureStage.self, from: JSONEncoder().encode(FailureStage.download)) == .download)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(FailureStage.self, from: Data("\"arbitrary free text\"".utf8)) }
}

@Test
func bundleStopsAtTotalLogBudgetAndReportsSkippedLogs() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    var data = Data(repeating: 120, count: (10 << 20) - 1)
    data.append(10)
    for index in 0..<6 { try data.write(to: logs.appendingPathComponent("budget\(index).log")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let stagedLogs = staging.appendingPathComponent("logs")
        let names = try FileManager.default.contentsOfDirectory(atPath: stagedLogs.path).sorted()
        #expect(names == ["budget0.log", "budget1.log", "budget2.log", "budget3.log", "budget4.log"])
        var size = 0
        for name in names { size += try Data(contentsOf: stagedLogs.appendingPathComponent(name)).count }
        #expect(size == 50 << 20)
        let skipped = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(skipped.contains("budget5.log"))
        #expect(skipped.contains("budget"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

@Test
func bundleSkipsLogsAfterFileCountLimitWithoutFailing() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    for index in 0..<101 { try Data("line\n".utf8).write(to: logs.appendingPathComponent(String(format: "%03d.log", index))) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("logs").path).count == 100)
        let skipped = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(skipped.contains("100.log"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

private struct DiagnosticTestRunner: ProcessRunner {
    let action: @Sendable ([String]) async throws -> ProcessResult
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        #expect(executable.path == "/usr/bin/ditto")
        #expect(arguments.prefix(3) == ["-c", "-k", "--sequesterRsrc"])
        return try await action(arguments)
    }
}

private func diagnosticFixtureInfo() -> SystemInfo {
    SystemInfo(macOSVersion: "27.0", macOSBuild: "26A1", hardwareModel: "Mac-test", chip: "Apple Test",
        memoryBytes: 16 << 30, appVersion: "1.0")
}

private func diagnosticTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func diagnosticRegularFiles(under directory: URL) throws -> [URL] {
    let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    return try files.compactMap { entry in
        guard let url = entry as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
        return url
    }
}
