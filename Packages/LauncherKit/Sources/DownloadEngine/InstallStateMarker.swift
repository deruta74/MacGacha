// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct InstallStateMarker: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case updating }
    public let state: State
    public let planID: SafeIdentifier

    public init(planID: SafeIdentifier) { state = .updating; self.planID = planID }

    private static func path() throws -> SafeRelativePath { try SafeRelativePath(".macgacha-state.json") }

    public func write(fs: ContainedFileSystem) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try fs.writeAtomically(encoder.encode(self), to: Self.path())
    }

    public static func load(fs: ContainedFileSystem) throws -> Self? {
        let path = try path()
        guard try fs.itemType(at: path) != nil else { return nil }
        let bytes = try fs.readFile(at: path, maxBytes: 65_536)
        do { return try JSONDecoder().decode(Self.self, from: bytes) }
        catch { throw LauncherError.journalCorrupt("Invalid install state marker") }
    }

    /// Launch/verify callers fail closed on any marker, including malformed JSON.
    public static func requireIdle(fs: ContainedFileSystem) throws {
        if try fs.itemType(at: path()) != nil { throw LauncherError.busy("install is updating") }
    }

    /// Clear after completion or a verified pre-commit discard. Refuses another plan's marker.
    public static func clear(fs: ContainedFileSystem, matching planID: SafeIdentifier) throws {
        if let marker = try load(fs: fs), marker.planID != planID {
            throw LauncherError.journalCorrupt("Install state marker belongs to another plan")
        }
        try fs.removeFile(at: path())
    }
}
