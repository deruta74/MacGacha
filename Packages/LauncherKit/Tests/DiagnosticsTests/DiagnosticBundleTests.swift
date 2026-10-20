import Foundation
import Synchronization
import Testing
import LauncherCore
import Diagnostics

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
    for file in try diagnosticRegularFiles(under: extracted) {
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("planted-secret"))
    }
    #expect(try String(contentsOf: logs.appendingPathComponent("macgacha.log"), encoding: .utf8) == original)
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
func bundleRejectsOversizedLogsBeforeRunningArchiver() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("oversized.log")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 11 << 20)
    try handle.close()
    let ran = Mutex(false)
    let runner = DiagnosticTestRunner { _ in
        ran.withLock { $0 = true }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    do {
        try await DiagnosticBundle(logDirectory: root, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
            systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
        Issue.record("An oversized log must fail before compression")
    } catch LauncherError.io {}
    #expect(!ran.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle.zip").path))
}

@Test
func systemInfoAndFailureStageAreCodable() throws {
    let info = SystemInfo.current(appVersion: "1.0-test")
    #expect(!info.macOSVersion.isEmpty)
    #expect(!info.macOSBuild.isEmpty)
    #expect(!info.hardwareModel.isEmpty)
    #expect(!info.chip.isEmpty)
    #expect(info.memoryBytes > 0)
    #expect(info.appVersion == "1.0-test")
    _ = try JSONDecoder().decode(SystemInfo.self, from: JSONEncoder().encode(info))
    #expect(try JSONDecoder().decode(FailureStage.self, from: JSONEncoder().encode(FailureStage.download)) == .download)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(FailureStage.self, from: Data("\"arbitrary free text\"".utf8)) }
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
