// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct PrefixManager: Sendable {
    private let paths: AppPaths
    private let runner: any ProcessRunner
    private static let markerLimit = 16_384

    public init(paths: AppPaths, runner: any ProcessRunner) {
        self.paths = paths
        self.runner = runner
    }

    /// Maps validated identifiers to a prefix without creating any filesystem entries.
    public func prefixURL(game: String, backend: ComponentKind) throws -> URL {
        _ = try ContainedFileSystem(root: paths.root)
        _ = try prefixPath(game: game, backend: backend)
        return paths.prefixes.appendingPathComponent("\(game)-\(backend.rawValue)", isDirectory: true)
    }

    /// Concurrent calls wait cancellably for the same prefix's file lock and recheck its
    /// marker. system.reg alone never establishes readiness. Wine's SHA-256 identifies
    /// the requested binary version even when an executable is replaced at the same path.
    @concurrent
    public func createPrefix(game: String, backend: ComponentKind, wineBinary: URL) async throws -> URL {
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            let prefix = try prefixPath(game: game, backend: backend)
            guard wineBinary.isFileURL, !wineBinary.path.isEmpty,
                  wineBinary.query == nil, wineBinary.fragment == nil else {
                throw LauncherError.unsafePath(wineBinary.path)
            }
            let fs = try ContainedFileSystem(root: paths.root)
            try fs.createDirectory(at: prefix)
            let lock = try await acquireLock(fs: fs, prefix: prefix)
            defer { withExtendedLifetime(lock) {} }
            // Validate every Prefixes ancestor immediately before crossing the process boundary.
            _ = try fs.directoryURL(at: prefix)
            let url = try prefixURL(game: game, backend: backend)
            let marker = try SafeRelativePath("\(prefix)/.macgacha-prefix.json")
            let pending = try SafeRelativePath("\(prefix)/.macgacha-prefix.pending")
            let existing = try readMarker(fs: fs, path: marker, backend: backend)
            let binary = wineBinary.standardizedFileURL
            let identity = try await binaryIdentity(binary, fs: fs)
            if let existing, existing.schemaVersion == PrefixMarker.schema,
               existing.wineBinaryPath == binary.path, existing.wineBinaryIdentity == identity,
               existing.createdAt.timeIntervalSince1970.isFinite {
                return url
            }

            // An obsolete marker cannot certify a prefix modified by a failed new wineboot.
            try fs.removeFile(at: marker)
            try fs.removeFile(at: pending)
            let result = try await runner.run(wineBinary, arguments: ["wineboot", "--init"],
                environment: ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d"],
                currentDirectory: nil)
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard result.exitCode == 0 else {
                throw LauncherError.processFailed(executable: wineBinary.path, exitCode: result.exitCode,
                    stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
            }
            let readiness = PrefixMarker(schemaVersion: PrefixMarker.schema, backend: backend.rawValue,
                wineBinaryPath: binary.path, wineBinaryIdentity: identity, createdAt: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(readiness)
            guard data.count <= Self.markerLimit else { throw LauncherError.io("Prefix marker exceeds size limit") }
            // Never publish before the file is fully durable. A failed/cancelled write or
            // sync leaves only this private pending file, which the next attempt replaces.
            try fs.writeAtomically(data, to: pending)
            try fs.fullSync(at: pending)
            try fs.rename(from: pending, to: marker)
            return url
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func prefixPath(game: String, backend: ComponentKind) throws -> SafeRelativePath {
        let game = try SafeIdentifier(game)
        let backend = try SafeIdentifier(backend.rawValue)
        return try SafeRelativePath("Prefixes/\(game)-\(backend)")
    }

    private func acquireLock(fs: ContainedFileSystem, prefix: SafeRelativePath) async throws -> InstallLock {
        let path = try SafeRelativePath("\(prefix)/.macgacha-prefix.lock")
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            do { return try InstallLock(fs: fs, path: path) }
            catch LauncherError.busy {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func readMarker(fs: ContainedFileSystem, path: SafeRelativePath, backend: ComponentKind) throws -> PrefixMarker? {
        guard let type = try fs.itemType(at: path) else { return nil }
        guard type == .regularFile else { throw LauncherError.unsafePath(path.description) }
        let data: Data
        do { data = try fs.readFile(at: path, maxBytes: Self.markerLimit) }
        catch LauncherError.fileTooLarge { return nil }
        let decoder = JSONDecoder()
        // Honor a different backend even if the rest of its marker is incomplete.
        if let header = try? decoder.decode(BackendHeader.self, from: data), header.backend != backend.rawValue {
            throw LauncherError.io("Prefix backend mismatch")
        }
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PrefixMarker.self, from: data)
    }

    private func binaryIdentity(_ binary: URL, fs: ContainedFileSystem) async throws -> Digest {
        if let relative = try? RuntimeJSONFile.relativePath(binary, root: paths.root) {
            var hasher = StreamingHasher(.sha256)
            try fs.readFile(at: relative) { hasher.update($0) }
            return hasher.finalize()
        }
        return try await FileHasher.digest(of: binary, algorithm: .sha256)
    }
}

private struct BackendHeader: Decodable { let backend: String }
private struct PrefixMarker: Codable {
    static let schema = 1
    let schemaVersion: Int
    let backend: String
    let wineBinaryPath: String
    let wineBinaryIdentity: Digest
    let createdAt: Date
}
