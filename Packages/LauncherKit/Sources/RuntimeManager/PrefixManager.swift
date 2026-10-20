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
    /// Ready prefixes upgrade in place when Wine changes; only incomplete prefixes reset.
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
            let lock = try await acquireLock(fs: fs, prefix: prefix)
            defer { withExtendedLifetime(lock) {} }
            try fs.createDirectory(at: prefix)
            // Validate every Prefixes ancestor immediately before crossing the process boundary.
            _ = try fs.directoryURL(at: prefix)
            let url = try prefixURL(game: game, backend: backend)
            let marker = try SafeRelativePath("\(prefix)/.macgacha-prefix.json")
            let pending = try SafeRelativePath("\(prefix)/.macgacha-prefix.pending")
            let existing = try readMarker(fs: fs, path: marker, game: game, backend: backend)
            let binary = wineBinary.standardizedFileURL
            let identity = try await binaryIdentity(binary, fs: fs)
            if let existing, existing.state == .ready,
               existing.wineBinaryPath == binary.path, existing.wineBinaryIdentity == identity {
                return url
            }

            let arguments: [String]
            if let existing {
                // Persist uncertainty before Wine can modify the initialized tree.
                // Failed/cancelled upgrades remain upgrading for every runtime request.
                let upgrading = PrefixMarker(schemaVersion: PrefixMarker.schema, game: game, backend: backend.rawValue,
                    state: .upgrading, wineBinaryPath: binary.path, wineBinaryIdentity: identity, createdAt: existing.createdAt)
                try writeMarker(upgrading, fs: fs, to: marker, pending: pending)
                arguments = ["wineboot", "-u"]
            } else {
                // Wine writes by path, so an incomplete prefix must not retain links
                // that could redirect initialization outside it. Contained removal
                // unlinks links themselves; the sibling lock survives the reset.
                try fs.removeItem(at: prefix)
                try fs.createDirectory(at: prefix)
                try fs.synchronizeTree(at: prefix)
                arguments = ["wineboot", "--init"]
            }
            let result = try await runner.run(wineBinary, arguments: arguments,
                environment: ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d"],
                currentDirectory: nil)
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard result.exitCode == 0 else {
                throw LauncherError.processFailed(executable: wineBinary.path, exitCode: result.exitCode,
                    stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
            }
            let readiness = PrefixMarker(schemaVersion: PrefixMarker.schema, game: game, backend: backend.rawValue,
                state: .ready, wineBinaryPath: binary.path, wineBinaryIdentity: identity, createdAt: existing?.createdAt ?? Date())
            try writeMarker(readiness, fs: fs, to: marker, pending: pending)
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
        let path = try SafeRelativePath("Prefixes/.macgacha-prefix-\(prefix.components.last!).lock")
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            do { return try InstallLock(fs: fs, path: path) }
            catch LauncherError.busy {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func writeMarker(_ value: PrefixMarker, fs: ContainedFileSystem, to path: SafeRelativePath,
        pending: SafeRelativePath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= Self.markerLimit else { throw LauncherError.io("Prefix marker exceeds size limit") }
        // Both upgrading and ready must be fully durable before publication. Failure
        // before rename leaves the prior marker and only a private pending file.
        try fs.writeAtomically(data, to: pending)
        try fs.fullSync(at: pending)
        try fs.rename(from: pending, to: path)
    }

    private func readMarker(fs: ContainedFileSystem, path: SafeRelativePath, game: String, backend: ComponentKind) throws -> PrefixMarker? {
        guard try fs.itemType(at: path, allowingLeafSymlink: true) == .regularFile else { return nil }
        let data: Data
        do { data = try fs.readFile(at: path, maxBytes: Self.markerLimit) }
        catch LauncherError.cancelled { throw LauncherError.cancelled }
        catch { return nil }
        let decoder = JSONDecoder()
        // Honor a different backend even if the rest of its marker is incomplete.
        if let header = try? decoder.decode(BackendHeader.self, from: data), header.backend != backend.rawValue {
            throw LauncherError.io("Prefix backend mismatch")
        }
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(PrefixMarker.self, from: data),
              marker.schemaVersion == PrefixMarker.schema, marker.createdAt.timeIntervalSince1970.isFinite else { return nil }
        if let storedGame = marker.game, storedGame != game { throw LauncherError.io("Prefix game mismatch") }
        return marker
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
    enum State: String, Codable { case ready, upgrading }
    static let schema = 1
    let schemaVersion: Int
    let game: String?
    let backend: String
    let state: State
    let wineBinaryPath: String
    let wineBinaryIdentity: Digest
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion, game, backend, state, wineBinaryPath, wineBinaryIdentity, createdAt
    }
}

private extension PrefixMarker {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        game = try container.decodeIfPresent(String.self, forKey: .game)
        backend = try container.decode(String.self, forKey: .backend)
        // Original schema-1 markers have no state or game field. Their game is
        // identified by the containing directory, and they certify a ready prefix.
        state = container.contains(.state) ? try container.decode(State.self, forKey: .state) : .ready
        wineBinaryPath = try container.decode(String.self, forKey: .wineBinaryPath)
        wineBinaryIdentity = try container.decode(Digest.self, forKey: .wineBinaryIdentity)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
