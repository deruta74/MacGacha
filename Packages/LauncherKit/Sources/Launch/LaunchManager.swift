// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import RuntimeManager

public struct LaunchStartupResult: Sendable {
    public let sessions: [String: LaunchSession]
    /// Journal discovery/read or ownership failed; absence is not established.
    public let unresolved: Set<String>
    public init(sessions: [String: LaunchSession] = [:], unresolved: Set<String> = []) {
        self.sessions = sessions; self.unresolved = unresolved
    }
}

/// Owns supervision independently of any UI observer. Cancelling or discarding the
/// event stream detaches that observer; it never cancels the game or its restore.
public actor LaunchManager {
    package typealias ProxyFactory = @Sendable ([String], @escaping @Sendable (String) -> Void) async throws -> any LaunchSessionProxy
    private let recipeOverrides: [String: LaunchRecipe]
    private let paths: AppPaths
    private let eventLog: EventLog
    private let sessionLogWriter: BestEffortLogWriter<SessionLogWork>
    private let runtimes: any LaunchRuntimeProviding
    private let prefixes: any LaunchPrefixProviding
    private let preparation: any LaunchPreparing
    private let spawner: any ProcessSpawner
    private let inspector: any ProcessInspector
    private let runner: any ProcessRunner
    private let clock: any Clock<Duration>
    private let gameMode: (any GameModeProviding)?
    private let displayProbe: any DisplayProbe
    private let proxyFactory: ProxyFactory
    private let baseEnvironment: [String: String]
    private let journalFileOps: any FileOps
    private let hideHooks: LaunchFileHooks
    private let beforeJournalRead: @Sendable () throws -> Void
    private let beforeRecoveryRead: @Sendable () async throws -> Void
    private let sessionProvenance: @Sendable () throws -> (bootSessionUUID: String, sessionStartTime: UInt64)
    private var contexts: [String: Context] = [:]
    private var unresolvedStartup: Set<String> = []
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
        var lifecycleLog: SessionLifecycleLog?
        var proxy: (any LaunchSessionProxy)?
        // Process lifetime is independent of file recovery and journal durability.
        // Reattached UI observers must stop their window timers at verified end.
        var hasEnded = false
        var ready = false
        var runningAnnounced = false
        var endOutcome = "while MacGacha was closed"
        var restoreEntryCount = 0
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
            self.lifecycleLog = log.map(SessionLifecycleLog.init)
            self.watchPhase = session.state == .running ? .running : .spawning
        }
    }

    public init(paths: AppPaths, runtimes: any LaunchRuntimeProviding, prefixes: any LaunchPrefixProviding,
        preparation: any LaunchPreparing, spawner: any ProcessSpawner, inspector: any ProcessInspector,
        runner: any ProcessRunner, clock: any Clock<Duration>, log: EventLog? = nil, displayProbe: any DisplayProbe = SystemDisplayProbe(), gameMode: (any GameModeProviding)? = nil) {
        self.gameMode = gameMode ?? GameModeHelper(paths: paths)
        self.eventLog = log ?? EventLog(directory: paths.logs)
        self.sessionLogWriter = Self.makeSessionLogWriter(beforeWrite: {})
        self.paths = paths; self.runtimes = runtimes; self.prefixes = prefixes; self.preparation = preparation
        self.spawner = spawner; self.inspector = inspector; self.runner = runner; self.clock = clock; self.displayProbe = displayProbe
        self.baseEnvironment = ProcessInfo.processInfo.environment; self.journalFileOps = SystemFileOps()
        self.recipeOverrides = [:]
        self.hideHooks = .none; self.beforeJournalRead = {}; self.beforeRecoveryRead = {}
        self.sessionProvenance = Self.currentSessionProvenance
        self.proxyFactory = { hosts, log in try await SessionProxy.start(blockedHosts: hosts, log: log) }
    }

    package init(paths: AppPaths, runtimes: any LaunchRuntimeProviding, prefixes: any LaunchPrefixProviding,
        preparation: any LaunchPreparing, spawner: any ProcessSpawner, inspector: any ProcessInspector,
        runner: any ProcessRunner, clock: any Clock<Duration>, log: EventLog? = nil, displayProbe: any DisplayProbe = FixedDisplayProbe(), gameMode: (any GameModeProviding)? = nil,
        proxyFactory: @escaping ProxyFactory,
        baseEnvironment: [String: String] = [:], journalFileOps: any FileOps = SystemFileOps(),
        hideHooks: LaunchFileHooks = .none, beforeJournalRead: @escaping @Sendable () throws -> Void = {},
        beforeRecoveryRead: @escaping @Sendable () async throws -> Void = {},
        recipeOverrides: [String: LaunchRecipe] = [:],
        sessionProvenance: @escaping @Sendable () throws -> (bootSessionUUID: String, sessionStartTime: UInt64) = LaunchManager.currentSessionProvenance,
        beforeSessionLogWrite: @escaping @Sendable () throws -> Void = {}) {
        self.gameMode = gameMode
        self.eventLog = log ?? EventLog(directory: paths.logs)
        self.sessionLogWriter = Self.makeSessionLogWriter(beforeWrite: beforeSessionLogWrite)
        self.paths = paths; self.runtimes = runtimes; self.prefixes = prefixes; self.preparation = preparation
        self.spawner = spawner; self.inspector = inspector; self.runner = runner; self.clock = clock; self.displayProbe = displayProbe
        self.proxyFactory = proxyFactory; self.baseEnvironment = baseEnvironment; self.journalFileOps = journalFileOps
        self.recipeOverrides = recipeOverrides
        self.hideHooks = hideHooks; self.beforeJournalRead = beforeJournalRead; self.beforeRecoveryRead = beforeRecoveryRead
        self.sessionProvenance = sessionProvenance
    }

    private enum SessionLogWork: Sendable {
        case line(SessionLifecycleLog, String), cap(SessionLifecycleLog), finish(SessionLifecycleLog)
        func write() {
            switch self {
            case .line(let log, let line): log.append(line: line)
            case .cap(let log): log.cap()
            case .finish(let log): log.finish()
            }
        }
    }
    private nonisolated static func makeSessionLogWriter(beforeWrite: @escaping @Sendable () throws -> Void) -> BestEffortLogWriter<SessionLogWork> {
        BestEffortLogWriter(maxPendingBytes: 128 << 10) { work in try beforeWrite(); work.write() }
    }
    /// Explicit test barrier; supervision only ever posts to these writers.
    package func flushLogs() async {
        await sessionLogWriter.drain()
        await eventLog.flush()
    }

    package nonisolated static func currentSessionProvenance() throws -> (bootSessionUUID: String, sessionStartTime: UInt64) {
        // Called on BlockingIO before the first durable snapshot and spawn.
        (try SystemProcessInspector.bootSessionUUID(), UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }

    public func launch(game: GameDefinition, installRoot: URL, gameBuild: String) -> AsyncStream<LaunchEvent> {
        let pair = AsyncStream<LaunchEvent>.makeStream()
        // Reserve synchronously, before an actor reentrancy point or any I/O.
        if let busy = reservedGame ?? contexts.keys.sorted().first ?? supervision.keys.sorted().first ?? unresolvedStartup.sorted().first {
            event("Launch failed", game: game.id, level: .error, metadata: Self.failureMetadata(LauncherError.busy("Launch slot unavailable"), stage: .lock))
            pair.continuation.yield(.stage(.lock))
            pair.continuation.yield(.failed(LaunchFailure(stage: .lock, message: String(localized: "\(Self.name(busy)) is running"), logURL: nil,
                unverifiedBuild: !((recipeOverrides[game.id] ?? Recipes.recipe(for: game.id))?.verifiedBuilds.contains(gameBuild) ?? false))))
            pair.continuation.finish(); return pair.stream
        }
        if recovering || !guardRecoveries.isEmpty {
            event("Launch failed", game: game.id, level: .error, metadata: Self.failureMetadata(LauncherError.busy("Launch slot unavailable"), stage: .lock))
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

    /// Atomic process/recovery observation for clients without an event stream.
    /// An absent context alone is not completion: startup may have been unable to
    /// read or acquire a journal. Confirm its absence before releasing UI ownership.
    public func sessionObservation(for game: String) async throws -> (session: LaunchSession, hasEnded: Bool)? {
        if let context = contexts[game] { return (context.session, context.hasEnded) }
        let snapshot = try await read(game: game)
        if let context = contexts[game] { return (context.session, context.hasEnded) }
        guard snapshot == nil else { throw LauncherError.busy("Launch recovery is required") }
        unresolvedStartup.remove(game)
        return nil
    }

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
        guard let context = contexts[game], context.session.state == .running, !context.hasEnded, !context.ready else { return }
        context.ready = true
        context.continuation?.yield(.ready)
        note(context, "game window ready")
    }

    private func start(game: GameDefinition, installRoot: URL, gameBuild: String, events: AsyncStream<LaunchEvent>.Continuation) async {
        defer { finishedSupervision(game: game.id) }
        var stage = LaunchStage.preflight
        let unverified = !((recipeOverrides[game.id] ?? Recipes.recipe(for: game.id))?.verifiedBuilds.contains(gameBuild) ?? false)
        do {
            events.yield(.stage(stage))
            guard let recipe = (recipeOverrides[game.id] ?? Recipes.recipe(for: game.id)) else { throw LauncherError.io("Unknown launch game") }
            let paths = paths, journalFileOps = journalFileOps
            let (settings, globalSettings) = try await BlockingIO.run {
                let settings = try LaunchSettingsStore(paths: paths).load(game.id)
                let global = try GlobalLaunchSettingsStore(paths: paths).load()
                return (settings, global)
            }
            let logsEnabled = globalSettings.sessionLogsEnabled
            event("Launch started", game: game.id, metadata: ["backend": settings.backend.rawValue,
                "buildVerification": unverified ? "unverified" : "verified"])
            let identity = try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: installRoot).pinRoot()
                guard try fs.itemType(at: recipe.executable) == .regularFile else { throw LauncherError.io("Game executable is missing") }
                return try fs.rootIdentity()
            }
            let selection = try await runtimes.selection(for: settings)
            let bundle = selection.bundle
            let prefix = try await prefixes.prefixURL(game: game.id, bundle: bundle)
            let requiredComponents = LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: bundle.id.rawValue)
            guard !selection.componentIDs.isEmpty else { throw LauncherError.io("The runtime bundle has no pinnable components") }
            let compatibilityIDs = try requiredComponents.map { kind in
                guard let id = selection.compatibilityComponentIDs[kind] else { throw LauncherError.io("Required compatibility component has no pin identity") }
                return id
            }
            let ids = Array(Set(selection.componentIDs + compatibilityIDs)).sorted()
            var helper: GameModeRuntime?
            if globalSettings.gameModeEnabled, let gameMode {
                do { helper = try await gameMode.prepare(bundle: bundle, componentIDs: ids) }
                catch {
                    event("Game Mode unavailable; using normal Wine", game: game.id, metadata: ["reason": "helperPreparationFailed"])
                }
            } else {
                event("Game Mode skipped; using normal Wine", game: game.id,
                    metadata: ["reason": globalSettings.gameModeEnabled ? "helperUnavailable" : "disabled"])
            }
            var previewChoice = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: installRoot, prefix: prefix,
                wineBinary: bundle.wineBinary, proxyPort: 0, componentRoots: selection.componentRoots, baseEnvironment: baseEnvironment,
                runtimeBundleID: bundle.id.rawValue, displays: displayProbe.connectedDisplays().map(\.id), gameModeRuntime: helper)
            stage = .lock; events.yield(.stage(stage))
            let (lock, pin) = try await BlockingIO.run {
                let lock = try SessionLock.acquire(paths: paths, game: game.id)
                let pin = try RuntimePin.pin(paths: paths, componentIDs: ids)
                return (lock, pin)
            }
            let validated = try await runtimes.selection(for: settings)
            guard validated.bundle == bundle,
                Set(validated.componentIDs) == Set(selection.componentIDs),
                requiredComponents.allSatisfy({ validated.componentRoots[$0] == selection.componentRoots[$0]
                    && validated.compatibilityComponentIDs[$0] == selection.compatibilityComponentIDs[$0] }) else {
                throw LauncherError.io("The selected runtime changed before it could be pinned")
            }
            if let candidate = helper, let gameMode {
                do {
                    try await gameMode.validate(candidate, bundle: bundle)
                    event("Game Mode helper selected", game: game.id)
                } catch {
                    helper = nil
                    previewChoice = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: installRoot, prefix: prefix,
                        wineBinary: bundle.wineBinary, proxyPort: 0, componentRoots: selection.componentRoots, baseEnvironment: baseEnvironment,
                        runtimeBundleID: bundle.id.rawValue)
                    event("Game Mode unavailable; using normal Wine", game: game.id, metadata: ["reason": "helperValidationFailed"])
                }
            }
            let preview = previewChoice
            guard try await read(game: game.id) == nil else { throw LauncherError.busy("Launch recovery is required") }
            let provenance = sessionProvenance
            let (bootSessionUUID, sessionStartTime) = try await BlockingIO.run { try provenance() }
            let session = LaunchSession(sessionID: UUID(), game: game.id, installRoot: installRoot, installIdentity: identity,
                prefix: prefix, bundleID: bundle.id.rawValue, runtimeDigest: bundle.digest, wineBinary: helper?.wineBinary ?? bundle.wineBinary,
                wineserver: helper?.wineserver ?? bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"), componentIDs: ids,
                recipeVersion: recipe.recipeVersion, settings: settings, gameExecutable: recipe.executable,
                bootSessionUUID: bootSessionUUID, sessionStartTime: sessionStartTime)
            let context = Context(session: session, lock: lock, pin: pin)
            context.endOutcome = "startup failure"
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
                context.lifecycleLog = context.log.map(SessionLifecycleLog.init)
            }
            note(context, "stage snapshot")
            context.session.sessionLogURL = context.log?.url
            try await persist(context.session)
            stage = .prepare; events.yield(.stage(stage)); note(context, "stage prepare")
            let initialized = try await prefixes.createPrefix(game: game.id, bundle: bundle)
            guard initialized.standardizedFileURL == prefix.standardizedFileURL else { throw LauncherError.io("Prefix changed during preparation") }
            let prepared = try await preparation.ensure(prefix: prefix, wineBinary: bundle.wineBinary, request: preview.preparation)
            if let frameRate = prepared.starRailFrameRate, frameRate == .missing || frameRate == .unreadable {
                events.yield(.note(.starRailSettingsMissing))
                let reason = frameRate == .missing ? "missing" : "unreadable"
                note(context, "Star Rail frame-rate setting " + reason)
                event("Star Rail frame-rate setting is unavailable", game: game.id, metadata: ["reason": reason])
            }
            let original = context.session, log = context.log, hideHooks = hideHooks, beforeJournalRead = beforeJournalRead
            let (hiddenSnapshot, hideResult) = try await BlockingIO.run {
                var snapshot = original
                try LaunchCopies.copyIfPresent(preview.copyIfPresent, installRoot: installRoot,
                    system32: prefix.appendingPathComponent("drive_c/windows/system32"), log: log)
                for copy in preview.componentCopies {
                    try LaunchCopies.copyRequired([(copy.source, copy.toSystem32)], componentRoot: copy.root,
                        system32: prefix.appendingPathComponent("drive_c/windows/system32"), log: log)
                }
                let result = Result { try HiddenFiles(hooks: hideHooks).hide(preview.hidden, session: &snapshot,
                    journal: LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead)) }
                return (snapshot, result)
            }
            // inout progress survives errors, including a rename followed by a
            // failed done write. The on-disk journal remains authoritative.
            context.session = hiddenSnapshot
            note(context, "files hidden: \(hiddenSnapshot.hides.filter { $0.status == .done }.count)")
            try hideResult.get()
            stage = .proxy; events.yield(.stage(stage)); note(context, "stage proxy")
            let sessionLogWriter = sessionLogWriter, lifecycleLog = context.lifecycleLog
            let logger: @Sendable (String) -> Void = {
                if logsEnabled, let lifecycleLog { sessionLogWriter.post(.line(lifecycleLog, $0), bytes: $0.utf8.count) }
            }
            context.proxy = try await proxyFactory(preview.blockedHosts, logger)
            context.session.proxyPort = context.proxy?.port
            let displays = displayProbe.connectedDisplays().map(\.id)
            let resolved = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: installRoot, prefix: prefix,
                wineBinary: bundle.wineBinary, proxyPort: context.proxy!.port, componentRoots: selection.componentRoots, baseEnvironment: baseEnvironment, runtimeBundleID: bundle.id.rawValue, displays: displays, gameModeRuntime: helper)
            if !displays.isEmpty {
                let selection = resolved.displayFallback ? "fallback" : (settings.display == nil ? "main" : "chosen")
                note(context, "display=\(selection)")
                event("Display selected", game: game.id, metadata: ["display": selection])
            }
            stage = .spawn; events.yield(.stage(stage)); note(context, "stage spawn")
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
            stage = .watch; events.yield(.stage(stage)); note(context, "stage watch")
            await watch(game: game.id, executable: recipe.executable.components.last!)
            return
        } catch {
            event("Launch failed", game: game.id, level: .error, metadata: Self.failureMetadata(error, stage: stage))
            if let context = contexts[game.id] {
                // hide() may have durably recorded more entries before throwing.
                if let persisted = try? await read(game: game.id), persisted.sessionID == context.session.sessionID { context.session = persisted }
                if let owned = context.ownedWrapper {
                    if !context.session.processes.contains(owned) { context.session.processes.append(owned) }
                    context.session.processGroupIDs = (context.session.processGroupIDs ?? []).union([owned.pid])
                }
                noteFailure(error, stage: stage, context: context)
                if context.ownedWrapper != nil, let executable = Self.executable(context.session) {
                    // A successful spawn is irreversible: retain ownership and
                    // defer its failure report until verified end and restore.
                    context.deferredFailure = Self.failure(error, stage: stage, log: context.lifecycleLog?.url, unverified: unverified)
                    await pending(context, reason: "Process state could not be confirmed")
                    await watch(game: game.id, executable: executable)
                } else {
                    context.hasEnded = true
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
                context.hasEnded = true
                context.endOutcome = context.ready ? "normal" : "before ready"
                context.session.state = .ending; try await persist(context.session)
                context.continuation?.yield(.ended(normal: context.ready))
                if !context.ready { noteFailure(LauncherError.io("The game ended before a window appeared"), stage: .watch, context: context) }
                await stopProxy(context)
                _ = await restore(context)
                if let failure = context.deferredFailure {
                    context.continuation?.yield(.stage(.report)); context.continuation?.yield(.failed(failure)); context.continuation?.finish()
                } else if !context.ready {
                    report(LauncherError.io("The game ended before a window appeared"), stage: .watch, context: context, unverified: context.unverifiedBuild)
                } else { context.continuation?.yield(.stage(.report)); context.continuation?.finish() }
                return
            } catch SessionWatchError.startup {
                context.hasEnded = true
                context.endOutcome = "startup failure"
                noteFailure(LauncherError.io("The game did not start"), stage: .watch, context: context)
                context.continuation?.yield(.ended(normal: false)); await stopProxy(context)
                _ = await restore(context)
                if let failure = context.deferredFailure {
                    context.continuation?.yield(.stage(.report)); context.continuation?.yield(.failed(failure)); context.continuation?.finish()
                } else { report(LauncherError.io("The game did not start"), stage: .watch, context: context, unverified: context.unverifiedBuild) }
                return
            } catch {
                // A failed write or incomplete scan cannot authorize restoration or
                // disconnect a potentially live game from its session proxy.
                note(context, "watch retry: process state unknown")
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
        context.session.startupPending = false
        context.session.state = .running
        context.session.processes = Array(Set(context.session.processes + processes)).sorted { $0.pid < $1.pid }
        try await persist(context.session)
        if !context.runningAnnounced, let process = processes.sorted(by: { $0.pid < $1.pid }).first {
            context.runningAnnounced = true
            note(context, "game process detected: pid \(process.pid)")
            event("Game running", game: game, metadata: ["pid": String(process.pid)])
            context.continuation?.yield(.running)
        }
    }

    private func restore(_ context: Context) async -> RestoreOutcome {
        do { try await verifiedEnd(context) }
        catch {
            await pending(context, reason: "Launch recovery could not finish")
            return .pending(reason: "Launch recovery could not finish")
        }
        context.restoreEntryCount = max(context.restoreEntryCount, context.session.hides.count)
        note(context, "stage restore")
        context.continuation?.yield(.stage(.restore))
        let paths = paths, journalFileOps = journalFileOps, beforeJournalRead = beforeJournalRead, hideHooks = hideHooks
        if context.finalization == nil {
            let original = context.session
            do {
                let (session, outcome) = try await BlockingIO.run {
                    var snapshot = original
                    let journal = LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead)
                    let outcome = try HiddenFiles(hooks: hideHooks).restore(session: &snapshot, journal: journal, retainResolvedJournal: true)
                    return (snapshot, outcome)
                }
                context.session = session
                if Self.resolved(outcome, session: session) {
                    context.finalization = (session, outcome)
                } else {
                    restored(context, outcome: outcome)
                    context.continuation?.yield(.restored(outcome))
                    // Recovery can produce more lifecycle lines on a later retry.
                    if let log = context.lifecycleLog { sessionLogWriter.post(.cap(log), bytes: 0) }
                    return outcome
                }
            } catch {
                let outcome = RestoreOutcome.pending(reason: "Launch recovery could not finish")
                restored(context, outcome: outcome)
                await pending(context, reason: "Launch recovery could not finish")
                return outcome
            }
        }
        guard let (session, outcome) = context.finalization else { preconditionFailure("Missing restore finalization") }
        do {
            try await BlockingIO.run {
                if case .conflict(let movedTo) = outcome {
                    try RecoveryNoticeStore(paths: paths).record(RecoveryNotice(id: session.sessionID, game: session.game,
                        movedTo: movedTo, recoveryRoot: session.recoveryLocation?.root))
                }
                // Publish notification first. Deletion always syncs the parent,
                // including a retry after unlink succeeded but its fsync failed.
                hideHooks.reach(.beforeJournalDelete)
                try LaunchJournal(paths: paths, fileOps: journalFileOps, sessionOwned: true, beforeRead: beforeJournalRead).delete(game: session.game)
                hideHooks.reach(.afterJournalDelete)
            }
        } catch {
            // Do not persist pending over a resolved journal, or discard our
            // completed snapshot when the journal has already been unlinked.
            context.session.state = .recoveryPending
            let outcome = RestoreOutcome.pending(reason: "Launch recovery could not finish")
            restored(context, outcome: outcome)
            context.continuation?.yield(.restored(outcome))
            return outcome
        }
        context.session = session
        context.finalization = nil
        restored(context, outcome: outcome)
        context.continuation?.yield(.restored(outcome))
        if let log = context.lifecycleLog { sessionLogWriter.post(.finish(log), bytes: 0) }
        if Self.resolved(outcome, session: session) {
            contexts[session.game] = nil
            if reservedGame == session.game && supervision[session.game] == nil { reservedGame = nil }
        }
        return outcome
    }

    private func event(_ message: String, game: String, level: EventLog.Level = .info, metadata: [String: String] = [:]) {
        var metadata = metadata
        metadata["game"] = Recipes.recipe(for: game) == nil ? "unknown" : game
        eventLog.post(level, "launch", message, metadata: metadata)
    }

    private func verifiedEnd(_ context: Context) async throws {
        guard context.hasEnded, context.session.endLogged != true else { return }
        var snapshot = context.session
        snapshot.endLogged = true
        snapshot.startupPending = false
        // Durable before enqueue: a crash may lose a best-effort line, but must
        // never produce another end notification on the next recovery attempt.
        try await persist(snapshot)
        context.session.endLogged = true
        let outcome = context.endOutcome
        note(context, outcome == "while MacGacha was closed"
            ? "Session ended while MacGacha was closed" : "session ended: \(outcome)")
        event("Session ended", game: context.session.game, metadata: ["outcome": outcome])
    }

    private func restored(_ context: Context, outcome: RestoreOutcome) {
        let name: String, conflicts: Int
        switch outcome {
        case .clean: name = "clean"; conflicts = 0
        case .pending: name = "pending"; conflicts = 0
        case .conflict(let movedTo): name = "conflict"; conflicts = movedTo.count
        }
        let remaining = context.session.hides.count
        let resolved = max(0, context.restoreEntryCount - remaining)
        note(context, "restore outcome: \(name) resolved=\(resolved) pending=\(remaining) conflicts=\(conflicts)")
        event("Restore outcome", game: context.session.game, metadata: ["outcome": name,
            "resolved": String(resolved), "pending": String(remaining), "conflicts": String(conflicts)])
    }

    private func note(_ context: Context, _ line: String) {
        guard let log = context.lifecycleLog else { return }
        sessionLogWriter.post(.line(log, line), bytes: line.utf8.count)
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
                persisted.startupPending = !context.hasEnded && context.watchPhase == .spawning
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
        if stage == .watch {
            event("Launch failed", game: context.session.game, level: .error, metadata: Self.failureMetadata(error, stage: stage))
        }
        context.continuation?.yield(.stage(.report))
        context.continuation?.yield(.failed(Self.failure(error, stage: stage, log: context.lifecycleLog?.url, unverified: unverified)))
        context.continuation?.finish(); context.continuation = nil
    }
    private static func failureMetadata(_ error: any Error, stage: LaunchStage) -> [String: String] {
        let failure = error as? LauncherError ?? (error is CancellationError ? .cancelled : .io(""))
        var fields = ["stage": stage.rawValue, "case": failure.logCase]
        fields["reason"] = failure.logReason
        return fields
    }
    private func noteFailure(_ error: any Error, stage: LaunchStage, context: Context) {
        let fields = Self.failureMetadata(error, stage: stage)
        note(context, "failed \(stage.rawValue) case=\(fields["case", default: "io"])" + (fields["reason"].map { " reason=\($0)" } ?? ""))
    }
    private static func failure(_ error: any Error, stage: LaunchStage, log: URL?, unverified: Bool) -> LaunchFailure {
        LaunchFailure(stage: stage, message: String(localized: "Launch failed during \(stage.rawValue)."), logURL: log, unverifiedBuild: unverified)
    }
    private static func name(_ game: String) -> String {
        GameDefinition.find(game)?.defaultInstallDirectoryName ?? "A game"
    }

    /// Startup recovery reads only durable snapshots. No proxy is recreated:
    /// surviving games keep the old, unavailable proxy endpoint (Option A).
    public func reattachAll() async -> [String: LaunchSession] {
        await reattachAll(recoveryGame: nil)
    }

    public func reattachStartup() async -> LaunchStartupResult {
        let sessions = await reattachAll()
        return LaunchStartupResult(sessions: sessions, unresolved: unresolvedStartup)
    }

    private func reattachAll(recoveryGame: String?) async -> [String: LaunchSession] {
        guard !recovering else { return contexts.mapValues(\.session) }
        recovering = true
        defer { recovering = false }
        for game in Recipes.games where contexts[game] == nil && (!guardRecoveries.contains(game) || recoveryGame == game) {
            do {
                guard try await read(game: game) != nil else { unresolvedStartup.remove(game); continue }
                let paths = paths, journalFileOps = journalFileOps, beforeJournalRead = beforeJournalRead
                let owned = try await BlockingIO.run { () throws -> (LaunchSession, SessionLock, RuntimePin)? in
                    let lock = try SessionLock.acquire(paths: paths, game: game)
                    // Discovery precedes exclusion. Another launcher may have
                    // finalized or replaced that journal while we awaited it.
                    let journal = LaunchJournal(paths: paths, fileOps: journalFileOps, beforeRead: beforeJournalRead)
                    guard let current = try journal.read(game: game) else { return nil }
                    let pin = try RuntimePin.pin(paths: paths, componentIDs: current.componentIDs)
                    return (current, lock, pin)
                }
                guard let (snapshot, lock, pin) = owned else { unresolvedStartup.remove(game); continue }
                let context = Context(session: snapshot, lock: lock, pin: pin)
                contexts[game] = context
                unresolvedStartup.remove(game)
                if let url = snapshot.sessionLogURL,
                    url.deletingLastPathComponent().standardizedFileURL == paths.logs.standardizedFileURL,
                    LaunchLogFiles.parseName(url.lastPathComponent)?.game == game {
                    let log = SessionLifecycleLog(recovering: url, ticker: ClockSessionLogTicker(clock: clock))
                    context.lifecycleLog = log
                    sessionLogWriter.post(.cap(log), bytes: 0)
                }
                do {
                    // Spawning without identities may precede a delayed Wine
                    // wrapper. Only startup's complete absence grace can end it.
                    let present = try await alive(snapshot)
                    let starting = snapshot.state == .spawning || snapshot.startupPending == true || present
                    if starting {
                        guard let executable = Self.executable(snapshot) else {
                            await pending(context, reason: "The snapshot's executable could not be confirmed"); continue
                        }
                        let task = Task {
                            await self.watch(game: game, executable: executable)
                            self.finishedSupervision(game: game)
                        }
                        context.worker = task; supervision[game] = task
                    } else { context.hasEnded = true; _ = await restore(context) }
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
            } catch { unresolvedStartup.insert(game) }
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
            // Any prefix-matching helper can still start the game after a crash
            // before the wrapper identity was journaled.
            return !processes.isEmpty
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
            unresolvedStartup.remove(game)
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
            context.hasEnded = true
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
