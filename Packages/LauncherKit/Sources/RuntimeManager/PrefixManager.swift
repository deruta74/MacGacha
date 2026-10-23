// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct PrefixManager: Sendable {
    private let paths: AppPaths
    private let runner: any ProcessRunner
    static let markerLimit = 16_384

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
    public func createPrefix(game: String, backend: ComponentKind, wineBinary: URL) async throws -> URL {
        try await BlockingIO.run {
            try await createOnIO(game: game, identifier: backend.rawValue, wineBinary: wineBinary, runtimeDigest: nil)
        }
    }

    public func prefixURL(game: String, bundle: SafeIdentifier) throws -> URL {
        _ = try SafeIdentifier(game)
        return paths.prefixes.appendingPathComponent("\(game)-\(bundle)", isDirectory: true)
    }

    public func createPrefix(game: String, bundle: InstalledRuntimeBundle) async throws -> URL {
        try await BlockingIO.run {
            try await createOnIO(game: game, identifier: bundle.id.rawValue, wineBinary: bundle.wineBinary, runtimeDigest: bundle.digest)
        }
    }

    private func createOnIO(game: String, identifier: String, wineBinary: URL, runtimeDigest: Digest?) async throws -> URL {
        do {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            _ = try SafeIdentifier(game); _ = try SafeIdentifier(identifier)
            let prefix = try SafeRelativePath("Prefixes/\(game)-\(identifier)")
            guard wineBinary.isFileURL, !wineBinary.path.isEmpty,
                  wineBinary.query == nil, wineBinary.fragment == nil else {
                throw LauncherError.unsafePath(wineBinary.path)
            }
            let fs = try ContainedFileSystem(root: paths.root)
            let lock = try await Self.acquireLock(fs: fs, prefix: prefix)
            defer { withExtendedLifetime(lock) {} }
            try fs.createDirectory(at: prefix)
            // Validate every Prefixes ancestor immediately before crossing the process boundary.
            _ = try fs.directoryURL(at: prefix)
            let url = prefix.resolved(against: paths.root)
            let marker = try SafeRelativePath("\(prefix)/.macgacha-prefix.json")
            let pending = try SafeRelativePath("\(prefix)/.macgacha-prefix.pending")
            let existing = try readMarker(fs: fs, path: marker, game: game, identifier: identifier)
            let binary = wineBinary.standardizedFileURL
            let identity = try await binaryIdentity(binary, fs: fs)
            if let existing, existing.state == .ready,
               existing.wineBinaryPath == binary.path, existing.wineBinaryIdentity == identity, existing.runtimeDigest == runtimeDigest {
                return url
            }

            let arguments: [String]
            if let existing {
                // Persist uncertainty before Wine can modify the initialized tree.
                // Failed/cancelled upgrades remain upgrading for every runtime request.
                let upgrading = PrefixMarker(schemaVersion: PrefixMarker.schema, game: game, backend: identifier,
                    state: .upgrading, wineBinaryPath: binary.path, wineBinaryIdentity: identity, createdAt: existing.createdAt, bundleID: runtimeDigest == nil ? nil : identifier, runtimeDigest: runtimeDigest)
                try Self.writeMarker(upgrading, fs: fs, to: marker, pending: pending)
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
            let environment = ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": runtimeDigest == nil ? "winemenubuilder.exe=d" : "winemenubuilder.exe=d;mscoree=d;mshtml=d"]
            let result = try await runner.run(wineBinary, arguments: arguments,
                environment: environment,
                currentDirectory: nil)
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            guard result.exitCode == 0 else {
                throw LauncherError.processFailed(executable: wineBinary.path, exitCode: result.exitCode,
                    stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
            }
            if runtimeDigest != nil {
                let config = try await runner.run(wineBinary, arguments: ["winecfg", "-v", "win10"], environment: environment, currentDirectory: nil)
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                guard config.exitCode == 0 else {
                    throw LauncherError.processFailed(executable: wineBinary.path, exitCode: config.exitCode,
                        stderrTail: String(decoding: config.stderr.suffix(4096), as: UTF8.self))
                }
            }
            let readiness = PrefixMarker(schemaVersion: PrefixMarker.schema, game: game, backend: identifier,
                state: .ready, wineBinaryPath: binary.path, wineBinaryIdentity: identity, createdAt: existing?.createdAt ?? Date(), bundleID: runtimeDigest == nil ? nil : identifier, runtimeDigest: runtimeDigest)
            try Self.writeMarker(readiness, fs: fs, to: marker, pending: pending)
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

    static func acquireLock(fs: ContainedFileSystem, prefix: SafeRelativePath) async throws -> InstallLock {
        let path = try SafeRelativePath("Prefixes/.macgacha-prefix-\(prefix.components.last!).lock")
        while true {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            do { return try InstallLock(fs: fs, path: path) }
            catch LauncherError.busy {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    static func writeMarker(_ value: PrefixMarker, fs: ContainedFileSystem, to path: SafeRelativePath,
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

    private func readMarker(fs: ContainedFileSystem, path: SafeRelativePath, game: String, identifier: String) throws -> PrefixMarker? {
        guard try fs.itemType(at: path, allowingLeafSymlink: true) == .regularFile else { return nil }
        let data: Data
        do { data = try fs.readFile(at: path, maxBytes: Self.markerLimit) }
        catch LauncherError.cancelled { throw LauncherError.cancelled }
        catch { return nil }
        let decoder = JSONDecoder()
        // Honor a different backend even if the rest of its marker is incomplete.
        if let header = try? decoder.decode(BackendHeader.self, from: data), header.backend != identifier {
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
struct PrefixMarker: Codable {
    enum State: String, Codable { case ready, upgrading }
    static let schema = 1
    let schemaVersion: Int
    let game: String?
    let backend: String
    let state: State
    let wineBinaryPath: String
    let wineBinaryIdentity: Digest
    let createdAt: Date
    let bundleID: String?
    let runtimeDigest: Digest?
    var provisioningRevision: Int? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion, game, backend, state, wineBinaryPath, wineBinaryIdentity, createdAt, bundleID, runtimeDigest, provisioningRevision
    }
}

extension PrefixMarker {
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
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        runtimeDigest = try container.decodeIfPresent(Digest.self, forKey: .runtimeDigest)
        provisioningRevision = try container.decodeIfPresent(Int.self, forKey: .provisioningRevision)
    }
}
