// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

/// Advances only when the test acknowledges a registered sleep. No wall-clock pacing.
final class ManagerClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        let offset: Duration
        func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    private struct State {
        var now: Duration = .zero
        var sleeps = 0
        var sleepers: [UUID: (Instant, CheckedContinuation<Void, any Error>)] = [:]
        var durationCounts: [Duration: Int] = [:]
        var observers: [(Int, Duration?, CheckedContinuation<Void, Never>)] = []
    }
    private let state = Mutex(State())
    var now: Instant { state.withLock { Instant(offset: $0.now) } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleepCount: Int { state.withLock { $0.sleeps } }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) = state.withLock { state in
                    if Task.isCancelled { return (.failure(CancellationError()), []) }
                    if deadline.offset <= state.now { return (.success(()), []) }
                    state.sleeps += 1
                    let duration = deadline.offset - state.now
                    state.durationCounts[duration, default: 0] += 1
                    state.sleepers[id] = (deadline, continuation)
                    let ready = state.observers.filter { $0.0 <= ($0.1.map { state.durationCounts[$0, default: 0] } ?? state.sleeps) }.map(\.2)
                    state.observers.removeAll { $0.0 <= ($0.1.map { state.durationCounts[$0, default: 0] } ?? state.sleeps) }
                    return (nil, ready)
                }
                result.1.forEach { $0.resume() }
                if let completed = result.0 { continuation.resume(with: completed) }
            }
        } onCancel: {
            self.state.withLock { $0.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func waitForSleep(_ count: Int, duration: Duration? = nil) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if (duration.map { state.durationCounts[$0, default: 0] } ?? state.sleeps) >= count { return true }
                state.observers.append((count, duration, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now += duration
            let ready = state.sleepers.filter { $0.value.0.offset <= state.now }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.1)
        }
        ready.forEach { $0.resume() }
    }
}

final class ManagerInspector: ProcessInspector, Sendable {
    struct State {
        var processes: [InspectedProcess] = []
        var alive: Set<ProcessIdentity> = []
        var failure = false
        var failuresRemaining = 0
        var prefixes: [String] = []
        var scopes: [ProcessInspectionScope] = []
    }
    private let state = Mutex(State())
    var values: State { state.withLock { $0 } }
    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    func isAlive(_ id: ProcessIdentity) -> Bool { state.withLock { $0.alive.contains(id) } }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] {
        try state.withLock { state in
            state.prefixes.append(value)
            state.scopes.append(scope)
            if state.failure || state.failuresRemaining > 0 {
                state.failuresRemaining = max(0, state.failuresRemaining - 1)
                throw LauncherError.io("injected process inspection failure")
            }
            return state.processes
        }
    }
}

final class ManagerSpawner: ProcessSpawner, Sendable {
    struct Call: Sendable { let executable: URL; let outputDiscarded: Bool; let environment: [String: String]; let arguments: [String] }
    private struct State { var calls: [Call] = []; var failure: LauncherError?; var afterSpawn: (@Sendable () throws -> Void)? }
    private let state = Mutex(State())
    let identity = ProcessIdentity(pid: 12345, startTime: 100)
    var calls: [Call] { state.withLock { $0.calls } }
    func fail(_ error: LauncherError = .io("injected spawn failure")) { state.withLock { $0.failure = error } }
    func afterSpawn(_ action: @escaping @Sendable () throws -> Void) { state.withLock { $0.afterSpawn = action } }
    func spawn(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL, output: ProcessOutput) throws -> ProcessIdentity {
        let action = try state.withLock { state in
            state.calls.append(Call(executable: executable, outputDiscarded: { if case .discard = output { true } else { false } }(), environment: environment, arguments: arguments))
            if let failure = state.failure { throw failure }
            return state.afterSpawn
        }
        try action?()
        return identity
    }
}

struct ManagerRunner: ProcessRunner {
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

final class ManagerProxy: LaunchSessionProxy, Sendable {
    let port: UInt16 = 34567
    private struct State { var starts = 0; var stops = 0; var logged: [String] = [] }
    private let state = Mutex(State())
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var logged: [String] { state.withLock { $0.logged } }
    func start(log: @Sendable (String) -> Void) {
        state.withLock { $0.starts += 1 }
        log("globaldp-prod-os01.starrails.com:443 block")
    }
    func stop() async { state.withLock { $0.stops += 1 } }
}

struct ManagerRuntimeProvider: LaunchRuntimeProviding {
    let selected: LaunchRuntimeSelection
    func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection { selected }
}
struct ManagerPrefixProvider: LaunchPrefixProviding {
    let prefix: URL
    func prefixURL(game: String, bundle: InstalledRuntimeBundle) async throws -> URL { prefix }
    func createPrefix(game: String, bundle: InstalledRuntimeBundle) async throws -> URL { prefix }
}
final class ManagerPreparation: LaunchPreparing, Sendable {
    private let failure = Mutex<LauncherError?>(nil)
    func fail(_ error: LauncherError = .io("injected preparation failure")) { failure.withLock { $0 = error } }
    func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }
}

actor ManagerEvents {
    private(set) var values: [LaunchEvent] = []
    private var waiters: [(@Sendable (LaunchEvent) -> Bool, CheckedContinuation<Void, Never>)] = []
    func append(_ event: LaunchEvent) {
        values.append(event)
        let ready = waiters.filter { $0.0(event) }.map(\.1)
        waiters.removeAll { $0.0(event) }
        ready.forEach { $0.resume() }
    }
    func wait(for predicate: @escaping @Sendable (LaunchEvent) -> Bool) async {
        if values.contains(where: predicate) { return }
        await withCheckedContinuation { waiters.append((predicate, $0)) }
    }
    func waitForRunning() async { await wait { if case .running = $0 { true } else { false } } }
    func waitForReady() async { await wait { if case .ready = $0 { true } else { false } } }
}

final class ManagerFixture: Sendable {
    static let bootSessionUUID = "D164F328-C268-4D08-B56C-547FA90745CA"
    static let sessionStartTime: UInt64 = 1_700_000_000_000_000
    let temp: ManagerTemporaryDirectory
    let paths: AppPaths
    let installRoot: URL
    let prefix: URL
    let bundle: InstalledRuntimeBundle
    let runtime: ManagerRuntimeProvider
    let prefixes: ManagerPrefixProvider
    let preparation = ManagerPreparation()
    let spawner = ManagerSpawner()
    let inspector = ManagerInspector()
    let runner = ManagerRunner()
    let clock = ManagerClock()
    let proxy = ManagerProxy()
    let journalOps = ManagerJournalFileOps()
    let gameProcess = InspectedProcess(identity: ProcessIdentity(pid: 23456, startTime: 200), executablePath: "/wine/StarRail.exe", arguments: [])
    let serverProcess = InspectedProcess(identity: ProcessIdentity(pid: 23457, startTime: 200), executablePath: "/bundle/bin/wineserver", arguments: [])
    let game = GameDefinition.all.first { $0.id == "starrail" }!
    let hiddenPath = try! SafeRelativePath("StarRail_Data/Plugins/x86_64/vulkan-1.dll")
    let original = Data("original dll".utf8)

    static func make(logsEnabled: Bool = true, initialGame: Bool = true) async throws -> ManagerFixture {
        try await BlockingIO.run { try ManagerFixture(logsEnabled: logsEnabled, initialGame: initialGame) }
    }
    private init(logsEnabled: Bool, initialGame: Bool) throws {
        temp = try ManagerTemporaryDirectory(); paths = AppPaths(root: temp.url.appendingPathComponent("store"))
        installRoot = temp.url.appendingPathComponent("game"); prefix = paths.prefixes.appendingPathComponent("starrail/bundle-a")
        let root = paths.runtimes.appendingPathComponent("bundles/bundle-a")
        bundle = InstalledRuntimeBundle(id: try SafeIdentifier("bundle-a"), root: root, wineBinary: root.appendingPathComponent("bin/wine"), digest: testDigest(Data()), source: .download)
        let fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("game"))
        try fs.createDirectory(at: SafeRelativePath("store/Prefixes/starrail/bundle-a/drive_c/windows/system32"))
        try fs.createDirectory(at: SafeRelativePath("store/Runtimes/bundles/bundle-a/bin"))
        try fs.createDirectory(at: SafeRelativePath("store/Runtimes/jadeite"))
        try fs.writeAtomically(original, to: SafeRelativePath("game/\(hiddenPath)"))
        try fs.writeAtomically(Data("game".utf8), to: SafeRelativePath("game/StarRail.exe"))
        try GlobalLaunchSettingsStore(paths: paths).save(GlobalLaunchSettings(sessionLogsEnabled: logsEnabled))
        runtime = ManagerRuntimeProvider(selected: LaunchRuntimeSelection(bundle: bundle, componentIDs: ["wine-a", "dxmt-a", "jadeite-a"], componentRoots: [.jadeite: paths.runtimes.appendingPathComponent("jadeite")], compatibilityComponentIDs: [.jadeite: "jadeite-a"]))
        prefixes = ManagerPrefixProvider(prefix: prefix)
        if initialGame { inspector.update { $0.processes = [gameProcess]; $0.alive = [gameProcess.identity] } }
    }
    func manager(hideHooks: LaunchFileHooks = .none, beforeJournalRead: @escaping @Sendable () throws -> Void = {},
        beforeRecoveryRead: @escaping @Sendable () async throws -> Void = {}, inspector overrideInspector: (any ProcessInspector)? = nil,
        log: EventLog? = nil, displayProbe: any DisplayProbe = FixedDisplayProbe(), gameMode: (any GameModeProviding)? = nil, beforeSessionLogWrite: @escaping @Sendable () throws -> Void = {}) -> LaunchManager {
        LaunchManager(paths: paths, runtimes: runtime, prefixes: prefixes, preparation: preparation,
            spawner: spawner, inspector: overrideInspector ?? inspector, runner: runner, clock: clock, log: log, displayProbe: displayProbe, gameMode: gameMode,
            proxyFactory: { [proxy] _, log in proxy.start(log: log); return proxy }, baseEnvironment: [:], journalFileOps: journalOps, hideHooks: hideHooks, beforeJournalRead: beforeJournalRead, beforeRecoveryRead: beforeRecoveryRead,
            sessionProvenance: { (Self.bootSessionUUID, Self.sessionStartTime) }, beforeSessionLogWrite: beforeSessionLogWrite)
    }
    func consume(_ manager: LaunchManager, events: ManagerEvents, build: String = "4.6.0") async -> Task<Void, Never> {
        let stream = await manager.launch(game: game, installRoot: installRoot, gameBuild: build)
        return Task { for await event in stream { await events.append(event) } }
    }
    func end(_ manager: LaunchManager) async throws {
        await clock.waitForSleep(1, duration: .seconds(3))
        inspector.update { $0.processes = []; $0.alive = [] }
        clock.advance(by: .seconds(3))
    }
    func journal() async throws -> LaunchSession? {
        try await BlockingIO.run { try LaunchJournal(paths: self.paths).read(game: "starrail") }
    }
    func assertOriginalRestored() async throws {
        try await BlockingIO.run {
            let bytes = try ContainedFileSystem(root: self.installRoot).readFile(at: self.hiddenPath, maxBytes: 100)
            #expect(bytes == self.original)
        }
    }
}

final class ManagerTemporaryDirectory: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ContainedFileSystem(root: url).createRootDurably()
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

extension ManagerFixture {
    func saveSnapshot(state: LaunchSession.State, processes: [ProcessIdentity], backend: RuntimeBackend = .d3dmetal, sessionLogURL: URL? = nil, gameExecutable: SafeRelativePath? = nil, processGroupIDs: Set<Int32>? = nil) async throws -> LaunchSession {
        try await BlockingIO.run {
            let settings = LaunchSettings(backend: backend, retina: false, frameLimit: 60, directX12: false, compatibilityPatches: true)
            var snapshot = LaunchSession(sessionID: UUID(), game: "starrail", installRoot: self.installRoot,
                installIdentity: try ContainedFileSystem(root: self.installRoot).rootIdentity(), prefix: self.prefix,
                bundleID: self.bundle.id.rawValue, runtimeDigest: self.bundle.digest, wineBinary: self.bundle.wineBinary,
                wineserver: self.bundle.wineBinary.deletingLastPathComponent().appendingPathComponent("wineserver"),
                componentIDs: self.runtime.selected.componentIDs, recipeVersion: 1, settings: settings, sessionLogURL: sessionLogURL, gameExecutable: gameExecutable,
                bootSessionUUID: Self.bootSessionUUID, sessionStartTime: Self.sessionStartTime)
            let journal = LaunchJournal(paths: self.paths)
            try journal.write(snapshot)
            try HiddenFiles().hide([self.hiddenPath], session: &snapshot, journal: journal)
            snapshot.state = state; snapshot.processes = processes; snapshot.processGroupIDs = processGroupIDs
            try journal.write(snapshot)
            return snapshot
        }
    }
    func assertHidden() async throws {
        let snapshot = try #require(try await journal())
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: self.installRoot)
            #expect(try fs.itemType(at: self.hiddenPath) == nil)
            let entry = try #require(snapshot.hides.first)
            #expect(try fs.readFile(at: snapshot.hiddenPath(entry), maxBytes: 100) == self.original)
        }
    }
    func assertLocksHeld() async throws {
        try await BlockingIO.run {
            #expect(throws: LauncherError.self) { try SessionLock.acquire(paths: self.paths, game: "starrail") }
            let fs = try ContainedFileSystem(root: self.paths.root)
            for component in self.runtime.selected.componentIDs {
                #expect(throws: LauncherError.self) { try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\(component).lock")) }
            }
        }
    }
    func waitForRestore(_ manager: LaunchManager) async {
        await manager.waitForSupervision(game: "starrail")
    }
}

final class ManagerJournalFileOps: FileOps, Sendable {
    private let failNext = Mutex(false)
    private let failNextDelete = Mutex(false)
    private struct DeletionSync {
        var armed = false
        var parent: (device: dev_t, inode: ino_t)?
        var failures = 0
        var successes = 0
    }
    private let deletionSync = Mutex(DeletionSync())
    func armDeletionSync() { deletionSync.withLock { $0.armed = true } }
    func allowDeletionSync() { deletionSync.withLock { $0.armed = false } }
    var deletionSyncFailures: Int { deletionSync.withLock { $0.failures } }
    var deletionSyncSuccesses: Int { deletionSync.withLock { $0.successes } }
    func arm() { failNext.withLock { $0 = true } }
    func armDelete() { failNextDelete.withLock { $0 = true } }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var info = stat()
        let readable = fstat(descriptor, &info) == 0
        let fail = deletionSync.withLock { state in
            guard readable, let parent = state.parent,
                parent.device == info.st_dev, parent.inode == info.st_ino else { return false }
            if state.armed { state.failures += 1; return true }
            state.successes += 1
            return false
        }
        if fail { throw LauncherError.io("injected post-unlink journal directory synchronization failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if destination == "launch-session.json", failNext.withLock({ let value = $0; $0 = false; return value }) {
            throw LauncherError.io("injected launch journal publication failure")
        }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if name == "launch-session.json", failNextDelete.withLock({ let value = $0; $0 = false; return value }) {
            throw LauncherError.io("injected launch journal deletion failure")
        }
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
        if name == "launch-session.json" {
            var info = stat()
            if fstat(directory, &info) == 0 {
                deletionSync.withLock { $0.parent = (info.st_dev, info.st_ino) }
            }
        }
    }
}

struct ManagerNoopLogTicker: SessionLogTicker {
    func start(_ action: @escaping @Sendable () -> Void) -> LogTickCancellation { LogTickCancellation {} }
}

final class ManagerReadFailures: Sendable {
    private let remaining = Mutex(0)
    func arm(_ count: Int) { remaining.withLock { $0 = count } }
    func read() throws {
        let fail = remaining.withLock { value in
            guard value > 0 else { return false }; value -= 1; return true
        }
        if fail { throw LauncherError.io("injected unreadable journal") }
    }
}

/// Suspends an async recovery read without occupying a cooperative worker.
final class ManagerRecoveryReadGate: Sendable {
    let entered = TestEvent()
    let released = TestEvent()
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    func read() async throws {
        let first = count.withLock { $0 += 1; return $0 == 1 }
        if first { entered.signal(); try await released.wait() }
    }
}

final class ManagerDisplayProbe: DisplayProbe, Sendable {
    private let state: Mutex<(lists: [[ConnectedDisplay]], calls: Int)>
    init(_ lists: [[ConnectedDisplay]]) { state = Mutex((lists, 0)) }
    var calls: Int { state.withLock { $0.calls } }
    func connectedDisplays() -> [ConnectedDisplay] {
        state.withLock { state in
            let index = min(state.calls, state.lists.count - 1)
            state.calls += 1
            return index >= 0 ? state.lists[index] : []
        }
    }
}
