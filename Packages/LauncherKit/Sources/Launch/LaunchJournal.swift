// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary

/// Synchronous durable metadata I/O: async callers must use BlockingIO.run.
public struct LaunchJournal: Sendable {
    private static let maximumBytes = 1 << 20
    let paths: AppPaths
    let fileOps: any FileOps
    private let sessionOwned: Bool
    private let beforeRead: @Sendable () throws -> Void
    public init(paths: AppPaths) { self.init(paths: paths, fileOps: SystemFileOps()) }
    /// Only the launch manager may opt out of the global operation lease, while
    /// retaining this game's SessionLock until restoration is finished.
    package init(paths: AppPaths, sessionOwned: Bool) {
        self.init(paths: paths, fileOps: SystemFileOps(), sessionOwned: sessionOwned)
    }
    package init(paths: AppPaths, fileOps: any FileOps, sessionOwned: Bool = false, beforeRead: @escaping @Sendable () throws -> Void = {}) {
        self.paths = paths; self.fileOps = fileOps; self.sessionOwned = sessionOwned; self.beforeRead = beforeRead
    }
    public func write(_ s: LaunchSession) throws {
        try s.validate()
        let data = try encode(s)
        try withOwnership { fs in
            if let prior = try read(game: s.game), prior.sessionID != s.sessionID {
                throw LauncherError.busy("An unfinished launch session exists")
            }
            try writeMetadata(data, to: relative(s.game, "launch-session.json"), in: fs)
        }
    }
    public func read(game: String) throws -> LaunchSession? {
        try beforeRead()
        guard let data = try readData(at: relative(game, "launch-session.json")) else { return nil }
        do {
            let session = try JSONDecoder().decode(LaunchSession.self, from: data)
            try session.validate()
            guard session.game == game else { throw LauncherError.journalCorrupt("Launch game does not match directory") }
            return session
        } catch { throw LauncherError.journalCorrupt("Invalid launch session") }
    }
    public func delete(game: String) throws {
        try withOwnership { fs in
            if let s = try read(game: game) {
                guard s.hides.isEmpty, s.state == .done || s.state == .recoveryConflict else {
                    throw LauncherError.busy("Launch recovery is not resolved")
                }
            }
            // removeFile also syncs the parent when the leaf is absent: a prior
            // unlink may have succeeded before its directory fsync failed.
            try fs.removeFile(at: relative(game, "launch-session.json"))
        }
    }

    func relative(_ game: String, _ leaf: String) throws -> SafeRelativePath {
        try SafeRelativePath("Games/\(SafeIdentifier(game).rawValue)/\(leaf)")
    }
    func readData(at path: SafeRelativePath) throws -> Data? {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        guard try fs.itemType(at: path) != nil else { return nil }
        return try fs.readFile(at: path, maxBytes: Self.maximumBytes)
    }
    func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw LauncherError.journalCorrupt("Launch metadata exceeds size limit") }
        return data
    }
    func writeMetadata(_ data: Data, to path: SafeRelativePath, in fs: ContainedFileSystem) throws {
        try fs.createDirectoryDurably(at: SafeRelativePath(path.components.dropLast().joined(separator: "/")))
        if sessionOwned { try fs.writeLaunchAtomically(data, to: path) }
        else { try fs.writeAtomically(data, to: path) }
    }
    func withOwnership<T>(_ body: (ContainedFileSystem) throws -> T) throws -> T {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        try fs.createRootDurably(); try fs.createDirectoryDurably(at: SafeRelativePath("Games"))
        if sessionOwned { return try body(fs) }
        let games = try ContainedFileSystem(root: paths.games, fileOps: fileOps)
        let lease = try GameOperationLease.acquire(fs: games)
        defer { withExtendedLifetime(lease) {} }
        return try body(fs)
    }
}
