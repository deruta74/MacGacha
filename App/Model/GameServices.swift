// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine
import Sophon
import GameLibrary

typealias GameEventStream = AsyncThrowingStream<OperationEvent, any Error>

protocol GameServices: Sendable {
    func start() async
    func waitUntilIdle(_ id: String) async throws
    func status(_ id: String) async -> GameStatus
    func checkForUpdate(_ id: String) async throws -> GameStatus
    func record(_ id: String) async throws -> GameRecord?
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream
    func update(_ id: String, approved: Bool) async -> GameEventStream
    func resume(_ id: String, approved: Bool) async -> GameEventStream
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream
    func uninstall(_ id: String) async throws
}

/// Construction does no filesystem work. All core work runs on service/core
/// executors, and API requests and chunk transfers share one host-policy client per region.
final class LiveGameServices: GameServices, Sendable {
    private let libraries: [Region: GameLibrary]
    private let store: GameRecordStore
    private let log: EventLog
    private let sessions: [Region: DeliveryHTTPSession]

    init(paths: AppPaths = .standard(), http: (any HTTPClient)? = nil,
        disk: any DiskSpaceProbe = SystemDiskSpaceProbe(), retry: RetryPolicy = RetryPolicy(),
        sleeper: any Sleeper = ContinuousSleeper(), log: EventLog? = nil,
        guard operationGuard: (any GameOperationGuard)? = nil) {
        let store = GameRecordStore(directory: paths.games), eventLog = log ?? EventLog(directory: paths.logs)
        self.store = store; self.log = eventLog
        var libraries: [Region: GameLibrary] = [:], sessions: [Region: DeliveryHTTPSession] = [:]
        for region in Region.allCases {
            let client: any HTTPClient
            if let http { client = http }
            else { let owned = DeliveryHTTPSession(region: region); sessions[region] = owned; client = owned.client }
            let fetcher = ChunkFetcher(http: client, retry: retry, sleeper: sleeper)
            libraries[region] = GameLibrary(paths: paths, api: DeliveryAPI(http: client, region: region),
                runner: OperationRunner(store: store, fetcher: fetcher, disk: disk, log: eventLog),
                store: store, disk: disk, log: eventLog, guard: operationGuard)
        }
        self.libraries = libraries; self.sessions = sessions
    }
    private func library(for game: GameDefinition) -> GameLibrary { libraries[game.region]! }

    func start() async { await libraries[.global]!.start() }
    func waitUntilIdle(_ id: String) async throws {
        let game = try Self.requireGame(id)
        try await library(for: game).waitUntilIdle(id)
    }
    func status(_ id: String) async -> GameStatus {
        guard let game = Self.game(id) else { return .unknown }
        return await library(for: game).status(game)
    }
    func checkForUpdate(_ id: String) async throws -> GameStatus {
        let game = try Self.requireGame(id)
        log.post(.info, "game", "Game update check started", metadata: ["game": game.id])
        do {
            let status = try await library(for: game).checkForUpdate(game)
            let result: String
            switch status {
            case .installed: result = "upToDate"
            case .updateAvailable: result = "updateAvailable"
            default: result = "unavailable"
            }
            log.post(.info, "game", "Game update check finished", metadata: ["game": game.id, "result": result])
            return status
        } catch {
            let error = launcherError(error)
            // Error payloads can contain paths; log only the stable case name.
            var fields = RuntimeErrorLog(error).metadata
            fields["game"] = game.id; fields["result"] = "failed"
            log.post(.warning, "game", "Game update check finished", metadata: fields)
            throw error
        }
    }
    func record(_ id: String) async throws -> GameRecord? {
        do { _ = try Self.requireGame(id); return try await store.load(id) }
        catch { throw await failure(error, id: id) }
    }
    @concurrent func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        do { let game = try Self.requireGame(id)
            return try await library(for: game).estimate(game, voices: voices, at: location) }
        catch { throw await failure(error, id: id) }
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).install(game, voices: voices, at: location, approved: approved), id: id)
    }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).adopt(game, folder: folder, voices: voices), id: id)
    }
    func update(_ id: String, approved: Bool) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).update(game, approved: approved), id: id)
    }
    func resume(_ id: String, approved: Bool) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).resume(game, approved: approved), id: id)
    }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).verify(game, mode: mode), id: id)
    }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream {
        guard let game = Self.game(id) else { return logged(invalidGame(), id: id) }
        return logged(await library(for: game).setVoices(game, voices), id: id)
    }
    func uninstall(_ id: String) async throws {
        do { let game = try Self.requireGame(id); try await library(for: game).uninstall(game) }
        catch { throw await failure(error, id: id) }
    }
    private static func game(_ id: String) -> GameDefinition? { GameDefinition.all.first { $0.id == id } }
    private static func requireGame(_ id: String) throws -> GameDefinition {
        guard let game = game(id) else { throw LauncherError.io("Unknown game") }
        return game
    }
    private func invalidGame() -> GameEventStream { GameEventStream { $0.finish(throwing: LauncherError.io("Unknown game")) } }
    private func logged(_ source: GameEventStream, id: String) -> GameEventStream {
        let pull = LoggedGameOperation(source: source, id: Self.game(id)?.id ?? "unknown", log: log, session: Self.game(id).flatMap { sessions[$0.region] })
        return GameEventStream(unfolding: { try await pull.next() })
    }
    private func failure(_ error: any Error, id: String) async -> LauncherError {
        let error = launcherError(error)
        await logGameFailure(error, id: Self.game(id)?.id ?? "unknown", log: log)
        return error
    }
}

private final class DeliveryHTTPSession: Sendable {
    let client: URLSessionHTTPClient
    init(region: Region) { client = DeliveryHostPolicy.makeHTTPClient(region: region) }
    deinit { client.invalidate() }
}
private func logGameFailure(_ error: LauncherError, id: String, log: EventLog) async {
    var fields = RuntimeErrorLog(error).metadata
    fields["game"] = id
    await log.log(error == .cancelled ? .info : .error, "game", error == .cancelled ? "Game operation paused" : "Game operation failed", metadata: fields)
}
private actor LoggedGameOperation {
    private var iterator: GameEventStream.Iterator?
    private let id: String, log: EventLog
    private let session: DeliveryHTTPSession?
    private var pulling = false, approval = false
    init(source: GameEventStream, id: String, log: EventLog, session: DeliveryHTTPSession?) {
        iterator = source.makeAsyncIterator(); self.id = id; self.log = log; self.session = session
    }
    func next() async throws -> OperationEvent? {
        guard !pulling else { throw LauncherError.busy("Game stream already in use") }
        pulling = true; defer { pulling = false }
        guard var active = iterator else { return nil }
        iterator = nil
        do {
            let event = try await active.next(isolation: self)
            iterator = active
            switch event {
            case .needsBatchApproval: approval = true
            case .failed(let error): throw error
            case .phase(.cancelled): throw LauncherError.cancelled
            case .phase(.failed): throw LauncherError.io("Game operation failed")
            case .phase(.completed), nil: iterator = nil
            default: break
            }
            return event
        } catch {
            iterator = nil
            let error = launcherError(error)
            if !(approval && { if case .insufficientSpace = error { true } else { false } }()) {
                await logGameFailure(error, id: id, log: log)
            }
            throw error
        }
    }
}

/// A value-only preview backend: no HTTP client, store, paths on disk or processes.
final class PreviewGameServices: GameServices, Sendable {
    private struct State { var statuses: [String: GameStatus]; var voices: [String: Set<String>] = [:] }
    private let state: Mutex<State>
    init(states: [String: GameState] = [:]) { state = Mutex(State(statuses: states.mapValues(\.status))) }
    func start() async {}
    func waitUntilIdle(_ id: String) async throws {}
    func status(_ id: String) async -> GameStatus { state.withLock { $0.statuses[id] ?? .notInstalled } }
    func checkForUpdate(_ id: String) async throws -> GameStatus { await status(id) }
    func record(_ id: String) async throws -> GameRecord? {
        let value = state.withLock { ($0.statuses[id] ?? .notInstalled, $0.voices[id] ?? ["en-us"]) }
        if value.0 == .notInstalled || value.0 == .unknown { return nil }
        let tag: String
        switch value.0 { case .installed(let t), .updateAvailable(let t, _): tag = t; default: tag = "1.0" }
        return GameRecord(installPath: URL(fileURLWithPath: "/preview/Games/\(id)"), ownership: .created,
            executable: try SafeRelativePath("Game.exe"), installed: InstalledBuild(tag: tag, buildID: "preview", categories: [], voices: value.1),
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        GameEstimate(download: 20 << 30, diskWhole: 50 << 30, diskMinimum: 5 << 30, available: 80 << 30)
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { complete(id, voices: voices) }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { complete(id, voices: voices) }
    func update(_ id: String, approved: Bool) async -> GameEventStream { complete(id) }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { complete(id) }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { complete(id) }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { complete(id, voices: voices) }
    func uninstall(_ id: String) async throws { state.withLock { $0.statuses[id] = .notInstalled; $0.voices[id] = nil } }
    private func complete(_ id: String, voices: Set<String>? = nil) -> GameEventStream {
        state.withLock {
            let tag: String
            switch $0.statuses[id] { case .updateAvailable(_, let to): tag = to; case .installed(let t): tag = t; default: tag = "1.0" }
            $0.statuses[id] = .installed(tag: tag)
            if let voices { $0.voices[id] = voices }
        }
        return GameEventStream { $0.yield(.phase(.completed)); $0.finish() }
    }
}
