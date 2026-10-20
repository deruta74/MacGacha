import Darwin
import Foundation
import LauncherCore

public struct DiagnosticBundle: Sendable {
    private let logDirectory: URL
    private let runner: any ProcessRunner
    private let openLog: @Sendable (URL) -> (fd: Int32, error: Int32)

    public init(logDirectory: URL, runner: any ProcessRunner) {
        self.init(logDirectory: logDirectory, runner: runner, openLog: {
            let fd = open($0.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            let openError = errno
            return (fd, openError)
        })
    }

    init(logDirectory: URL, runner: any ProcessRunner, openLog: @escaping @Sendable (URL) -> (fd: Int32, error: Int32)) {
        self.logDirectory = logDirectory
        self.runner = runner
        self.openLog = openLog
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
        } catch let error as LauncherError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw LauncherError.cancelled
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
        let files = try fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        var totalBytes = 0
        var skipped: [String] = []
        let fileLimit = 10 << 20
        let totalLimit = 50 << 20
        for file in files {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let name = file.lastPathComponent
            guard file.pathExtension == "log" else {
                skipped.append("skipped (not a log): \(name)")
                continue
            }
            guard count < 100, totalBytes < totalLimit else {
                skipped.append("skipped (export budget): \(name)")
                continue
            }
            let (fd, openError) = openLog(file)
            guard fd >= 0 else {
                // Rotation may remove a discovered file before it is opened; never follow symlinks.
                if openError == ENOENT || openError == ELOOP {
                    skipped.append("skipped (missing or symlink): \(name)")
                    continue
                }
                throw LauncherError.io("Cannot open diagnostic log")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw LauncherError.io("Cannot inspect diagnostic log") }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                skipped.append("skipped (not a regular file): \(name)")
                continue
            }
            count += 1
            // Bound the snapshot even if the active log grows while exporting.
            let allowance = min(fileLimit, totalLimit - totalBytes)
            let length = Int(min(info.st_size, Int64(allowance)))
            let offset = UInt64(info.st_size) - UInt64(length)
            var truncated = offset > 0
            var startsAtBoundary = true
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                startsAtBoundary = try handle.read(upToCount: 1)?.first == 10
            } else {
                try handle.seek(toOffset: 0)
            }
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
            var output = Data(Redactor.redactLog(String(decoding: data, as: UTF8.self)).utf8)
            if output.count > allowance {
                // Redaction can expand tiny secrets. Keep only complete lines within the byte budget.
                let prefix = output.prefix(allowance)
                if let newline = prefix.lastIndex(of: 10) { output = Data(prefix[...newline]) }
                else { output.removeAll() }
                truncated = true
            }
            if truncated { skipped.append("truncated (export budget): \(name)") }
            totalBytes += output.count
            try output.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        if !skipped.isEmpty {
            try write(Redactor.redactLog(skipped.joined(separator: "\n") + "\n"),
                to: destination.deletingLastPathComponent().appendingPathComponent("skipped.txt"))
        }
    }
}
