// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A launch's immutable context. Recovery uses this snapshot, never today's recipe or settings.
public struct LaunchSession: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case preparing, spawning, running, ending, restoring, done, recoveryConflict, recoveryPending
    }
    public let sessionID: UUID
    public let game: String
    public let installRoot: URL
    public let installIdentity: FileSystemIdentity
    public let prefix: URL
    public let bundleID: String
    public let runtimeDigest: Digest
    public let wineBinary: URL
    public let wineserver: URL
    public let componentIDs: [String]
    public let recipeVersion: Int
    public let settings: LaunchSettings
    public var state: State
    public var processes: [ProcessIdentity]
    public var hides: [HideEntry]
    public var proxyPort: UInt16?
    public let createdAt: Date

    public init(sessionID: UUID, game: String, installRoot: URL, installIdentity: FileSystemIdentity, prefix: URL,
        bundleID: String, runtimeDigest: Digest, wineBinary: URL, wineserver: URL, componentIDs: [String],
        recipeVersion: Int, settings: LaunchSettings, state: State = .preparing, processes: [ProcessIdentity] = [],
        hides: [HideEntry] = [], proxyPort: UInt16? = nil, createdAt: Date = Date()) {
        self.sessionID = sessionID; self.game = game; self.installRoot = installRoot; self.installIdentity = installIdentity
        self.prefix = prefix; self.bundleID = bundleID; self.runtimeDigest = runtimeDigest; self.wineBinary = wineBinary
        self.wineserver = wineserver; self.componentIDs = componentIDs; self.recipeVersion = recipeVersion
        self.settings = settings; self.state = state; self.processes = processes; self.hides = hides
        self.proxyPort = proxyPort; self.createdAt = createdAt
    }

    func validate() throws {
        _ = try SafeIdentifier(game); _ = try SafeIdentifier(bundleID)
        for id in componentIDs { _ = try SafeIdentifier(id) }
        for url in [installRoot, prefix, wineBinary, wineserver] {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
                url.host == nil || url.host == "" || url.host == "localhost" else { throw LauncherError.journalCorrupt("Invalid session URL") }
        }
        guard recipeVersion > 0, runtimeDigest.algorithm == .sha256, componentIDs.count <= 64,
            Set(componentIDs).count == componentIDs.count, processes.count <= 1024, hides.count <= 256,
            processes.allSatisfy({ $0.pid > 0 }), createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LauncherError.journalCorrupt("Invalid launch snapshot")
        }
        try settings.validate()
        var originals = Set<String>(), hidden = Set<String>()
        for entry in hides {
            guard entry.size >= 0, entry.sha256.algorithm == .sha256,
                entry.hiddenName == entry.path.components.last! + ".macgacha-hidden-" + sessionID.uuidString,
                !Self.pathKey(entry.path).contains(".macgacha-hidden"),
                originals.insert(Self.pathKey(entry.path)).inserted,
                hidden.insert(Self.pathKey(try hiddenPath(entry))).inserted else {
                throw LauncherError.journalCorrupt("Invalid or duplicate hide entry")
            }
        }
        guard originals.isDisjoint(with: hidden) else { throw LauncherError.journalCorrupt("Overlapping hide entries") }
    }

    func hiddenPath(_ entry: HideEntry) throws -> SafeRelativePath {
        try SafeRelativePath((Array(entry.path.components.dropLast()) + [entry.hiddenName]).joined(separator: "/"))
    }
    static func pathKey(_ path: SafeRelativePath) -> String {
        path.description.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct HideEntry: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case planned, done }
    public let path: SafeRelativePath
    public let hiddenName: String
    public let size: Int64
    public let sha256: Digest
    public var status: Status
    public init(path: SafeRelativePath, hiddenName: String, size: Int64, sha256: Digest, status: Status) {
        self.path = path; self.hiddenName = hiddenName; self.size = size; self.sha256 = sha256; self.status = status
    }
}
