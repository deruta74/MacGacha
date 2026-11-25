// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import DownloadEngine

/// Local launch evidence, never inferred from log text or exported in diagnostics.
public struct LaunchConfiguration: Codable, Equatable, Sendable {
    public let gameBuild: String
    public let gameBuildID: String?
    public let bundleID: String
    public let runtimeProfileID: String
    public let runtimeDigest: Digest
    public let componentIDs: [String]
    public let compatibilityComponentIDs: [ComponentKind: String]
    public let recipeVersion: Int
    public let settings: LaunchSettings
    public let gameModeEnabled: Bool?

    public init(gameBuild: String, gameBuildID: String? = nil, bundleID: String, runtimeProfileID: String, runtimeDigest: Digest,
        componentIDs: [String], compatibilityComponentIDs: [ComponentKind: String], recipeVersion: Int, settings: LaunchSettings, gameModeEnabled: Bool? = nil) {
        self.gameBuild = gameBuild; self.gameBuildID = gameBuildID; self.bundleID = bundleID; self.runtimeProfileID = runtimeProfileID
        self.runtimeDigest = runtimeDigest; self.componentIDs = componentIDs.sorted()
        self.compatibilityComponentIDs = compatibilityComponentIDs; self.recipeVersion = recipeVersion; self.settings = settings; self.gameModeEnabled = gameModeEnabled
    }
    init(gameBuild: String, gameBuildID: String? = nil, selection: LaunchRuntimeSelection, recipeVersion: Int, settings: LaunchSettings, requiredComponents: [ComponentKind]? = nil, gameModeEnabled: Bool? = nil) {
        self.init(gameBuild: gameBuild, gameBuildID: gameBuildID, bundleID: selection.bundle.id.rawValue, runtimeProfileID: selection.runtimeProfileID,
            runtimeDigest: selection.bundle.digest, componentIDs: selection.componentIDs,
            compatibilityComponentIDs: selection.compatibilityComponentIDs.filter { requiredComponents?.contains($0.key) ?? true }, recipeVersion: recipeVersion, settings: settings, gameModeEnabled: gameModeEnabled)
    }
    func validate(game: String) throws {
        guard GameDefinition.find(game) != nil, !gameBuild.isEmpty, gameBuild.utf8.count <= 128,
            !gameBuild.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            gameBuildID.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true,
            recipeVersion > 0, runtimeDigest.algorithm == .sha256, componentIDs.count <= 64,
            !componentIDs.isEmpty, Set(componentIDs).count == componentIDs.count,
            compatibilityComponentIDs.count <= 8 else { throw LauncherError.journalCorrupt("Invalid launch history") }
        for id in [bundleID, runtimeProfileID] + componentIDs + Array(compatibilityComponentIDs.values) { _ = try SafeIdentifier(id) }
        try settings.validate(for: game)
    }
}

public struct SuccessfulLaunch: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let endedAt: Date
    public let configuration: LaunchConfiguration
}

public struct LaunchComparison: Equatable, Sendable {
    public enum Change: String, Sendable { case backend, runtime, game, settings }
    public let changes: [Change]
    public init(previous: LaunchConfiguration, current: LaunchConfiguration) {
        var changes: [Change] = []
        if previous.settings.backend != current.settings.backend { changes.append(.backend) }
        if previous.bundleID != current.bundleID || previous.runtimeProfileID != current.runtimeProfileID || previous.runtimeDigest != current.runtimeDigest ||
            previous.componentIDs != current.componentIDs || previous.compatibilityComponentIDs != current.compatibilityComponentIDs { changes.append(.runtime) }
        if previous.gameBuild != current.gameBuild || previous.gameBuildID != current.gameBuildID { changes.append(.game) }
        var prior = previous.settings; prior.backend = current.settings.backend
        if prior != current.settings || (previous.gameModeEnabled != nil && current.gameModeEnabled != nil && previous.gameModeEnabled != current.gameModeEnabled) { changes.append(.settings) }
        self.changes = changes
    }
}

/// Payload-free classification. An arbitrary I/O message is never evidence of a cause.
public enum LaunchFailureReason: String, Sendable, Equatable {
    case unknown, process, busy, rosetta, location, runtime, gameFiles, network
    public static func classify(_ error: any Error) -> Self {
        if let error = error as? LaunchConfigurationError {
            switch error { case .runtimeUnavailable, .previousUnavailable: return .runtime; case .gameFilesMissing: return .gameFiles }
        }
        guard let error = error as? LauncherError else { return .unknown }
        switch error {
        case .processSpawnFailed, .processFailed: return .process
        case .busy: return .busy
        case .rosettaMissing, .rosettaInstallerUnavailable: return .rosetta
        case .installVolumeUnavailable: return .location
        default: return .unknown
        }
    }
}

public enum LaunchConfigurationError: Error, Sendable { case runtimeUnavailable, previousUnavailable, gameFilesMissing }

public struct LaunchDiagnosis: Sendable, Equatable {
    public let reason: LaunchFailureReason
    public let previous: SuccessfulLaunch?
    public let attempted: LaunchConfiguration?
    /// A single-use, in-memory capability, revalidated under the ordinary launch locks.
    public let retryID: UUID?
    public var comparison: LaunchComparison? {
        guard let previous, let attempted else { return nil }
        return LaunchComparison(previous: previous.configuration, current: attempted)
    }
    public init(reason: LaunchFailureReason, previous: SuccessfulLaunch?, attempted: LaunchConfiguration?, retryID: UUID? = nil) {
        self.reason = reason; self.previous = previous; self.attempted = attempted; self.retryID = retryID
    }
}

extension LaunchSession {
    /// Shared with automatic-runtime cleanup: a window or elapsed wall time alone
    /// never establishes that this configuration successfully ran the game.
    func qualifiesSuccessfulLaunch(normal: Bool) -> Bool {
        guard normal, reachedRunning == true, reachedReady == true,
            let seconds = confirmedRunningSeconds else { return false }
        return seconds.isFinite && (120...31_536_000).contains(seconds)
    }
}

/// One bounded baseline per edition, atomically merged under a cross-process lock.
/// Blocking API: callers must use BlockingIO.
public struct LaunchHistoryStore: Sendable {
    private struct State: Codable { var schemaVersion = 1; var games: [String: SuccessfulLaunch] = [:] }
    private static let maxBytes = 1 << 20
    private let paths: AppPaths
    private let log: EventLog?
    private let file = try! SafeRelativePath("LaunchHistory/last-successful.json")
    public init(paths: AppPaths, log: EventLog? = nil) {
        self.paths = paths
        self.log = log
    }

    public func load() throws -> [String: SuccessfulLaunch] {
        try loadState(in: ContainedFileSystem(root: paths.root))?.games ?? [:]
    }

    /// A missing file has no history. A rejected snapshot returns nil so the
    /// writer can log its replacement once, even if display read it repeatedly.
    private func loadState(in fs: ContainedFileSystem) throws -> State? {
        guard try fs.itemType(at: file) != nil else { return State() }
        let bytes: Data
        do {
            bytes = try fs.readFile(at: file, maxBytes: Self.maxBytes)
        } catch LauncherError.fileTooLarge {
            return nil
        } catch LauncherError.io {
            return nil
        }
        guard let state = try? JSONDecoder().decode(State.self, from: bytes),
            state.schemaVersion == 1, state.games.count <= GameDefinition.all.count else { return nil }
        do {
            for (game, value) in state.games {
                try value.configuration.validate(game: game)
                guard value.endedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
            }
        } catch {
            return nil
        }
        return state
    }

    public func recordVerifiedSession(_ session: LaunchSession, normal: Bool) throws {
        guard session.qualifiesSuccessfulLaunch(normal: normal),
            let configuration = session.configuration, let endedAt = session.verifiedEndedAt else { return }
        try configuration.validate(game: session.game)
        guard endedAt.timeIntervalSinceReferenceDate.isFinite else { throw LauncherError.journalCorrupt("Invalid launch history date") }
        let root = try ContainedFileSystem(root: paths.root)
        try root.createRootDurably()
        let fs = try root.pinRoot()
        try fs.createDirectoryDurably(at: SafeRelativePath("LaunchHistory"))
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("LaunchHistory/.lock"))
        defer { withExtendedLifetime(lock) {} }
        let stored = try loadState(in: fs)
        var state = stored ?? State()
        if let previous = state.games[session.game], previous.endedAt > endedAt { return }
        state.games[session.game] = SuccessfulLaunch(sessionID: session.sessionID, endedAt: endedAt, configuration: configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(state)
        guard bytes.count <= Self.maxBytes else { throw LauncherError.journalCorrupt("Launch history exceeds limit") }
        try fs.writeLaunchAtomically(bytes, to: file)
        if stored == nil {
            (log ?? EventLog(directory: paths.logs)).post(.warning, "launch", "Invalid launch history replaced")
        }
    }
}
