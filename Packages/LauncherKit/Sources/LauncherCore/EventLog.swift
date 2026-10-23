// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import os

/// Writes structured launcher events. Never log raw HTTP bodies, headers, cookies, or full URLs
/// with query strings. Log status codes, hosts, sizes, and LauncherError cases instead;
/// redaction is best-effort defense in depth, not permission to log sensitive inputs.
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

    /// The JSONL schema shared with diagnostic export. Unknown fields are never re-encoded.
    public struct Record: Codable, Sendable {
        public let ts: String
        public let level: Level
        public var category: String
        public var message: String
        public var metadata: [String: String]
    }

    private let directory: URL
    private let maxFileBytes: Int
    private let keepFiles: Int

    public init(directory: URL, maxFileBytes: Int = 5 << 20, keepFiles: Int = 5) {
        self.directory = directory
        self.maxFileBytes = max(128, maxFileBytes) // Leave room for the smallest valid JSONL record.
        self.keepFiles = max(1, keepFiles)
    }

    public func log(_ level: Level, _ category: String, _ message: String, metadata: [String: String] = [:]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let budget = min(maxFileBytes, 5 << 20)
        var boundedMetadata: [String: String] = [:]
        var remaining = budget / 2
        for key in metadata.keys.sorted().prefix(128) where remaining > 0 {
            // Match the original key before truncation can turn "password" into "pass".
            let entry = Redactor.redact(metadata: [key: cappedInput(metadata[key] ?? "")])
            if let (safeKey, value) = entry.first {
                let boundedKey = Redactor.uniqueKey(prefix(safeKey, bytes: min(remaining, 256)), in: boundedMetadata, maxBytes: 256)
                let boundedValue = prefix(value, bytes: min(remaining, 4096))
                boundedMetadata[boundedKey] = boundedValue
                remaining -= min(remaining, boundedKey.utf8.count + boundedValue.utf8.count)
            }
        }
        var record = Record(ts: ISO8601DateFormatter().string(from: Date()), level: level,
            category: prefix(Redactor.redact(cappedInput(category)), bytes: min(budget, 1024)),
            message: prefix(Redactor.redact(cappedInput(message)), bytes: budget), metadata: boundedMetadata)
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
        let logger = Logger(subsystem: "com.lo7ted.macgacha", category: record.category)
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
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return (index, url)
        }.sorted { $0.0 > $1.0 }
        for (index, file) in numbered {
            // unlink refuses directories, including a directory substituted after inspection.
            if index >= keepFiles - 1 {
                guard unlink(file.path) == 0 else { throw LauncherError.io("Cannot remove rotated event log") }
            } else {
                let next = directory.appendingPathComponent("macgacha.\(index + 1).log")
                if isBlockedSlot(next) {
                    guard unlink(file.path) == 0 else { throw LauncherError.io("Cannot remove rotated event log") }
                } else {
                    try fm.moveItem(at: file, to: next)
                }
            }
        }
        let current = directory.appendingPathComponent("macgacha.log")
        let first = directory.appendingPathComponent("macgacha.1.log")
        if keepFiles == 1 || isBlockedSlot(first) {
            // A blocked archive slot may discard old records, never the new active record.
            guard unlink(current.path) == 0 else { throw LauncherError.io("Cannot remove event log") }
        }
        else { try fm.moveItem(at: current, to: first) }
    }

    private func isBlockedSlot(_ file: URL) -> Bool {
        var info = stat()
        if lstat(file.path, &info) == 0 { return info.st_mode & S_IFMT != S_IFREG }
        return errno != ENOENT
    }

    private func cappedInput(_ string: String) -> String {
        let count = string.utf8.count
        return count > 1 << 20 ? "<omitted \(count) bytes>" : string
    }

    private func prefix(_ string: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let utf8 = string.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: bytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        // Back up over UTF-8 continuation bytes; never introduce a replacement scalar.
        while end != utf8.startIndex && end != utf8.endIndex && utf8[end] & 0xc0 == 0x80 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }
}
