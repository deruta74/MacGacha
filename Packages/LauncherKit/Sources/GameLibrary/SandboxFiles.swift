// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import Sophon

/// Synchronous contained parsing. Call on the library's IO executor or BlockingIO.
enum SandboxFiles {
    static let maximumListBytes = 8 << 20
    static let maximumConfigBytes = 1 << 20
    static let maximumFiles = 20_000
    static let maximumExpanded: Int64 = 4 << 30
    static let defaultList = try! SafeRelativePath("beyond_pkg_version")
    static let assets = try! SafeRelativePath("BeyondAssets")
    private static let config = try! SafeRelativePath("config.ini")

    static func supportedList(_ path: SafeRelativePath?) -> SafeRelativePath? {
        path == defaultList ? defaultList : nil
    }

    static func validateListPath(_ path: SafeRelativePath) throws {
        guard supportedList(path) != nil else { throw LauncherError.unsafePath("Invalid sandbox list") }
    }

    static func listIsManaged(_ paths: Set<SafeRelativePath>) -> Bool {
        paths.contains { folded($0.components[0]) == defaultList.description }
    }
    static func detect(in fs: ContainedFileSystem, listPath: SafeRelativePath) throws -> SandboxInstallation? {
        try validateListPath(listPath)
        // Presence alone is insufficient: unreadable lists never opt a user in.
        do {
            guard try fs.itemType(at: listPath) == .regularFile else { return nil }
            _ = try fs.readFile(at: listPath, maxBytes: maximumListBytes)
        } catch { if Task.isCancelled { throw LauncherError.cancelled }; return nil }
        var version: String?
        if let data = try? fs.readFile(at: config, maxBytes: maximumConfigBytes), let text = String(data: data, encoding: .utf8) {
            let values = text.split(whereSeparator: { $0.isNewline }).compactMap { line -> String? in
                guard let value = configValue(String(line)), SandboxPackage.isValidVersion(value) else { return nil }
                return value
            }
            if Set(values).count == 1 { version = values.first }
        }
        return try SandboxInstallation(version: version, listPath: listPath)
    }
    static func writeConfigVersion(_ version: String?, in fs: ContainedFileSystem) throws {
        if let data = try configData(setting: version, in: fs) { try fs.writeAtomically(data, to: config) }
    }
    static func configData(setting version: String?, in fs: ContainedFileSystem) throws -> Data? {
        guard try fs.itemType(at: config) != nil else { return nil }
        guard try fs.itemType(at: config) == .regularFile else { throw LauncherError.unsafePath("Invalid game config") }
        let data = try fs.readFile(at: config, maxBytes: maximumConfigBytes)
        guard let text = String(data: data, encoding: .utf8), version.map(SandboxPackage.isValidVersion) ?? true else {
            throw LauncherError.io("Invalid game config")
        }
        // Keep each original line ending, order, whitespace and unrelated byte intact.
        var result = "", found = false
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, bytes) in lines.enumerated() {
            var body = String(decoding: bytes, as: UTF8.self)
            var ending = index == lines.count - 1 ? "" : "\n"
            if body.hasSuffix("\r") { body.removeLast(); ending = "\r" + ending }
            if configValue(body) != nil {
                if let version { result += "wpf_version=" + version + ending }
                found = true
            } else { result += body + ending }
        }
        if let version, !found {
            let ending = text.contains("\r\n") ? "\r\n" : "\n"
            if !result.isEmpty, result.utf8.last != 10 { result += ending }
            result += "wpf_version=" + version + ending
        }
        guard result.utf8.count <= maximumConfigBytes else { throw LauncherError.io("Game config exceeds size limit") }
        return Data(result.utf8)
    }
    private static func configValue(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "="),
            line[..<equals].trimmingCharacters(in: .whitespaces) == "wpf_version" else { return nil }
        return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    struct Entry: Decodable {
        let remoteName: String
        let md5: String
        let fileSize: Int64
    }
    static func verify(in fs: ContainedFileSystem, listPath: SafeRelativePath, mode: Verifier.Mode,
        progress: @Sendable (Int64, Int64) -> Void = { _, _ in }) throws -> Bool {
        try validateListPath(listPath)
        guard try fs.itemType(at: listPath) == .regularFile else { return false }
        let data = try fs.readFile(at: listPath, maxBytes: maximumListBytes)
        let lines = data.split(separator: 10).filter { !$0.allSatisfy { $0 == 13 || $0 == 32 || $0 == 9 } }
        guard !lines.isEmpty, lines.count <= maximumFiles else { throw LauncherError.io("Invalid sandbox list") }
        var paths = Set<String>(), files: [(SafeRelativePath, Digest, Int64)] = [], total: Int64 = 0
        for line in lines {
            guard line.count <= 65536 else { throw LauncherError.io("Invalid sandbox list") }
            let entry: Entry
            do { entry = try JSONDecoder().decode(Entry.self, from: Data(line)) }
            catch { throw LauncherError.io("Invalid sandbox list") }
            let path = try SafeRelativePath(entry.remoteName)
            guard path.components.count > 1, path.components.first == "BeyondAssets", entry.fileSize >= 0,
                entry.fileSize <= maximumExpanded, total <= maximumExpanded - entry.fileSize,
                paths.insert(folded(path.description)).inserted else { throw LauncherError.unsafePath("Invalid sandbox list") }
            guard entry.md5.utf8.count == 32 else { throw LauncherError.io("Invalid sandbox list") }
            let digest = try Digest(algorithm: .md5, hex: entry.md5)
            files.append((path, digest, entry.fileSize)); total += entry.fileSize
        }
        var verified: Int64 = 0
        for (path, digest, size) in files {
            try Task.checkCancellation()
            guard try fs.itemType(at: path) == .regularFile, try fs.size(at: path) == size else { return false }
            if mode == .full {
                var hasher = StreamingHasher(.md5), read: Int64 = 0
                try fs.readFile(at: path) { bytes in
                    read += Int64(bytes.count)
                    guard read <= size else { throw LauncherError.io("Sandbox file changed") }
                    hasher.update(bytes)
                }
                guard read == size, hasher.finalize() == digest else { return false }
            }
            verified += size; progress(verified, total)
        }
        return true
    }
    static func requireGamePlanSafe(_ plan: InstallPlan, game: String) throws {
        guard GameDefinition.all.first(where: { $0.id == game })?.family == .genshin else { return }
        for path in plan.files.map(\.path) + plan.deletions {
            let root = folded(path.components[0])
            guard root != "beyondassets", root != defaultList.description else {
                throw LauncherError.unsafePath("Sandbox files are separately managed")
            }
        }
    }
    static func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
