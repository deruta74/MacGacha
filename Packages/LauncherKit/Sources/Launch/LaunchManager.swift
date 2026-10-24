// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import RuntimeManager

/// Owns supervision independently of any UI observer. Cancelling or discarding the
/// event stream detaches that observer; it never cancels the game or its restore.
public actor LaunchManager {
    package typealias ProxyFactory = @Sendable ([String], @escaping @Sendable (String) -> Void) async throws -> any LaunchSessionProxy
    private let paths: AppPaths
    private let runtimes: any LaunchRuntimeProviding
    private let prefixes: any LaunchPrefixProviding
    private let preparation: any LaunchPreparing
    private let spawner: any ProcessSpawner
    private let inspector: any ProcessInspector
    private let runner: any ProcessRunner
    private let clock: any Clock<Duration>
    private let proxyFactory: ProxyFactory
    private let baseEnvironment: [String: String]
    private let journalFileOps: any FileOps
    private let hideHooks: LaunchFileHooks
    private let beforeJournalRead: @Sendable () throws -> Void
    private let beforeRecoveryRead: @Sendable () async throws -> Void
    private let sessionProvenance: @Sendable () throws -> (bootSessionUUID: String, sessionStartTime: UInt64)
    private var contexts: [String: Context] = [:]
    private var reservedGame: String?
    private var recovering = false
    private var guardRecoveries: Set<String> = []
    private var supervision: [String: Task<Void, Never>] = [:]

    private final class Context {
        var session: LaunchSession
        // Uncertainty is a recovery state, not evidence that startup completed.
        var watchPhase: LaunchSession.State
        let lock: SessionLock
        let pin: RuntimePin
        var log: SessionLog?
        var proxy: (any LaunchSessionProxy)?
        var ready = false
        var runningAnnounced = false
        var ownedWrapper: ProcessIdentity?
        var unverifiedBuild = false
        var deferredFailure: LaunchFailure?
        // Keep the verified restore across unlink/fsync failure. The journal can
        // already be absent, so it cannot reconstruct this finalization retry.
        var finalization: (session: LaunchSession, outcome: RestoreOutcome)?
        var worker: Task<Void, Never>?
        var continuation: AsyncStream<LaunchEvent>.Continuation?
        init(session: LaunchSession, lock: SessionLock, pin: RuntimePin, log: SessionLog? = nil) {
            self.session = session; self.lock = lock; self.pin = pin; self.log = log
            self.watchPhase = session.state == .running ? .running : .spawning
        }
    }

    public init(paths: AppPaths, runtimes: any LaunchRuntimeProviding, prefixes: any LaunchPrefixProviding,
        preparation: any LaunchPreparing, spawner: any ProcessSpawner, inspector: any ProcessInspector,
        runner: any ProcessRunner, clock: any Clock<Duration>) {
        self.paths = paths; self.runtimes = runtimes; self.prefixes = prefixes; self.preparation = preparation
        self.spawner = spawner; self.inspector = inspector; self.runner = runner; self.clock = clock
        self.baseEnvironment = ProcessInfo.processInfo.environment; self.journalFileOps = SystemFileOps()
        self.hideHooks = .none; self.beforeJournalRead = {}; self.beforeRecoveryRead = {}
        self.sessionProvenance = Self.currentSessionProvenance
        self.proxyFactory = { hosts, log in try await SessionProxy.start(blockedHosts: hosts, log: log) }
    }

    package init(paths: AppPaths, runtimes: any LaunchRuntimeProviding, prefixes: any LaunchPrefixProviding,
        preparation: any LaunchPreparing, spawner: any ProcessSpawner, inspector: any ProcessInspector,
        runner: any ProcessRunner, clock: any Clock<Duration>, proxyFactory: @escaping ProxyFactory,
        baseEnvironment: [String: String] = [:], journalFileOps: any FileOps = SystemFileOps(),
        hideHooks: LaunchFileHooks = .none, beforeJournalRead: @escaping @Sendable () throws -> Void = {},
        beforeRecoveryRead: @escaping @Sendable () async throws -> Void = {},
        sessionProvenance: @escaping @Sendable () throws -> (bootSessionUUID: String, sessionStartTime: UInt64) = LaunchManager.currentSessionProvenance) {
        self.paths = paths; self.runtimes = runtimes; self.prefixes = prefixes; self.preparation = preparation
        self.spawner = spawner; self.inspector = inspector; self.runner = runner; self.clock = clock
        self.proxyFactory = proxyFactory; self.baseEnvironment = baseEnvironment; self.journalFileOps = journalFileOps
        self.hideHooks = hideHooks; self.beforeJournalRead = beforeJournalRead; self.beforeRecoveryRead = beforeRecoveryRead
        self.sessionProvenance = sessionProvenance
    }

    package nonisolated static func currentSessionProvenance() throws -> (bootSessionUUID: String, sessionStartTime: UInt64) {
        // Called on BlockingIO before the first durable snapshot and spawn.
        (try SystemProcessInspector.bootSessionUUID(), UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }

    public func launch(game: GameDefinition, installRoot: URL, gameBuild: String) -> AsyncStream<LaunchEvent> {
        let pair = AsyncStream<LaunchEvent>.makeStream()
        // Reserve synchronously, before an actor reentrancy point or any I/O.
        if let busy = reservedGame ?? contexts.keys.sorted().first ?? supervision.keys.sorted().first {
            pair.continuation.yield(.stage(.lock))
            pair.continuation.yield(.failed(LaunchFailure(stage: .lock, message: String(localized: "\(Self.name(busy)) is running"), logURL: nil,
                unverifiedBuild: !(Recipes.recipe(for: game.id)?.verifiedBuilds.contains(gameBuild) ?? false))))
            pair.continuation.finish(); return pair.stream
        }
        if recovering || !guardRecoveries.isEmpty {
            pair.continuation.yield(.failed(LaunchFailure(stage: .lock, message: String(localized: "Launch recovery is in progress"), logURL: nil, unverifiedBuild: false)))
            pair.continuation.finish(); return pair.stream
        }
        reservedGame = game.id
        // This owner task is deliberately unrelated to stream termination.
        supervision[game.id] = Task { await self.start(game: game, installRoot: installRoot, gameBuild: gameBuild, events: pair.continuation) }
        return pair.stream
    }

    package func waitForSupervision(game: String) async { await supervision[game]?.value }

    public func liveSession(for game: String) -> LaunchSession? { contexts[game]?.session }

    /// Completed recoveries remain available across restarts until acknowledged.
    public func pendingRecoveryNotices() async throws -> [RecoveryNotice] {
        let paths = paths
        return try await BlockingIO.run { try RecoveryNoticeStore(paths: paths).load() }
    }

    public func acknowledgeRecoveryNotice(id: UUID) async throws {
        let paths = paths
        try await BlockingIO.run { try RecoveryNoticeStore(paths: paths).acknowledge(id: id) }
    }

    public func markReady(game: String) {
        guard let context = contexts[game], context.session.state == .running, !context.ready else { return }
        context.ready = true; context.continuation?.yield(.ready)
    }

    private func start(game: GameDefinition, installRoot: URL, gameBuild: String, events: AsyncStream<LaunchEvent>.Continuation) async {
        defer { finishedSupervision(game: game.id) }
        var stage = LaunchStage.preflight
        let unverified = !(Recipes.recipe(for: game.id)?.verifiedBuilds.contains(gameBuild) ?? false)
        do {
            events.yield(.stage(stage))
            guard let recipe = Recipes.recipe(for: game.id) else { throw LauncherError.io("Unknown launch game") }
            let paths = paths, journalFileOps = journalFileOps
            let (settings, logsEnabled, identity) = try await BlockingIO.run {
                let settings = try LaunchSettingsStore(paths: paths).load(game.id)
                let enabled = try GlobalLaunchSettingsStore(paths: paths).load().sessionLogsEnabled
                let fs = try ContainedFileSystem(root: installRoot).pinRoot()
                guard try fs.itemType(at: recipe.executable) == .regularFile else { throw LauncherError.io("Game executable is missing") }
                return (settings, enabled, try fs.rootIdentity())
            }
            let selection = try await runtimes.selection(for: settings)
            let bundle = selection.bundle
            let prefix = try await prefixes.prefixURL(game: game.id, bundle: bundle)
            let preview = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: installRoot, prefix: prefix,
                wineBinary: bundle.wineBinary, proxyPort: 0, componentRoots: selection.componentRoots, baseEnvironment: baseEnvironment)
            guard !selection.componentIDs.isEmpty else { throw LauncherError.io("The runtime bundle has no pinnable components") }
            let compatibilityIDs = try preview.requiredComponents.map { kind in
                guard let id = selection.compatibilityComponentIDs[kind] else { throw LauncherError.io("Required compatibility component has no pin identity") }
                return id
            }
            let ids = Array(Set(selection.componentIDs + compatibilityIDs)).sorted()
            stage = .lock; events.yield(.stage(stage))
            let (lock, pin) = try await BlockingIO.run {
                let lock = try SessionLock.acquire(paths: paths, game: game.id)
                let pin = try RuntimePin.pin(paths: paths, componentIDs: ids)
                return (lock, pin)
            }
            let validated = try await runtimes.selection(for: settings)
            guard validated.bundle == bundle,
                Set(validated.componentIDs) == Set(selection.componentIDs),
                preview.requiredComponents.allSatisfy({ validated.componentRoots[$0] == selection.componentRoots[$0]
                    && validated.compatibilityComponentIDs[$0] == selection.compatibilityComponentIDs[$0] }) else {
                throw LauncherError.io("The selected runtime changed before it could be pinned")
            }
            guard try await read(game: game.id) == nil else { throw LauncherError.busy("Launch recovery is required") }
            let provenance = sessionProvenance
            let (bootSessionUUID, sessionStartTime) = try await BlockingIO.run { try provenance() }
            let session = LaunchSession(sessionID: UUID(), game: game.id, installRoot: installRoot, installIdentity: identity,
                prefix: prefix, bundleID: bundle.id.rawValue, runtimeDigest: bundle.digest, wineBinary: bundle.wineBinary,
                wineserver: bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"), componentIDs: ids,
                recipeVersion: recipe.recipeVersion, settings: settings, gameExecutable: recipe.executable,
                bootSessionUUID: bootSessionUUID, sessionStartTime: sessionStartTime)
            let context = Context(session: session, lock: lock, pin: pin)
            context.continuation = events; context.unverifiedBuild = unverified; contexts[game.id] = context
            stage = .snapshot; events.yield(.stage(stage))
            try await persist(context.session)
            if logsEnabled {
                let clock = clock
                context.log = try await BlockingIO.run {
                    try SessionLog.create(paths: paths, game: game.id, header: ["recipe": game.id,
                        "recipeVersion": String(recipe.recipeVersion), "gameBuild": gameBuild, "backend": settings.backend.rawValue,
                        "runtimeBundle": bundle.id.rawValue, "runtimeDigest": bundle.digest.hex, "componentIDs": ids.joined(separator: ","),
                        "settings": String(describing: settings)], now: Date(), timeZone: .current, maxBytes: 64 << 20,
                        ticker: ClockSessionLogTicker(clock: clock))
                }
            }
            await note(context, "stage snapshot")
            context.session.sessionLogURL = context.log?.url
            try await persist(context.session)
            stage = .prepare; events.yield(.stage(stage)); await note(context, "stage prepare")
            let initialized = try await prefixes.createPrefix(game: game.id, bundle: bundle)
            guard initialized.standardizedFileURL == prefix.standardizedFileURL else { throw LauncherError.io("Prefix changed during preparation") }
            try await preparation.ensure(prefix: prefix, wineBinary: bundle.wineBinary, request: preview.preparation)
            let original = context.session, log = context.log, hideHooks = hideHooks, beforeJournalRead = beforeJournalRead
            let (hiddenSnapshot, hideResult) = try await BlockingIO.run {
                var snapshot = original
                try LaunchCopies.copyIfPresent(preview.copyIfPresent, installRoot: installRoot,
                    system32: prefix.appendingPathComponent("drive_c/windows/system32"), log: log)
                let result = Result { try HiddenFiles(hooks: hideHooks).hide(preview.hidden, session: &snapshot,
                    journal: LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead)) }
                return (snapshot, result)
            }
            // inout progress survives errors, including a rename followed by a
            // failed done write. The on-disk journal remains authoritative.
            context.session = hiddenSnapshot
            try hideResult.get()
            stage = .proxy; events.yield(.stage(stage)); await note(context, "stage proxy")
            let logger: @Sendable (String) -> Void = { if logsEnabled { log?.append(line: $0) } }
            context.proxy = try await proxyFactory(preview.blockedHosts, logger)
            context.session.proxyPort = context.proxy?.port
            let resolved = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: installRoot, prefix: prefix,
                wineBinary: bundle.wineBinary, proxyPort: context.proxy!.port, componentRoots: selection.componentRoots, baseEnvironment: baseEnvironment)
            stage = .spawn; events.yield(.stage(stage)); await note(context, "stage spawn")
            context.session.state = .spawning; try await persist(context.session)
            let spawner = spawner, output = context.log?.processOutput ?? .discard
            let process = try await BlockingIO.run {
                try spawner.spawn(resolved.executable, arguments: resolved.arguments, environment: resolved.environment,
                    currentDirectory: resolved.currentDirectory, output: output)
            }
            context.ownedWrapper = process
            context.session.processes = [process]
            context.session.processGroupIDs = [process.pid]
            try await persist(context.session)
            stage = .watch; events.yield(.stage(stage)); await note(context, "stage watch")
            await watch(game: game.id, executable: recipe.executable.components.last!)
            return
        } catch {
            if let context = contexts[game.id] {
                // hide() may have durably recorded more entries before throwing.
                if let persisted = try? await read(game: game.id), persisted.sessionID == context.session.sessionID { context.session = persisted }
                if let owned = context.ownedWrapper {
                    if !context.session.processes.contains(owned) { context.session.processes.append(owned) }
                    context.session.processGroupIDs = (context.session.processGroupIDs ?? []).union([owned.pid])
                }
                await note(context, "failed \(stage.rawValue)")
                if context.ownedWrapper != nil, let executable = Self.executable(context.session) {
                    // A successful spawn is irreversible: retain ownership and
                    // defer its failure report until verified end and restore.
                    context.deferredFailure = Self.failure(error, stage: stage, log: context.log?.url, unverified: unverified)
                    await pending(context, reason: "Process state could not be confirmed")
                    await watch(game: game.id, executable: executable)
                } else {
                    await stopProxy(context)
                    // A failed read is not evidence that the snapshot is absent.
                    var confirmedMissing = false
                    if stage == .snapshot {
                        do { confirmedMissing = try await read(game: game.id) == nil } catch {}
                    }
                    if confirmedMissing { contexts[game.id] = nil; reservedGame = nil }
                    else { _ = await restore(context) }
                    report(error, stage: stage, context: context, unverified: unverified)
                }
            } else {
                events.yield(.failed(Self.failure(error, stage: stage, log: nil, unverified: unverified))); events.finish()
                reservedGame = nil
            }
        }
    }

    private func watch(game: String, executable: String) async {
        guard let context = contexts[game] else { return }
        let watcher = SessionWatcher(runtimesRoot: paths.runtimes, inspector: inspector, runner: runner, clock: clock)
        let reaper = context.ownedWrapper.map { OwnedWrapperReaper(identity: $0) }
        let supervisionClock = clock
        let reaperClock = AnyLaunchClock(supervisionClock)
        defer { reaper?.continueReaping(clock: reaperClock) }
        while true {
            do {
                var watching = context.session
                watching.state = context.watchPhase
                try await watcher.watch(session: watching, executable: executable, ownedWrapper: context.ownedWrapper, ownedReaper: reaper) { processes in
                    try await self.observed(game: game, processes: processes)
                }
                context.session.state = .ending; try await persist(context.session)
                context.continuation?.yield(.ended(normal: context.ready))
                if !context.ready { await note(context, "failed watch: game ended before ready") }
                await stopProxy(context)
                _ = await restore(context)
                if let failure = context.deferredFailure {
                    context.continuation?.yield(.stage(.report)); context.continuation?.yield(.failed(failure)); context.continuation?.finish()
                } else if !context.ready {
                    report(LauncherError.io("The game ended before a window appeared"), stage: .watch, context: context, unverified: context.unverifiedBuild)
                } else { context.continuation?.yield(.stage(.report)); context.continuation?.finish() }
                return
            } catch SessionWatchError.startup {
                await note(context, "failed watch: startup")
                context.continuation?.yield(.ended(normal: false)); await stopProxy(context)
                _ = await restore(context)
                if let failure = context.deferredFailure {
                    context.continuation?.yield(.stage(.report)); context.continuation?.yield(.failed(failure)); context.continuation?.finish()
                } else { report(LauncherError.io("The game did not start"), stage: .watch, context: context, unverified: context.unverifiedBuild) }
                return
            } catch {
                // A failed write or incomplete scan cannot authorize restoration or
                // disconnect a potentially live game from its session proxy.
                await note(context, "watch retry: process state unknown")
                await pending(context, reason: "Process state could not be confirmed")
                // Ownership is independent of observer cancellation. Even if an
                // internal task is cancelled, retry pacing must not busy-loop.
                let clock = clock
                _ = try? await Task.detached { try await clock.sleep(for: .seconds(1)) }.value
            }
        }
    }

    private func observed(game: String, processes: [ProcessIdentity]) async throws {
        guard let context = contexts[game] else { return }
        context.watchPhase = .running
        context.session.state = .running
        context.session.processes = Array(Set(context.session.processes + processes)).sorted { $0.pid < $1.pid }
        try await persist(context.session)
        if !context.runningAnnounced { context.runningAnnounced = true; context.continuation?.yield(.running) }
    }

    private func restore(_ context: Context) async -> RestoreOutcome {
        await note(context, "stage restore")
        context.continuation?.yield(.stage(.restore))
        let paths = paths, journalFileOps = journalFileOps, beforeJournalRead = beforeJournalRead
        if context.finalization == nil {
            let original = context.session
            do {
                let (session, outcome) = try await BlockingIO.run {
                    var snapshot = original
                    let journal = LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead)
                    let outcome = try HiddenFiles().restore(session: &snapshot, journal: journal, retainResolvedJournal: true)
                    return (snapshot, outcome)
                }
                context.session = session
                if Self.resolved(outcome, session: session) {
                    context.finalization = (session, outcome)
                } else {
                    context.continuation?.yield(.restored(outcome))
                    if let log = context.log { _ = try? await BlockingIO.run { log.finish() } }
                    return outcome
                }
            } catch {
                await pending(context, reason: "Launch recovery could not finish")
                return .pending(reason: "Launch recovery could not finish")
            }
        }
        guard let (session, outcome) = context.finalization else { preconditionFailure("Missing restore finalization") }
        do {
            try await BlockingIO.run {
                if case .conflict(let movedTo) = outcome {
                    try RecoveryNoticeStore(paths: paths).record(RecoveryNotice(id: session.sessionID, game: session.game, movedTo: movedTo))
                }
                // Publish notification first. Deletion always syncs the parent,
                // including a retry after unlink succeeded but its fsync failed.
                try LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead).delete(game: session.game)
            }
        } catch {
            // Do not persist pending over a resolved journal, or discard our
            // completed snapshot when the journal has already been unlinked.
            context.session.state = .recoveryPending
            let outcome = RestoreOutcome.pending(reason: "Launch recovery could not finish")
            context.continuation?.yield(.restored(outcome))
            return outcome
        }
        context.session = session
        context.finalization = nil
        context.continuation?.yield(.restored(outcome))
        if let log = context.log { _ = try? await BlockingIO.run { log.finish() } }
        if Self.resolved(outcome, session: session) {
            contexts[session.game] = nil
            if reservedGame == session.game && supervision[session.game] == nil { reservedGame = nil }
        }
        return outcome
    }

    private func note(_ context: Context, _ line: String) async {
        guard let log = context.log else { return }
        _ = try? await BlockingIO.run { log.append(line: line) }
    }
    private func pending(_ context: Context, reason: String) async {
        // Never replace durable hide ownership with an older caller snapshot.
        // If reading fails, retain the journal byte-for-byte and only update our
        // in-memory status; the next supervision/guard attempt reads it again.
        do {
            if var persisted = try await read(game: context.session.game), persisted.sessionID == context.session.sessionID {
                if let owned = context.ownedWrapper {
                    if !persisted.processes.contains(owned) { persisted.processes.append(owned) }
                    persisted.processGroupIDs = (persisted.processGroupIDs ?? []).union([owned.pid])
                }
                persisted.state = .recoveryPending
                try await persist(persisted)
                context.session = persisted
            }
        } catch {}
        context.session.state = .recoveryPending
        context.continuation?.yield(.restored(.pending(reason: reason)))
    }
    private func stopProxy(_ context: Context) async { await context.proxy?.stop(); context.proxy = nil }
    private func persist(_ session: LaunchSession) async throws {
        let paths = paths, journalFileOps = journalFileOps, beforeJournalRead = beforeJournalRead
        try await BlockingIO.run {
            let journal = LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead)
            if let prior = try journal.read(game: session.game), prior.sessionID == session.sessionID {
                guard prior.hides.allSatisfy({ durable in session.hides.contains { $0.path == durable.path } }) else {
                    throw LauncherError.io("Refusing to replace newer launch recovery ownership")
                }
            }
            try journal.write(session)
        }
    }
    private func read(game: String) async throws -> LaunchSession? {
        try await beforeRecoveryRead()
        let paths = paths, journalFileOps = journalFileOps, beforeJournalRead = beforeJournalRead
        return try await BlockingIO.run { try LaunchJournal(paths: paths, fileOps: journalFileOps, beforeRead: beforeJournalRead).read(game: game) }
    }
    private func report(_ error: any Error, stage: LaunchStage, context: Context, unverified: Bool) {
        context.continuation?.yield(.stage(.report))
        context.continuation?.yield(.failed(Self.failure(error, stage: stage, log: context.log?.url, unverified: unverified)))
        context.continuation?.finish(); context.continuation = nil
    }
    private static func failure(_ error: any Error, stage: LaunchStage, log: URL?, unverified: Bool) -> LaunchFailure {
        LaunchFailure(stage: stage, message: String(localized: "Launch failed during \(stage.rawValue)."), logURL: log, unverifiedBuild: unverified)
    }
    private static func name(_ game: String) -> String {
        ["starrail": "Star Rail", "genshin": "Genshin Impact", "zzz": "Zenless Zone Zero"][game] ?? "A game"
    }

    /// Startup recovery reads only durable snapshots. No proxy is recreated:
    /// surviving games keep the old, unavailable proxy endpoint (Option A).
    public func reattachAll() async -> [String: LaunchSession] {
        await reattachAll(recoveryGame: nil)
    }

    private func reattachAll(recoveryGame: String?) async -> [String: LaunchSession] {
        guard !recovering else { return contexts.mapValues(\.session) }
        recovering = true
        defer { recovering = false }
        for game in Recipes.games where contexts[game] == nil && (!guardRecoveries.contains(game) || recoveryGame == game) {
            do {
                guard let snapshot = try await read(game: game) else { continue }
                let paths = paths
                let (lock, pin) = try await BlockingIO.run {
                    (try SessionLock.acquire(paths: paths, game: game), try RuntimePin.pin(paths: paths, componentIDs: snapshot.componentIDs))
                }
                let context = Context(session: snapshot, lock: lock, pin: pin)
                contexts[game] = context
                let clock = clock
                context.log = try? await BlockingIO.run {
                    guard let url = snapshot.sessionLogURL,
                        url.deletingLastPathComponent().standardizedFileURL == paths.logs.standardizedFileURL,
                        LaunchLogFiles.parseName(url.lastPathComponent)?.game == game else { return nil }
                    return try SessionLog.recover(at: url, ticker: ClockSessionLogTicker(clock: clock))
                }
                do {
                    if try await alive(snapshot) {
                        guard let executable = Self.executable(snapshot) else {
                            await pending(context, reason: "The snapshot's executable could not be confirmed"); continue
                        }
                        let task = Task {
                            await self.watch(game: game, executable: executable)
                            self.finishedSupervision(game: game)
                        }
                        context.worker = task; supervision[game] = task
                    } else { _ = await restore(context) }
                } catch {
                    await pending(context, reason: "Process state could not be confirmed")
                    if let executable = Self.executable(snapshot) {
                        let task = Task {
                            await self.watch(game: game, executable: executable)
                            self.finishedSupervision(game: game)
                        }
                        context.worker = task; supervision[game] = task
                    }
                }
            } catch { /* A busy or unreadable snapshot is retained for the next recovery attempt. */ }
        }
        return contexts.mapValues(\.session)
    }

    private func finishedSupervision(game: String) {
        supervision[game] = nil
        if contexts[game] == nil, reservedGame == game { reservedGame = nil }
    }

    private func alive(_ session: LaunchSession) async throws -> Bool {
        let inspector = inspector, scope = session.inspectionScope(runtimesRoot: paths.runtimes)
        return try await BlockingIO.run {
            let processes = try inspector.processes(environmentContains: "WINEPREFIX", value: session.prefix.path, scope: scope)
            if session.processes.contains(where: { inspector.isAlive($0) }) { return true }
            guard let executable = Self.executable(session)?.lowercased() else { throw LauncherError.io("Unknown snapshot executable") }
            return processes.contains {
                let leaf = URL(fileURLWithPath: $0.executablePath).lastPathComponent.lowercased()
                if leaf == "wineserver" || leaf == "wineserver64" || leaf == executable { return true }
                return ["wine", "wine64", "wine-preloader", "wine64-preloader"].contains(leaf)
                    && $0.arguments.first.map { Self.executableLeaf($0) == executable } == true
            }
        }
    }

    private static func resolved(_ outcome: RestoreOutcome, session: LaunchSession) -> Bool {
        guard session.hides.isEmpty else { return false }
        switch outcome {
        case .clean: return true
        case .conflict: return session.state == .recoveryConflict
        case .pending: return false
        }
    }

    private static func executable(_ session: LaunchSession) -> String? {
        if let path = session.gameExecutable { return path.components.last }
        // Compatibility with journals written before the additive field: only
        // the exact, still-known recipe revision may supply a fallback.
        guard let recipe = Recipes.recipe(for: session.game), recipe.recipeVersion == session.recipeVersion else { return nil }
        return recipe.executable.components.last
    }
    private static func executableLeaf(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }

    /// Recovery has one owner per game. Retain the guard reservation across all
    /// awaits; a reattach may transfer ownership to a watcher, which wins.
    public func recoverIfNeeded(game: String) async throws {
        guard !recovering else { throw LauncherError.busy("Launch recovery is in progress") }
        guard guardRecoveries.insert(game).inserted else { throw LauncherError.busy("Launch recovery is in progress") }
        defer { guardRecoveries.remove(game) }
        try requireGuardOwnership(game: game)
        if contexts[game] == nil {
            let snapshot = try await read(game: game)
            try requireGuardOwnership(game: game)
            if snapshot != nil {
                _ = await reattachAll(recoveryGame: game)
                try requireGuardOwnership(game: game)
            }
        }
        guard let context = contexts[game] else {
            let snapshot = try await read(game: game)
            try requireGuardOwnership(game: game)
            guard contexts[game] == nil, snapshot == nil else { throw LauncherError.busy("Launch recovery is required") }
            return
        }
        guard context.session.state == .recoveryPending || context.session.state == .recoveryConflict else {
            throw LauncherError.busy("\(Self.name(game)) is running")
        }
        if context.finalization == nil {
            let stillAlive: Bool
            do { stillAlive = try await alive(context.session) }
            catch { throw LauncherError.busy("The session's process state cannot be confirmed") }
            try requireGuardOwnership(game: game, context: context)
            guard !stillAlive else { throw LauncherError.busy("\(Self.name(game)) is running") }
        }
        let outcome = await restore(context)
        try requireGuardOwnership(game: game)
        guard contexts[game] == nil, Self.resolved(outcome, session: context.session) else { throw LauncherError.busy("Launch recovery is required") }
    }

    private func requireGuardOwnership(game: String, context: Context? = nil) throws {
        guard supervision[game] == nil else { throw LauncherError.busy("Launch supervision is in progress") }
        guard !(reservedGame == game && contexts[game] == nil) else { throw LauncherError.busy("Launch preparation is in progress") }
        if let context, contexts[game] !== context { throw LauncherError.busy("Launch recovery ownership changed") }
    }

}

public struct LaunchManagerOperationGuard: GameOperationGuard {
    private let manager: LaunchManager
    public init(manager: LaunchManager) { self.manager = manager }
    public func willOperate(on game: String) async throws { try await manager.recoverIfNeeded(game: game) }
}
