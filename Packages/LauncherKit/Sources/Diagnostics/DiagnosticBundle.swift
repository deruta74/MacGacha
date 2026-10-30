// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import LauncherCore

public struct DiagnosticBundle: Sendable {
    private let logDirectory: URL
    private let runner: any ProcessRunner
    private let beforeEventOpen: @Sendable (URL) -> Void
    private let logByteLimit: Int
    private let sessionLogURLs: [URL]
    private let gameLogRoot: URL?
    private let gameLogCandidates: [String: [SafeRelativePath]]
    private let sessionLogsEnabled: Bool
    private let logDiscoveryFailures: [String]
    private let beforeOptionalOpen: @Sendable (URL) -> Void

    /// Optional launch logs are selected by the caller, without a dependency on Launch.
    /// Game candidates are relative to gameLogRoot and opened through containment.
    /// Failed discovery scopes are redacted and included in the bounded skip report.
    public init(logDirectory: URL, runner: any ProcessRunner, sessionLogURLs: [URL] = [],
        gameLogRoot: URL? = nil, gameLogCandidates: [String: [SafeRelativePath]] = [:], sessionLogsEnabled: Bool = true,
        logDiscoveryFailures: [String] = []) {
        self.init(logDirectory: logDirectory, runner: runner, logByteLimit: nil,
            sessionLogURLs: sessionLogURLs, gameLogRoot: gameLogRoot, gameLogCandidates: gameLogCandidates,
            sessionLogsEnabled: sessionLogsEnabled, logDiscoveryFailures: logDiscoveryFailures)
    }

    init(logDirectory: URL, runner: any ProcessRunner, logByteLimit: Int?,
        sessionLogURLs: [URL] = [], gameLogRoot: URL? = nil,
        gameLogCandidates: [String: [SafeRelativePath]] = [:], sessionLogsEnabled: Bool = true,
        logDiscoveryFailures: [String] = [], beforeEventOpen: @escaping @Sendable (URL) -> Void = { _ in },
        beforeOptionalOpen: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.beforeOptionalOpen = beforeOptionalOpen
        self.sessionLogURLs = sessionLogURLs
        self.gameLogRoot = gameLogRoot
        self.gameLogCandidates = gameLogCandidates
        self.sessionLogsEnabled = sessionLogsEnabled
        self.logDiscoveryFailures = logDiscoveryFailures
        self.logDirectory = logDirectory
        self.runner = runner
        self.beforeEventOpen = beforeEventOpen
        let maximum = Self.totalLimit - Self.reportLimit
        self.logByteLimit = min(maximum, max(0, logByteLimit ?? maximum))
    }

    public func export(to zipURL: URL, systemInfo: SystemInfo, runtimes: [String: String], failureStage: FailureStage?) async throws {
        do { try await BlockingIO.run { try await exportOnIO(to: zipURL, systemInfo: systemInfo, runtimes: runtimes, failureStage: failureStage) } }
        catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func exportOnIO(to zipURL: URL, systemInfo: SystemInfo, runtimes: [String: String],
        failureStage: FailureStage?) async throws {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("macgacha-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let archive = zipURL.deletingLastPathComponent().appendingPathComponent(".macgacha-diagnostics-\(UUID().uuidString).zip")
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: archive)
        }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try write(Redactor.redact(String(decoding: encoder.encode(systemInfo), as: UTF8.self)),
                to: staging.appendingPathComponent("system.json"))
            try write(String(decoding: encoder.encode(Redactor.redact(metadata: runtimes)), as: UTF8.self),
                to: staging.appendingPathComponent("runtimes.json"))
            try write((failureStage?.rawValue ?? "none") + "\n", to: staging.appendingPathComponent("failure.txt"))
            if !sessionLogsEnabled {
                try write("session logs disabled\n", to: staging.appendingPathComponent("session-logs.txt"))
            }
            try copyLogs(to: staging.appendingPathComponent("logs", isDirectory: true))
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--sequesterRsrc", staging.path, archive.path],
                environment: [:], currentDirectory: nil)
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard result.exitCode == 0 else {
                let stderr = Redactor.redact(String(decoding: result.stderr, as: UTF8.self))
                throw LauncherError.processFailed(executable: "/usr/bin/ditto", exitCode: result.exitCode,
                    stderrTail: String(stderr.suffix(4096)))
            }
            // A sibling archive makes publication atomic and preserves any previous export on failure.
            guard rename(archive.path, zipURL.path) == 0 else { throw LauncherError.io("Cannot publish diagnostic archive") }
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            guard let launcherError = error as? LauncherError else {
                throw LauncherError.io(Redactor.redact(String(describing: error)))
            }
            switch launcherError {
            case .unsafePath(let path): throw LauncherError.unsafePath(Redactor.redact(path))
            case .invalidDigest(let digest): throw LauncherError.invalidDigest(Redactor.redact(digest))
            case .sizeMismatch(let path, let expected, let actual):
                throw LauncherError.sizeMismatch(path: Redactor.redact(path), expected: expected, actual: actual)
            case .digestMismatch(let path, let expected, let actual):
                throw LauncherError.digestMismatch(path: Redactor.redact(path), expected: Redactor.redact(expected),
                    actual: Redactor.redact(actual))
            case .insufficientSpace(let required, let available):
                throw LauncherError.insufficientSpace(required: required, available: available)
            case .http(let status, let url):
                let safeURL = URL(string: Redactor.redact(url.absoluteString)) ?? URL(fileURLWithPath: "/redacted")
                throw LauncherError.http(status: status, url: safeURL)
            case .transport(let message): throw LauncherError.transport(Redactor.redact(message))
            case .io(let message): throw LauncherError.io(Redactor.redact(message))
            case .busy(let message): throw LauncherError.busy(Redactor.redact(message))
            case .fileTooLarge(let path, let limit):
                throw LauncherError.fileTooLarge(path: Redactor.redact(path), limit: limit)
            case .consentRequired(let component): throw LauncherError.consentRequired(Redactor.redact(component))
            case .processSpawnFailed: throw error
            case .processFailed(let executable, let code, let stderr):
                throw LauncherError.processFailed(executable: Redactor.redact(executable), exitCode: code,
                    stderrTail: Redactor.redact(stderr))
            case .gameEditionMismatch, .gameEditionUnknown, .gameDistributionUnsupported, .rosettaMissing, .rosettaInstallerUnavailable, .languageRestartFailed: throw error
            case .cancelled: throw LauncherError.cancelled
            case .journalCorrupt(let message): throw LauncherError.journalCorrupt(Redactor.redact(message))
            }
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // The report reserve is part of the 50 MiB total, never an extra allowance.
    private static let fileLimit = 10 << 20
    private static let totalLimit = 50 << 20
    private static let reportLimit = 32 << 10
    private static let entryLimit = 1000
    private static let logLimit = 100

    private struct CopyReport {
        var skippedFiles = 0
        var truncatedFiles = 0
        var droppedRecords = 0
        var budgetRecords = 0
        var entries = 0
        var enumerationStopped = false
        var notices = 0
        var names: [String] = []

        mutating func note(_ name: String, reason: String) {
            notices += 1
            guard names.count < 50 else { return }
            // JSON quoting keeps malicious filename newlines/control characters on a single report line.
            let safeName = Redactor.redactLog(name)
            let encoded = (try? String(decoding: JSONEncoder().encode(safeName), as: UTF8.self)) ?? "<omitted>"
            let line = "file: \(reason): \(encoded)"
            var bounded = ""
            for scalar in line.unicodeScalars {
                guard bounded.utf8.count + scalar.utf8.count <= 512 else { break }
                bounded.unicodeScalars.append(scalar)
            }
            names.append(bounded)
        }

        var text: String {
            var lines = ["Skipped files: \(skippedFiles)", "Truncated files: \(truncatedFiles)",
                "Dropped records: \(droppedRecords)", "Records omitted for budget: \(budgetRecords)",
                "Entries examined: \(entries)"]
            if enumerationStopped { lines.append("Enumeration stopped at 1000 entries; unexamined entries are not counted") }
            lines += names
            if notices > names.count { lines.append("\(notices - names.count) additional file notices omitted") }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private func isEventLog(_ name: String) -> Bool {
        if name == "macgacha.log" { return true }
        guard name.hasPrefix("macgacha."), name.hasSuffix(".log") else { return false }
        let number = name.dropFirst(9).dropLast(4)
        return !number.isEmpty && number.first != "0" && number.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func logPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.lastPathComponent
        let right = rhs.lastPathComponent
        let leftIsLog = isEventLog(left)
        let rightIsLog = isEventLog(right)
        if leftIsLog != rightIsLog { return leftIsLog }
        guard leftIsLog else { return left < right }
        if left == "macgacha.log" { return right != "macgacha.log" }
        if right == "macgacha.log" { return false }
        let leftIndex = left.dropFirst(9).dropLast(4)
        let rightIndex = right.dropFirst(9).dropLast(4)
        // Canonical decimal indices compare by digit count, then digits, without integer overflow.
        if leftIndex.count != rightIndex.count { return leftIndex.count < rightIndex.count }
        return leftIndex.lexicographicallyPrecedes(rightIndex)
    }

    private func copyLogs(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = CopyReport()
        for scope in logDiscoveryFailures.prefix(50) {
            report.skippedFiles += 1
            report.note(scope, reason: "discovery unavailable")
        }
        var count = 0, totalBytes = 0
        let sessions = try suppliedSessionNames(report: &report)
        let pinnedLogs = try pinnedLogSource(report: &report)
        if let (source, paths) = pinnedLogs {
            report.entries = min(paths.count, Self.entryLimit)
            report.enumerationStopped = paths.count > Self.entryLimit
            var files = paths.prefix(Self.entryLimit).map { $0.resolved(against: logDirectory) }
            let logsLimit = logByteLimit
            let existingNames = Set(files.map(\.lastPathComponent))
            files += sessions.filter { !existingNames.contains($0) }.map { logDirectory.appendingPathComponent($0) }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let timestamp = ISO8601DateFormatter()
            for file in files.sorted(by: { left, right in
                let l = sessions.contains(left.lastPathComponent), r = sessions.contains(right.lastPathComponent)
                if l != r { return l }
                return logPrecedes(left, right)
            }) {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let name = file.lastPathComponent
                let isSession = sessions.contains(name)
                guard isEventLog(name) || isSession else {
                    report.skippedFiles += 1
                    report.note(name, reason: "not a MacGacha event log")
                    continue
                }
                guard count < Self.logLimit, totalBytes < logsLimit else {
                    report.skippedFiles += 1
                    report.note(name, reason: "export budget")
                    continue
                }
                if isSession {
                    let allowance = min(Self.fileLimit, logsLimit - totalBytes)
                    guard let (output, truncated) = try optionalRead(name, report: &report, body: {
                        self.beforeOptionalOpen(file)
                        let handle = try source.openForReading(at: SafeRelativePath(name))
                        defer { try? handle.close() }
                        return try self.readSessionLog(handle, allowance: allowance)
                    }) else { continue }
                    if truncated { report.truncatedFiles += 1; report.note(name, reason: "truncated for export budget") }
                    try ContainedFileSystem(root: destination).writeAtomically(output, to: SafeRelativePath(name))
                    count += 1; totalBytes += output.count
                    continue
                }
                guard let handle = try optionalRead(name, report: &report, body: {
                    self.beforeEventOpen(file)
                    return try source.openForReading(at: SafeRelativePath(name))
                }) else { continue }
                defer { try? handle.close() }
                count += 1
                let allowance = min(Self.fileLimit, logsLimit - totalBytes)
                guard let complete = try optionalRead(name, report: &report, body: { try self.readCompleteEventLog(handle) }) else { continue }
                let data = safeTail(complete, allowance: allowance)
                var truncated = complete.count > data.count
                var output = Data()
                var invalid = 0
                // Redact complete content before selecting records, including an
                // unexpected sensitive outer wrapper. Then enforce the event schema.
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    if index == lines.count - 1 && line.isEmpty { continue }
                    guard var record = try? decoder.decode(EventLog.Record.self, from: Data(line)),
                          timestamp.date(from: record.ts) != nil else { invalid += 1; continue }
                    // Already sanitized before selection. Foreign/multiline fallback
                    // still needs the event schema's bounded metadata-key policy.
                    if record.metadata.keys.contains(where: { $0.utf8.count > 256 }) {
                        record.metadata = Redactor.redact(metadata: record.metadata)
                    }
                    var encoded = try encoder.encode(record)
                    encoded.append(10)
                    guard encoded.count <= allowance - output.count else {
                        report.budgetRecords += 1
                        truncated = true
                        continue
                    }
                    output.append(encoded)
                }
                report.droppedRecords += invalid
                if invalid > 0 { report.note(name, reason: "\(invalid) invalid records dropped") }
                if truncated {
                    report.truncatedFiles += 1
                    report.note(name, reason: "truncated for export budget")
                }
                totalBytes += output.count
                try output.write(to: destination.appendingPathComponent(name), options: .atomic)
            }
        }
        if pinnedLogs == nil {
            for name in sessions { report.skippedFiles += 1; report.note(name, reason: "missing optional log") }
        }
        try copyGameLogs(to: destination.deletingLastPathComponent().appendingPathComponent("game-logs"), remainingBytes: logByteLimit - totalBytes, remainingFiles: Self.logLimit - count, report: &report)
        let reportData = Data(report.text.utf8)
        guard reportData.count <= Self.reportLimit else { throw LauncherError.io("Diagnostic report exceeds export budget") }
        try reportData.write(to: destination.deletingLastPathComponent().appendingPathComponent("skipped.txt"), options: .atomic)
    }

    private func pinnedLogSource(report: inout CopyReport) throws -> (ContainedFileSystem, [SafeRelativePath])? {
        do {
            try Task.checkCancellation()
            // Anchor traversal at app data, then retain the actual Logs directory.
            // URLs below are labels only: all enumeration and reads use this pin.
            guard let app = try ContainedFileSystem(root: logDirectory.deletingLastPathComponent()).pinRootIfPresent(),
                  let source = try app.pinDirectoryIfPresent(at: SafeRelativePath(logDirectory.lastPathComponent)) else { return nil }
            return (source, try source.contentsOfRootDirectory(maximumEntries: Self.entryLimit + 1))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled {
                throw LauncherError.cancelled
            }
            report.skippedFiles += 1
            report.note("Logs", reason: "unsafe or unavailable log directory")
            return nil
        }
    }

    private func suppliedSessionNames(report: inout CopyReport) throws -> Set<String> {
        guard sessionLogsEnabled else { return [] }
        var result = Set<String>()
        for url in sessionLogURLs {
            if let name = try optionalRead(url.lastPathComponent, report: &report, body: {
                guard url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == self.logDirectory.standardizedFileURL else {
                    throw LauncherError.unsafePath("Session log is outside log directory")
                }
                let path = try SafeRelativePath(url.lastPathComponent)
                guard path.components.count == 1 else { throw LauncherError.unsafePath(path.description) }
                return path.description
            }) { result.insert(name) }
        }
        return result
    }

    private func optionalRead<T>(_ name: String, report: inout CopyReport, body: () throws -> T) throws -> T? {
        do { try Task.checkCancellation(); return try body() }
        catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            if let launcher = error as? LauncherError, case .cancelled = launcher { throw launcher }
            report.skippedFiles += 1
            report.note(name, reason: "missing, unsafe or oversized optional log")
            return nil
        }
    }

    /// Never start redaction in the middle of a record. A larger file is omitted
    /// rather than exporting an untrusted tail without its sensitive-key context.
    /// The bounded full snapshot includes incomplete final records for redaction.
    private func readCompleteLog(_ handle: FileHandle) throws -> Data {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= 64 << 20 else { throw LauncherError.io("Optional log exceeds safe redaction limit") }
        try handle.seek(toOffset: 0)
        var data = Data(), remaining = Int(info.st_size)
        while remaining > 0 {
            try Task.checkCancellation()
            let piece = try autoreleasepool { try handle.read(upToCount: min(65_536, remaining)) ?? Data() }
            guard !piece.isEmpty else { throw LauncherError.io("Optional log changed during read") }
            data.append(piece); remaining -= piece.count
        }
        try Task.checkCancellation()
        return data
    }

    private func redactComplete(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        let safe = autoreleasepool { Data(Redactor.redactLog(String(decoding: data, as: UTF8.self)).utf8) }
        try Task.checkCancellation()
        return safe
    }
    private func readCompleteRedactedLog(_ handle: FileHandle) throws -> Data { try redactComplete(readCompleteLog(handle)) }

    private func readCompleteEventLog(_ handle: FileHandle) throws -> Data {
        let raw = try readCompleteLog(handle)
        // Only after EVERY line validates as a complete event can we rule out
        // sensitive context carried across lines. Multiline/foreign input takes
        // the whole-content redactor instead. No selection happens in either pass.
        if raw.count <= 8 << 20 {
            let decoder = JSONDecoder(), timestamp = ISO8601DateFormatter()
            var records: [EventLog.Record] = []
            var valid = true
            let lines = raw.split(separator: 10, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                try Task.checkCancellation()
                if index == lines.count - 1 && line.isEmpty { continue }
                guard let record = try? decoder.decode(EventLog.Record.self, from: Data(line)), timestamp.date(from: record.ts) != nil else { valid = false; break }
                records.append(record)
            }
            if valid {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var output = Data()
                for var record in records {
                    try Task.checkCancellation()
                    let encoded = try autoreleasepool {
                        record.category = Redactor.redact(record.category)
                        record.message = Redactor.redact(record.message)
                        record.metadata = Redactor.redact(metadata: record.metadata)
                        return try encoder.encode(record)
                    }
                    output.append(encoded); output.append(10)
                }
                return output
            }
        }
        return try redactComplete(raw)
    }

    private func readSessionLog(_ handle: FileHandle, allowance: Int) throws -> (Data, Bool) {
        let safe = try readCompleteRedactedLog(handle)
        guard safe.count > allowance else { return (safe, false) }
        var head = Data(safe.prefix(min(32 << 10, allowance / 2)))
        if head.last != 10 {
            if let end = head.lastIndex(of: 10) { head = Data(head[...end]) } else { head.removeAll() }
        }
        let notice = Data("[session log middle omitted]\n".utf8)
        let marker = notice.count <= allowance - head.count ? notice : Data()
        return (head + marker + safeTail(safe, allowance: max(0, allowance - head.count - marker.count)), true)
    }

    /// Select only after redaction; retained data can no longer lose a secret's key.
    private func safeTail(_ data: Data, allowance: Int) -> Data {
        guard data.count > allowance else { return data }
        guard allowance > 0 else { return Data() }
        let start = data.count - allowance
        if data[start - 1] == 10 { return Data(data[start...]) }
        guard let newline = data[start...].firstIndex(of: 10) else { return Data() }
        return Data(data[data.index(after: newline)...])
    }

    private func copyGameLogs(to destination: URL, remainingBytes: Int, remainingFiles: Int, report: inout CopyReport) throws {
        var remaining = remainingBytes, filesLeft = remainingFiles
        guard sessionLogsEnabled, let gameLogRoot, !gameLogCandidates.isEmpty else { return }
        guard let fs = try optionalRead("game logs", report: &report, body: { try ContainedFileSystem(root: gameLogRoot) }) else { return }
        for game in gameLogCandidates.keys.sorted() {
            guard try optionalRead(game, report: &report, body: { try SafeIdentifier(game) }) != nil else { continue }
            var newest: (path: SafeRelativePath, date: Date)?
            for path in gameLogCandidates[game] ?? [] {
                if let date = try optionalRead(path.components.last!, report: &report, body: {
                    guard try fs.itemType(at: path, allowingLeafSymlink: true) == .regularFile,
                        let date = try fs.modificationDate(at: path) else { throw LauncherError.io("Missing optional game log") }
                    return date
                }), newest == nil || date > newest!.date { newest = (path, date) }
            }
            guard let newest else { continue }
            guard remaining > 0, filesLeft > 0 else { report.skippedFiles += 1; report.note(game, reason: "export budget"); continue }
            let name = game + "-" + newest.path.components.last!
            guard let safe = try optionalRead(name, report: &report, body: {
                self.beforeOptionalOpen(newest.path.resolved(against: gameLogRoot))
                let handle = try fs.openForReading(at: newest.path)
                defer { try? handle.close() }
                return try self.readCompleteRedactedLog(handle)
            }) else { continue }
            var lines = safe.split(separator: 10, omittingEmptySubsequences: false)
            if lines.last?.isEmpty == true { lines.removeLast() }
            var tail = Data(lines.suffix(200).joined(separator: [10])); if !tail.isEmpty { tail.append(10) }
            let bounded = safeTail(tail, allowance: min(1 << 20, remaining))
            try ContainedFileSystem(root: destination).writeAtomically(bounded, to: SafeRelativePath(name))
            remaining -= bounded.count; filesLeft -= 1
            if lines.count > 200 || bounded.count < tail.count { report.truncatedFiles += 1; report.note(name, reason: "last 200 game-log lines") }
        }
    }

}
