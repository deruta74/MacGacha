import Darwin
import Foundation
import os

public actor EventLog {
    public enum Level: String, Codable, Sendable {
        case debug, info, notice, warning, error, fault

        fileprivate var osType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice, .warning: .default
            case .error: .error
            case .fault: .fault
            }
        }
    }

    private struct Record: Encodable {
        let ts: String
        let level: Level
        var category: String
        var message: String
        var metadata: [String: String]
    }

    private let directory: URL
    private let maxFileBytes: Int
    private let keepFiles: Int

    public init(directory: URL, maxFileBytes: Int = 5 << 20, keepFiles: Int = 5) {
        self.directory = directory
        self.maxFileBytes = max(1, maxFileBytes)
        self.keepFiles = max(1, keepFiles)
    }

    public func log(_ level: Level, _ category: String, _ message: String, metadata: [String: String] = [:]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let budget = min(maxFileBytes, 5 << 20)
        var boundedMetadata: [String: String] = [:]
        var remaining = budget / 2
        for key in metadata.keys.prefix(128).sorted() where remaining > 0 {
            // Match the original key before truncation can turn "password" into "pass".
            let entry = Redactor.redact(metadata: [key: prefix(metadata[key] ?? "", bytes: min(remaining, 4096))])
            if let (safeKey, value) = entry.first {
                let boundedKey = prefix(safeKey, bytes: min(remaining, 1024))
                boundedMetadata[boundedKey] = value
                remaining -= min(remaining, boundedKey.utf8.count + value.utf8.count)
            }
        }
        var record = Record(ts: ISO8601DateFormatter().string(from: Date()), level: level,
            category: Redactor.redact(prefix(category, bytes: min(budget, 1024))),
            message: Redactor.redact(prefix(message, bytes: budget)), metadata: boundedMetadata)
        guard var data = try? encoder.encode(record) else { return }
        if data.count >= budget {
            record.metadata = [:]
            while data.count >= budget {
                if !record.message.isEmpty { record.message = prefix(record.message, bytes: record.message.utf8.count / 2) }
                else if !record.category.isEmpty { record.category = prefix(record.category, bytes: record.category.utf8.count / 2) }
                else { return } // A valid JSON record cannot fit in this caller-supplied limit.
                guard let encoded = try? encoder.encode(record) else { return }
                data = encoded
            }
        }
        data.append(10)
        let logger = Logger(subsystem: "com.deruta.macgacha", category: record.category)
        logger.log(level: level.osType, "\(String(decoding: data, as: UTF8.self), privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("macgacha.log")
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw LauncherError.io("Cannot open event log") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw LauncherError.io("Event log is not a regular file")
            }
            if info.st_size > Int64(maxFileBytes - data.count) {
                try handle.close()
                try rotate()
                let replacementFD = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
                guard replacementFD >= 0 else { throw LauncherError.io("Cannot open rotated event log") }
                let replacement = FileHandle(fileDescriptor: replacementFD, closeOnDealloc: true)
                defer { try? replacement.close() }
                try replacement.write(contentsOf: data)
            } else {
                try handle.write(contentsOf: data)
            }
        } catch {
            logger.error("\(Redactor.redact(error.localizedDescription), privacy: .public)")
        }
    }

    private func rotate() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let numbered = files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("macgacha."), name.hasSuffix(".log"),
                  let index = Int(name.dropFirst(9).dropLast(4)), index > 0,
                  name == "macgacha.\(index).log" else { return nil }
            return (index, url)
        }.sorted { $0.0 > $1.0 }
        for (index, file) in numbered {
            // unlink refuses directories, including a directory substituted after inspection.
            if index >= keepFiles - 1 {
                guard unlink(file.path) == 0 else { throw LauncherError.io("Cannot remove rotated event log") }
            }
            else { try fm.moveItem(at: file, to: directory.appendingPathComponent("macgacha.\(index + 1).log")) }
        }
        let current = directory.appendingPathComponent("macgacha.log")
        if keepFiles == 1 {
            guard unlink(current.path) == 0 else { throw LauncherError.io("Cannot remove event log") }
        }
        else { try fm.moveItem(at: current, to: directory.appendingPathComponent("macgacha.1.log")) }
    }

    private func prefix(_ string: String, bytes: Int) -> String {
        String(decoding: string.utf8.prefix(bytes), as: UTF8.self)
    }
}
