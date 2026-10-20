import Darwin
import Foundation
import LauncherCore

public struct DiagnosticBundle: Sendable {
    private let logDirectory: URL
    private let runner: any ProcessRunner
    private let openLog: @Sendable (URL) -> (fd: Int32, error: Int32)
    private let logByteLimit: Int

    public init(logDirectory: URL, runner: any ProcessRunner) {
        self.init(logDirectory: logDirectory, runner: runner, openLog: {
            let fd = open($0.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            let openError = errno
            return (fd, openError)
        })
    }

    init(logDirectory: URL, runner: any ProcessRunner, openLog: @escaping @Sendable (URL) -> (fd: Int32, error: Int32),
        logByteLimit: Int? = nil) {
        self.logDirectory = logDirectory
        self.runner = runner
        self.openLog = openLog
        let maximum = Self.totalLimit - Self.reportLimit
        self.logByteLimit = min(maximum, max(0, logByteLimit ?? maximum))
    }

    @concurrent public func export(to zipURL: URL, systemInfo: SystemInfo, runtimes: [String: String],
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
            case .fileTooLarge(let path, let limit):
                throw LauncherError.fileTooLarge(path: Redactor.redact(path), limit: limit)
            case .consentRequired(let component): throw LauncherError.consentRequired(Redactor.redact(component))
            case .processFailed(let executable, let code, let stderr):
                throw LauncherError.processFailed(executable: Redactor.redact(executable), exitCode: code,
                    stderrTail: Redactor.redact(stderr))
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
            let safeName = Redactor.redact(name)
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
        if fm.fileExists(atPath: logDirectory.path) {
            guard let enumerator = fm.enumerator(at: logDirectory, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]) else { throw LauncherError.io("Cannot enumerate diagnostic logs") }
            var files: [URL] = []
            while report.entries < Self.entryLimit, let file = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                files.append(file)
                report.entries += 1
            }
            report.enumerationStopped = report.entries == Self.entryLimit && enumerator.nextObject() != nil
            var count = 0
            var totalBytes = 0
            let logsLimit = logByteLimit
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let timestamp = ISO8601DateFormatter()
            for file in files.sorted(by: logPrecedes) {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let name = file.lastPathComponent
                guard isEventLog(name) else {
                    report.skippedFiles += 1
                    report.note(name, reason: "not a MacGacha event log")
                    continue
                }
                guard count < Self.logLimit, totalBytes < logsLimit else {
                    report.skippedFiles += 1
                    report.note(name, reason: "export budget")
                    continue
                }
                let (fd, openError) = openLog(file)
                guard fd >= 0 else {
                    if openError == ENOENT || openError == ELOOP {
                        report.skippedFiles += 1
                        report.note(name, reason: "missing or symlink")
                        continue
                    }
                    throw LauncherError.io("Cannot open diagnostic log")
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw LauncherError.io("Cannot inspect diagnostic log") }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                    report.skippedFiles += 1
                    report.note(name, reason: "not a regular file")
                    continue
                }
                count += 1
                let allowance = min(Self.fileLimit, logsLimit - totalBytes)
                let (data, tailTruncated) = try readTail(handle, size: info.st_size, allowance: allowance)
                var truncated = tailTruncated
                var output = Data()
                var invalid = 0
                // Each retained line is decoded independently; a discarded prefix cannot supply a key
                // for a value in the retained tail. Unknown fields are dropped by the shared schema.
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    guard !Task.isCancelled else { throw LauncherError.cancelled }
                    if index == lines.count - 1 && line.isEmpty { continue }
                    guard var record = try? decoder.decode(EventLog.Record.self, from: Data(line)),
                          timestamp.date(from: record.ts) != nil else { invalid += 1; continue }
                    record.category = Redactor.redact(record.category)
                    record.message = Redactor.redact(record.message)
                    record.metadata = Redactor.redact(metadata: record.metadata)
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
        let reportData = Data(report.text.utf8)
        guard reportData.count <= Self.reportLimit else { throw LauncherError.io("Diagnostic report exceeds export budget") }
        try reportData.write(to: destination.deletingLastPathComponent().appendingPathComponent("skipped.txt"), options: .atomic)
    }

    private func readTail(_ handle: FileHandle, size: Int64, allowance: Int) throws -> (Data, Bool) {
        let length = Int(min(size, Int64(allowance)))
        let offset = UInt64(size) - UInt64(length)
        var startsAtBoundary = true
        if offset > 0 {
            try handle.seek(toOffset: offset - 1)
            startsAtBoundary = try handle.read(upToCount: 1)?.first == 10
        } else { try handle.seek(toOffset: 0) }
        var remaining = length
        var data = Data()
        while remaining > 0 {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let piece = try autoreleasepool { try handle.read(upToCount: min(65_536, remaining)) ?? Data() }
            guard !piece.isEmpty else { break }
            data.append(piece)
            remaining -= piece.count
        }
        if !startsAtBoundary {
            if let newline = data.firstIndex(of: 10) { data = Data(data[data.index(after: newline)...]) }
            else { data.removeAll() }
        }
        return (data, offset > 0)
    }
}
