import Darwin
import Foundation
import LauncherCore

public enum FailureStage: String, Codable, Sendable {
    case download, verify, stage, commit, cleanup, runtimeInstall, gptkImport, prefixCreation, launch
}

public struct DiagnosticBundle: Sendable {
    private let logDirectory: URL
    private let runner: any ProcessRunner

    public init(logDirectory: URL, runner: any ProcessRunner) {
        self.logDirectory = logDirectory
        self.runner = runner
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
            if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled {
                throw LauncherError.cancelled
            }
            if case LauncherError.processFailed(let executable, let exitCode, let stderr) = error {
                throw LauncherError.processFailed(executable: Redactor.redact(executable), exitCode: exitCode,
                    stderrTail: Redactor.redact(stderr))
            }
            throw LauncherError.io(Redactor.redact(String(describing: error)))
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func copyLogs(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: logDirectory.path) else { return }
        guard let files = fm.enumerator(at: logDirectory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
            throw LauncherError.io("Cannot enumerate diagnostic logs")
        }
        var count = 0
        var totalBytes: Int64 = 0
        for case let file as URL in files {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            count += 1
            guard count <= 100 else { throw LauncherError.io("Too many diagnostic log entries") }
            guard file.pathExtension == "log" else { continue }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                if errno == ELOOP { continue } // Never follow a log symlink out of the selected directory.
                throw LauncherError.io("Cannot open diagnostic log")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw LauncherError.io("Cannot inspect diagnostic log") }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            // Snapshot limits also bound growing logs: 10 MiB per file, 50 MiB per export.
            guard info.st_size >= 0, info.st_size <= 10 << 20, totalBytes <= (50 << 20) - info.st_size else {
                throw LauncherError.io("Diagnostic logs exceed export size limit")
            }
            totalBytes += info.st_size
            var remaining = Int(info.st_size)
            var data = Data()
            while remaining > 0 {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let piece = try autoreleasepool { try handle.read(upToCount: min(65_536, remaining)) ?? Data() }
                guard !piece.isEmpty else { break }
                data.append(piece)
                remaining -= piece.count
            }
            let text = String(decoding: data, as: UTF8.self)
            let sanitized: String
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                // Legacy logs can be one pretty-printed JSON document, rather than JSONL.
                sanitized = Redactor.redact(text)
            } else {
                sanitized = text.components(separatedBy: "\n").map { Redactor.redact($0) }.joined(separator: "\n")
            }
            try write(sanitized, to: destination.appendingPathComponent(file.lastPathComponent))
        }
    }
}
