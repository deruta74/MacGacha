// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Launch
import GameLibrary
import RuntimeManager

struct LaunchObservation: Sendable {
    let session: LaunchSession
    let hasEnded: Bool
}

protocol LaunchServices: Sendable {
    func startupReattachment() async throws -> LaunchStartupResult
    func reattach() async throws -> [String: LaunchSession]
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent>
    func observation(_ id: String) async throws -> LaunchObservation?
    func recover(_ id: String) async throws
    func session(_ id: String) async -> LaunchSession?
    func gameProcessIDs(_ id: String) async -> [Int32]
    func markReady(_ id: String) async
    func notices() async throws -> [RecoveryNotice]
    func acknowledge(_ id: UUID) async throws
}

extension LaunchServices {
    func startupReattachment() async throws -> LaunchStartupResult { LaunchStartupResult(sessions: try await reattach()) }
}

/// The same lazy manager backs launch, startup recovery and GameLibrary's guard.
/// Construction performs no I/O; callers join startup before any game operation.
actor LiveLaunchServices: LaunchServices, GameOperationGuard {
    private let paths: AppPaths
    private let icons: any GameModeIconProviding
    private let log: EventLog?
    private var construction: Task<LaunchManager, any Error>?
    private var startup: Task<LaunchStartupResult, Never>?
    init(paths: AppPaths, log: EventLog? = nil, icons: any GameModeIconProviding = BundleGameModeIcons()) {
        self.paths = paths; self.log = log; self.icons = icons
    }
    private func manager() async throws -> LaunchManager {
        if let construction { return try await construction.value }
        let paths = paths, log = log, icons = icons
        let task = Task {
            let manifest = try await BundledRuntimeManifest.load()
            let runner = SystemProcessRunner(), store = RuntimeStore(paths: paths)
            let consent = ConsentStore(url: paths.root.appendingPathComponent("consent.json"), root: paths.root)
            let bundles = RuntimeBundleManager(manifest: manifest, store: store, consent: consent,
                installer: ComponentInstaller(store: store, consent: consent))
            return LaunchManager(paths: paths, runtimes: LiveLaunchRuntimes(manifest: manifest, manager: bundles, store: store),
                prefixes: PrefixManager(paths: paths, runner: runner), preparation: LaunchPreparation(paths: paths, runner: runner),
                spawner: SystemProcessSpawner(), inspector: SystemProcessInspector(), runner: runner, clock: ContinuousClock(), log: log, gameMode: GameModeHelper(paths: paths, icons: icons))
        }
        construction = task
        return try await task.value
    }
    func reattach() async throws -> [String: LaunchSession] {
        try await startupReattachment().sessions
    }
    func startupReattachment() async throws -> LaunchStartupResult {
        if let startup { return await startup.value }
        let manager = try await manager()
        if let startup { return await startup.value }
        let task = Task { await manager.reattachStartup() }
        startup = task
        let result = await task.value
        // Single-flight construction, not a permanent cache of failed recovery.
        if !result.unresolved.isEmpty { startup = nil }
        return result
    }
    func willOperate(on game: String) async throws {
        _ = try await reattach()
        try await manager().recoverIfNeeded(game: game)
    }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        _ = try await reattach()
        return await (try manager()).launch(game: game, installRoot: record.installPath, gameBuild: record.installed?.tag ?? "unknown")
    }
    func observation(_ id: String) async throws -> LaunchObservation? {
        try await manager().sessionObservation(for: id).map { LaunchObservation(session: $0.session, hasEnded: $0.hasEnded) }
    }
    func recover(_ id: String) async throws { try await manager().recoverIfNeeded(game: id) }
    func session(_ id: String) async -> LaunchSession? { try? await manager().liveSession(for: id) }
    func gameProcessIDs(_ id: String) async -> [Int32] {
        guard let session = await session(id) else { return [] }
        let recipe = Recipes.recipe(for: id)
        guard let executable = session.gameExecutable ?? (recipe?.recipeVersion == session.recipeVersion ? recipe?.executable : nil) else { return [] }
        let roots = [paths.runtimes, session.installRoot]
        return (try? await BlockingIO.run {
            let scope = ProcessInspectionScope(executableRoots: roots, processGroupIDs: session.processGroupIDs ?? [],
                identities: Set(session.processes), bootSessionUUID: session.bootSessionUUID, sessionStartTime: session.sessionStartTime)
            let processes = try SystemProcessInspector().processes(environmentContains: "WINEPREFIX", value: session.prefix.path, scope: scope)
            let name = Self.basename(executable.description)
            return processes.filter {
                let binary = Self.basename($0.executablePath)
                return binary == name || (["wine", "wine64", "wine-preloader", "wine64-preloader"].contains(binary)
                    && $0.arguments.first.map { Self.basename($0) == name } == true)
            }.map { $0.identity.pid }
        }) ?? []
    }
    private nonisolated static func basename(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }
    func markReady(_ id: String) async { try? await manager().markReady(game: id) }
    func notices() async throws -> [RecoveryNotice] { try await manager().pendingRecoveryNotices() }
    func acknowledge(_ id: UUID) async throws { try await manager().acknowledgeRecoveryNotice(id: id) }
}

struct PreviewLaunchServices: LaunchServices {
    func reattach() async throws -> [String: LaunchSession] { [:] }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        AsyncStream { $0.finish() }
    }
    func observation(_ id: String) async throws -> LaunchObservation? { nil }
    func recover(_ id: String) async throws {}
    func session(_ id: String) async -> LaunchSession? { nil }
    func gameProcessIDs(_ id: String) async -> [Int32] { [] }
    func markReady(_ id: String) async {}
    func notices() async throws -> [RecoveryNotice] { [] }
    func acknowledge(_ id: UUID) async throws {}
}

/// Blocking preferences storage is injectable; the model always calls it on BlockingIO.
protocol LaunchPreferencesPersistence: Sendable {
    func loadGames() throws -> [String: LaunchSettings]
    func loadGlobal() throws -> GlobalLaunchSettings
    func save(_ settings: LaunchSettings, game: String) throws
    func saveGlobal(_ settings: GlobalLaunchSettings) throws
}
struct LiveLaunchPreferencesPersistence: LaunchPreferencesPersistence {
    let paths: AppPaths
    func loadGames() throws -> [String: LaunchSettings] {
        let store = LaunchSettingsStore(paths: paths)
        return try Dictionary(uniqueKeysWithValues: GameDefinition.all.map { ($0.id, try store.load($0.id)) })
    }
    func loadGlobal() throws -> GlobalLaunchSettings { try GlobalLaunchSettingsStore(paths: paths).load() }
    func save(_ settings: LaunchSettings, game: String) throws { try LaunchSettingsStore(paths: paths).save(settings, for: game) }
    func saveGlobal(_ settings: GlobalLaunchSettings) throws { try GlobalLaunchSettingsStore(paths: paths).save(settings) }
}
