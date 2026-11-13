// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

public struct PlayTimeSummary: Codable, Equatable, Sendable {
    public let totalSeconds: Double
    public let lastSessionSeconds: Double
    /// The running start of the most recent counted session.
    public let lastPlayed: Date
}

public struct PlayTimeBackfillResult: Equatable, Sendable {
    public let sessions: Int
}

/// Local-only, contained cross-process metadata. All I/O must run on BlockingIO.
/// Session IDs and totals publish together, including the one-time backfill marker.
public struct PlayTimeStore: Sendable {
    private struct State: Codable {
        var schemaVersion = 1
        var games: [String: PlayTimeSummary] = [:]
        var backfillDone = false
        var countedSessionIDs: Set<String> = []
    }
    private let paths: AppPaths
    private let fileOps: any FileOps
    private static let file = try! SafeRelativePath("PlayTime/play-time.json")
    private static let maximumBytes = 8 << 20
    /// Unknown-end evidence and legacy backfill are capped at one day.
    public static let recoveryWindowSeconds: Double = 86_400

    public init(paths: AppPaths) { self.init(paths: paths, fileOps: SystemFileOps()) }
    package init(paths: AppPaths, fileOps: any FileOps) { self.paths = paths; self.fileOps = fileOps }

    public func load() throws -> [String: PlayTimeSummary] {
        try read(in: ContainedFileSystem(root: paths.root, fileOps: fileOps)).games
    }

    public func record(sessionID: UUID, game: String, runningSince: Date?, endedAt: Date, recovered: Bool, supervisedSeconds: Double? = nil) throws {
        guard GameDefinition.find(game) != nil else { throw LauncherError.journalCorrupt("Invalid play time game") }
        guard let start = runningSince, let seconds = Self.creditedSeconds(runningSince: start,
            endedAt: endedAt, recovered: recovered, supervisedSeconds: supervisedSeconds) else { return }
        try mutate { state, _ in
            _ = Self.add(id: Self.playID(for: sessionID), game: game, start: start, seconds: seconds, to: &state)
        }
    }

    static func creditedSeconds(runningSince: Date?, endedAt: Date, recovered: Bool, supervisedSeconds: Double?) -> Double? {
        guard let start = runningSince, start.timeIntervalSinceReferenceDate.isFinite,
            endedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        // An unknown end is never evidence of play. Its caller must supply a frozen
        // duration derived from life checkpoints or an owned log's modification time.
        let seconds = supervisedSeconds ?? (recovered ? 0 : endedAt.timeIntervalSince(start))
        guard seconds.isFinite, seconds > 0 else { return nil }
        if recovered { return min(seconds, recoveryWindowSeconds) }
        guard supervisedSeconds != nil || seconds <= recoveryWindowSeconds else { return nil }
        return seconds
    }

    /// Domain separation prevents reuse as another identifier. The random UUID has
    /// enough entropy that the public digest cannot be reversed to the private ID.
    static func playID(for sessionID: UUID) -> String {
        var hasher = StreamingHasher(.sha256)
        hasher.update(Data("MacGacha.play-time.v1:\(sessionID.uuidString)".utf8))
        return hasher.finalize().hex
    }

    /// nil means a previous transaction already completed backfill. Missing,
    /// oversized or unsafe logs complete it with no history, without following links.
    @discardableResult public func backfill() throws -> PlayTimeBackfillResult? {
        try mutate { state, fs in
            guard !state.backfillDone else { return nil }
            let path = try SafeRelativePath("Logs/macgacha.log")
            var data = Data()
            do {
                if try fs.itemType(at: path) != nil { data = try fs.readFile(at: path, maxBytes: 8 << 20) }
            } catch let error as LauncherError {
                switch error {
                case .unsafePath, .fileTooLarge: break
                default: throw error
                }
            }
            let count = PlayTimeBackfill.parse(data) { id, game, start, seconds in
                Self.add(id: id, game: game, start: start, seconds: seconds, to: &state)
            }
            state.backfillDone = true
            return PlayTimeBackfillResult(sessions: count)
        }
    }

    private static func add(id: String, game: String, start: Date, seconds: Double, to state: inout State) -> Bool {
        guard state.countedSessionIDs.insert(id).inserted else { return false }
        let prior = state.games[game]
        let latest = prior.map { start >= $0.lastPlayed } ?? true
        state.games[game] = PlayTimeSummary(totalSeconds: (prior?.totalSeconds ?? 0) + seconds,
            lastSessionSeconds: latest ? seconds : prior!.lastSessionSeconds,
            lastPlayed: latest ? start : prior!.lastPlayed)
        return true
    }

    private func read(in fs: ContainedFileSystem) throws -> State {
        guard try fs.itemType(at: Self.file) != nil else { return State() }
        do {
            var state = try JSONDecoder().decode(State.self, from: fs.readFile(at: Self.file, maxBytes: Self.maximumBytes))
            guard state.schemaVersion == 1, state.games.count <= GameDefinition.all.count,
                state.countedSessionIDs.count <= 100_000,
                state.countedSessionIDs.allSatisfy({ $0.utf8.count <= 160 }) else { throw invalidState() }
            for (game, summary) in state.games {
                guard GameDefinition.find(game) != nil, summary.totalSeconds.isFinite, summary.totalSeconds > 0,
                    summary.lastSessionSeconds.isFinite, summary.lastSessionSeconds > 0,
                    summary.lastSessionSeconds <= summary.totalSeconds,
                    summary.lastPlayed.timeIntervalSinceReferenceDate.isFinite else { throw invalidState() }
            }
            // Migrate existing UUID receipts so old accounting also deduplicates
            // the redaction-safe correlation key without changing totals.
            state.countedSessionIDs = Set(state.countedSessionIDs.map {
                UUID(uuidString: $0).map(Self.playID(for:)) ?? $0
            })
            return state
        } catch { throw invalidState() }
    }

    private func mutate<T>(_ update: (inout State, ContainedFileSystem) throws -> T) throws -> T {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        try fs.createRootDurably()
        try fs.createDirectoryDurably(at: SafeRelativePath("PlayTime"))
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("PlayTime/.play-time.lock"))
        defer { withExtendedLifetime(lock) {} }
        var state = try read(in: fs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let result = try update(&state, fs)
        let bytes = try encoder.encode(state)
        guard bytes.count <= Self.maximumBytes, state.countedSessionIDs.count <= 100_000 else { throw invalidState() }
        // Re-publish even a duplicate to complete a prior uncertain rename/fsync.
        try fs.writeLaunchAtomically(bytes, to: Self.file)
        return result
    }

    private func invalidState() -> LauncherError { .journalCorrupt("Invalid play time metadata") }
}
