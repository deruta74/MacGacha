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
    public init(paths: AppPaths) { self.init(paths: paths, fileOps: SystemFileOps()) }
    package init(paths: AppPaths, fileOps: any FileOps) { self.paths = paths; self.fileOps = fileOps }
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
            guard let s = try read(game: game) else { return }
            guard s.hides.isEmpty, s.state == .done || s.state == .recoveryConflict else {
                throw LauncherError.busy("Launch recovery is not resolved")
            }
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
        try fs.writeAtomically(data, to: path)
    }
    func withOwnership<T>(_ body: (ContainedFileSystem) throws -> T) throws -> T {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        try fs.createRootDurably(); try fs.createDirectoryDurably(at: SafeRelativePath("Games"))
        let games = try ContainedFileSystem(root: paths.games, fileOps: fileOps)
        let lease = try GameOperationLease.acquire(fs: games)
        defer { withExtendedLifetime(lease) {} }
        return try body(fs)
    }
}
