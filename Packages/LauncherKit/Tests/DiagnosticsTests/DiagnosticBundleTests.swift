// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
    let original = String(decoding: try diagnosticRecord(message: "failure: token=planted-secret"), as: UTF8.self)
    try Data(original.utf8).write(to: logs.appendingPathComponent("macgacha.log"))
    try diagnosticRecord(message: "legacy", metadata: ["TOKEN": "planted-secret"])
        .write(to: logs.appendingPathComponent("macgacha.1.log"))
    for name in ["wine.log", "game.log", "macgacha-extra.log", "macgacha.bad.log", "macgacha.01.log"] {
        try Data("planted-secret\n".utf8).write(to: logs.appendingPathComponent(name))
    }
    let outside = root.appendingPathComponent("outside.log")
    try Data("must not be copied".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("macgacha.2.log"), withDestinationURL: outside)
    let zip = root.appendingPathComponent("diagnostics.zip")
    let info = diagnosticFixtureInfo()
    try await DiagnosticBundle(logDirectory: logs, runner: SystemProcessRunner()).export(
        to: zip, systemInfo: info, runtimes: ["wine": "11.0", "TOKEN": "planted-secret"], failureStage: .download)
    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", zip.path, extracted.path], environment: [:], currentDirectory: nil)
    #expect(result.exitCode == 0)
    let decoded = try JSONDecoder().decode(SystemInfo.self, from: Data(contentsOf: extracted.appendingPathComponent("system.json")))
    #expect(try FileManager.default.contentsOfDirectory(atPath: extracted.appendingPathComponent("logs").path).sorted()
        == ["macgacha.1.log", "macgacha.log"])
    #expect(decoded.appVersion == info.appVersion)
    #expect(decoded.memoryBytes == info.memoryBytes)
    let runtimes = try JSONDecoder().decode([String: String].self,
        from: Data(contentsOf: extracted.appendingPathComponent("runtimes.json")))
    #expect(runtimes["wine"] == "11.0")
    #expect(runtimes["TOKEN"] == "<redacted>")
    #expect(try String(contentsOf: extracted.appendingPathComponent("failure.txt"), encoding: .utf8) == "download\n")
    #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("logs/macgacha.log").path))
    #expect(!FileManager.default.fileExists(atPath: extracted.appendingPathComponent("logs/macgacha.2.log").path))
    #expect(try String(contentsOf: extracted.appendingPathComponent("logs/macgacha.log"), encoding: .utf8).hasSuffix("\n"))
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
    try diagnosticRecord(message: "rotating").write(to: logs.appendingPathComponent("macgacha.1.log"))
    try diagnosticRecord(message: "stable").write(to: logs.appendingPathComponent("macgacha.log"))
    let removed = Mutex(false)
    let runner = DiagnosticTestRunner { arguments in
        let stagedLogs = URL(fileURLWithPath: arguments[3]).appendingPathComponent("logs")
        #expect(!FileManager.default.fileExists(atPath: stagedLogs.appendingPathComponent("macgacha.1.log").path))
        #expect(try String(contentsOf: stagedLogs.appendingPathComponent("macgacha.log"), encoding: .utf8).contains("stable"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let bundle = DiagnosticBundle(logDirectory: logs, runner: runner, openLog: { file in
        if file.lastPathComponent == "macgacha.1.log" {
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
    let file = logs.appendingPathComponent("macgacha.log")
    var original = try diagnosticRecord(message: String(repeating: "x", count: 11 << 20), metadata: ["TOKEN": "cutoff-private"])
    original.append(try diagnosticRecord(message: "surviving record", metadata: ["accountMid": "planted-secret"]))
    try original.write(to: file)
    for index in 0..<101 { try Data("ignored".utf8).write(to: logs.appendingPathComponent("other\(index).txt")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let copied = try String(contentsOf: staging.appendingPathComponent("logs/macgacha.log"), encoding: .utf8)
        #expect(copied.contains("surviving record"))
        #expect(!copied.contains("cutoff-private"))
        #expect(!copied.contains("planted-secret"))
        #expect(copied.split(separator: "\n").count == 1)
        _ = try JSONSerialization.jsonObject(with: Data(copied.utf8))
        let skipped = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(skipped.contains("macgacha.log"))
        #expect(skipped.contains("truncated"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("logs").path) == ["macgacha.log"])
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
    let overhead = try diagnosticRecord(message: "").count
    let record = try diagnosticRecord(message: String(repeating: "x", count: (1 << 20) - overhead))
    #expect(record.count == 1 << 20)
    var data = Data()
    for _ in 0..<9 { data.append(record) }
    for index in 1...7 { try data.write(to: logs.appendingPathComponent("macgacha.\(index).log")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let stagedLogs = staging.appendingPathComponent("logs")
        let names = try FileManager.default.contentsOfDirectory(atPath: stagedLogs.path).sorted()
        #expect(!names.isEmpty)
        var size = 0
        for name in names { size += try Data(contentsOf: stagedLogs.appendingPathComponent(name)).count }
        let report = try Data(contentsOf: staging.appendingPathComponent("skipped.txt"))
        #expect(size + report.count <= 50 << 20)
        #expect(size > 40 << 20)
        #expect(String(decoding: report, as: UTF8.self).contains("budget"))
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
    for index in 1...101 { try diagnosticRecord(message: "line").write(to: logs.appendingPathComponent("macgacha.\(index).log")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("logs").path).count == 100)
        let skipped = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(skipped.contains("Skipped files: 1"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

@Test
func bundleDropsInvalidRecordsAndUnknownFields() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    var data = try diagnosticRecord(message: "token=planted-secret", metadata: ["accountMid": "planted-secret"])
    data.append(Data("not JSON planted-secret\n{\"message\":\"planted-secret\"}\n[]\n".utf8))
    var record = try #require(JSONSerialization.jsonObject(with: diagnosticRecord(message: "safe")) as? [String: Any])
    record["unknownBody"] = "planted-secret"
    data.append(try JSONSerialization.data(withJSONObject: record))
    data.append(10)
    try data.write(to: logs.appendingPathComponent("macgacha.log"))
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let output = try String(contentsOf: staging.appendingPathComponent("logs/macgacha.log"), encoding: .utf8)
        #expect(output.split(separator: "\n").count == 2)
        #expect(!output.contains("planted-secret"))
        #expect(!output.contains("unknownBody"))
        let report = try String(contentsOf: staging.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(report.contains("Dropped records: 3"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

@Test
func bundleBoundsEnumerationAndSkippedReport() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let controls = String(repeating: "\u{1}", count: 200)
    for index in 0..<1005 { try Data().write(to: logs.appendingPathComponent(controls + "ignored\(index).txt")) }
    let runner = DiagnosticTestRunner { arguments in
        let staging = URL(fileURLWithPath: arguments[3])
        let reportData = try Data(contentsOf: staging.appendingPathComponent("skipped.txt"))
        let report = String(decoding: reportData, as: UTF8.self)
        #expect(report.contains("Skipped files: 1000"))
        #expect(report.contains("Enumeration stopped at 1000 entries"))
        #expect(report.contains("950 additional file notices"))
        #expect(report.split(separator: "\n").filter { $0.hasPrefix("file: ") }.count == 50)
        #expect(reportData.count <= 32 << 10)
        #expect(report.split(separator: "\n").allSatisfy { $0.utf8.count <= 512 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("logs").path).isEmpty)
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

@Test
func bundleRedactsStructuredErrorPayloads() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for error in [LauncherError.io("token=planted-secret"), .processFailed(executable: "tool?token=planted-secret",
        exitCode: 3, stderrTail: "Proxy-Authorization: Bearer planted-secret")] {
        let runner = DiagnosticTestRunner { _ in throw error }
        do {
            try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner)
                .export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
            Issue.record("Expected runner error")
        } catch let result as LauncherError {
            #expect(!String(describing: result).contains("planted-secret"))
            switch (error, result) {
            case (.io, .io), (.processFailed, .processFailed): break
            default: Issue.record("LauncherError case must be preserved")
            }
        }
    }
}

@Test
func bundleCancellationTakesPrecedenceOverEveryThrownError() async throws {
    struct ForeignError: Error {}
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let errors: [any Error] = [LauncherError.io("failure"), LauncherError.insufficientSpace(required: 2, available: 1), ForeignError()]
    for error in errors {
        let runner = DiagnosticTestRunner { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw error
        }
        let task = Task {
            try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner)
                .export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
        }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
    }
}

@Test
func bundleRedactsAllLauncherErrorPayloads() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pairs: [(LauncherError, LauncherError)] = [
        (.unsafePath("token=error-private"), .unsafePath("token=<redacted>")),
        (.invalidDigest("token=error-private"), .invalidDigest("token=<redacted>")),
        (.sizeMismatch(path: "token=error-private", expected: 2, actual: 1), .sizeMismatch(path: "token=<redacted>", expected: 2, actual: 1)),
        (.digestMismatch(path: "token=error-private", expected: "token=error-private", actual: "token=error-private"),
            .digestMismatch(path: "token=<redacted>", expected: "token=<redacted>", actual: "token=<redacted>")),
        (.insufficientSpace(required: 2, available: 1), .insufficientSpace(required: 2, available: 1)),
        (.http(status: 401, url: URL(string: "https://example.test/?token=error-private&lang=en")!),
            .http(status: 401, url: URL(string: "https://example.test/?token=%3Credacted%3E&lang=en")!)),
        (.transport("token=error-private"), .transport("token=<redacted>")),
        (.io("token=error-private"), .io("token=<redacted>")),
        (.busy("token=error-private"), .busy("token=<redacted>")),
        (.fileTooLarge(path: "token=error-private", limit: 1024), .fileTooLarge(path: "token=<redacted>", limit: 1024)),
        (.consentRequired("token=error-private"), .consentRequired("token=<redacted>")),
        (.processFailed(executable: "token=error-private", exitCode: 2, stderrTail: "token=error-private"),
            .processFailed(executable: "token=<redacted>", exitCode: 2, stderrTail: "token=<redacted>")),
        (.cancelled, .cancelled),
        (.journalCorrupt("token=error-private"), .journalCorrupt("token=<redacted>")),
    ]
    for (source, expected) in pairs {
        let runner = DiagnosticTestRunner { _ in throw source }
        await #expect(throws: expected) {
            try await DiagnosticBundle(logDirectory: root.appendingPathComponent("missing"), runner: runner)
                .export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
        }
    }
}

@Test(arguments: [999, 1000, 1001])
func enumerationStoppedRequiresAnAdditionalEntry(entryCount: Int) async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    for index in 0..<entryCount { try Data().write(to: logs.appendingPathComponent("ignored\(index).txt")) }
    let runner = DiagnosticTestRunner { arguments in
        let staged = URL(fileURLWithPath: arguments[3])
        let report = try String(contentsOf: staged.appendingPathComponent("skipped.txt"), encoding: .utf8)
        #expect(report.contains("Enumeration stopped") == (entryCount > 1000))
        #expect(report.contains("Entries examined: \(min(1000, entryCount))"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
}

@Test
func fiveMiBOfRecordsAreStructurallyReredactedWithinCoarseBudget() async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    var metadata = Dictionary(uniqueKeysWithValues: (0..<32).map { ("version\($0)", "1.2.3") })
    metadata["TOKEN"] = "performance-private"
    let record = try diagnosticRecord(message: "password=performance-private " + String(repeating: "x", count: 512), metadata: metadata)
    var data = Data()
    var count = 0
    while data.count < 5 << 20 { data.append(record); count += 1 }
    let expectedRecords = count
    try data.write(to: logs.appendingPathComponent("macgacha.log"))
    let runner = DiagnosticTestRunner { arguments in
        let staged = URL(fileURLWithPath: arguments[3])
        let output = try Data(contentsOf: staged.appendingPathComponent("logs/macgacha.log"))
        #expect(output.split(separator: 10).count == expectedRecords)
        #expect(!String(decoding: output, as: UTF8.self).contains("performance-private"))
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let clock = ContinuousClock()
    let start = clock.now
    try await DiagnosticBundle(logDirectory: logs, runner: runner).export(to: root.appendingPathComponent("bundle.zip"),
        systemInfo: diagnosticFixtureInfo(), runtimes: [:], failureStage: nil)
    // Hang guard for slow debug/parallel CI runs, not a performance benchmark.
    #expect(start.duration(to: clock.now) < .seconds(60))
}

@Test(arguments: [2, 3, 4])
func bundlePrioritizesActiveThenNumericRotationsWithinBudget(fileBudget: Int) async throws {
    let root = try diagnosticTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let logs = root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let record = try diagnosticRecord(message: "record")
    let expectedOrder = ["macgacha.log", "macgacha.1.log", "macgacha.2.log", "macgacha.10.log"]
    for name in expectedOrder.reversed() { try record.write(to: logs.appendingPathComponent(name)) }
    let opened = Mutex<[String]>([])
    let runner = DiagnosticTestRunner { arguments in
        let stagedLogs = URL(fileURLWithPath: arguments[3]).appendingPathComponent("logs")
        let names = try FileManager.default.contentsOfDirectory(atPath: stagedLogs.path)
        #expect(Set(names) == Set(expectedOrder.prefix(fileBudget)))
        for name in names { #expect(try Data(contentsOf: stagedLogs.appendingPathComponent(name)) == record) }
        try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments[4]))
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let bundle = DiagnosticBundle(logDirectory: logs, runner: runner, openLog: { file in
        opened.withLock { $0.append(file.lastPathComponent) }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        let openError = errno
        return (fd, openError)
    }, logByteLimit: fileBudget * record.count)
    try await bundle.export(to: root.appendingPathComponent("bundle.zip"), systemInfo: diagnosticFixtureInfo(),
        runtimes: [:], failureStage: nil)
    #expect(opened.withLock { $0 } == Array(expectedOrder.prefix(fileBudget)))
}

private func diagnosticRecord(message: String, metadata: [String: String] = [:]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["ts": "2026-10-20T12:00:00Z", "level": "info",
        "category": "test", "message": message, "metadata": metadata], options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    return data
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
