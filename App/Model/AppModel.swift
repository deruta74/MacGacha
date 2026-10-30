// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Launch
import Foundation
import Observation
import LauncherCore
import DownloadEngine
import RuntimeManager
import HoYoPlayAPI
import GameLibrary

@MainActor @Observable
final class AppModel {
    enum ConsentMode: Sendable, Equatable { case download, importGPTK }
    struct ConsentRequest: Identifiable, Equatable {
        let id: String
        let mode: ConsentMode
        let title: String
        let body: String
        let termsURL: URL
    }
    enum ImportState: Equatable { case searching, choose([GPTKCandidate]), notFound }
    enum RowState: Equatable {
        case notInstalled
        case working(phase: OperationPhase, fraction: Double?)
        case installed(source: SourceMode)
        case failed(message: String)
        case invalid(reason: String, removable: Bool)
    }
    struct RuntimeRow: Identifiable, Equatable {
        let id: String
        let kindName: String
        let version: String
        let licenseName: String
        var state: RowState
        let canImportGPTK: Bool
        let needsConsent: Bool
        /// Optional bundle summary and download size for bundles or standalone components.
        var summary: String? = nil
        var downloadSize: Int64? = nil
    }

    var region: Region {
        didSet {
            guard region != oldValue else { return }
            defaults?.set(region.rawValue, forKey: "region")
            updateArtReveal()
            revalidateGameEvents()
            if started && regionLoadingEnabled { loadRegion(region) }
        }
    }
    private(set) var games: [String: GameState] = Dictionary(uniqueKeysWithValues: GameDefinition.all.map { ($0.id, GameState(status: .unknown)) })
    private(set) var gameRecords: [String: GameRecord] = [:]
    var isGameOperationRunning: Bool { gameOperation != nil }
    private(set) var isRuntimeOperationRunning = false
    @ObservationIgnored let updater: any AppUpdating
    private(set) var launcherRevealed = false
    private(set) var artCacheStates: [Region: ArtCacheState] = [:]
    var artCacheState: ArtCacheState { artCacheStates[region] ?? .notChecked }
    @ObservationIgnored let artClock: any Clock<Duration>
    @ObservationIgnored var artStartupTask: Task<Void, Never>?
    @ObservationIgnored var artRevealTask: Task<Void, Never>?
    @ObservationIgnored var artStartupBegan = false
    @ObservationIgnored var artRefreshFinished: Set<Region> = []
    private(set) var gameArt: [String: GameArt]
    /// Activity posts for the visible region, keyed by the edition's game ID.
    private(set) var gameEvents: [String: [GameEvent]] = [:]
    @ObservationIgnored let eventsServices: [Region: any GameEventsProviding]
    @ObservationIgnored let eventsNow: @Sendable () -> Date
    @ObservationIgnored let eventsSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored var eventsSnapshots: [Region: [String: GameEventsSnapshot]] = [:]
    @ObservationIgnored var eventsHydrationTask: Task<Void, Never>?
    @ObservationIgnored var eventsTasks: [Region: Task<Void, Never>] = [:]
    @ObservationIgnored var eventsExpiryTask: Task<Void, Never>?
    @ObservationIgnored var eventsExpiryGeneration = UUID()
    @ObservationIgnored var eventsWindowTask: Task<Void, Never>?
    var connectedDisplays: [ConnectedDisplay] = []
    @ObservationIgnored let displayProbe: any DisplayProbe
    @ObservationIgnored let displayNames: @MainActor @Sendable () -> [String: String]
    @ObservationIgnored private var screenChangeObservation: ScreenChangeObservation?
    private(set) var rows: [RuntimeRow] = []
    private(set) var consentRequest: ConsentRequest?
    private(set) var importState: ImportState?
    private(set) var lastError: String?
    private(set) var logLines: [String] = []
    private(set) var isExporting = false
    private(set) var isStarting = true
    private(set) var installRoot: URL

    @ObservationIgnored let paths: AppPaths
    // Observed: the setup sheet can open before startup loads it and must refresh when it arrives.
    var manifest: RuntimeManifest?
    @ObservationIgnored private let services: any RuntimeServices
    @ObservationIgnored let artServices: [Region: any GameArtProviding]
    @ObservationIgnored var artHydrationTasks: [Region: Task<Void, Never>] = [:]
    @ObservationIgnored var artTasks: [Region: Task<Void, Never>] = [:]
    @ObservationIgnored var regionLoadTasks: [Region: Task<Void, Never>] = [:]
    @ObservationIgnored var regionLoadingEnabled = true
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let purgeableSpace: any PurgeableSpaceProbe
    @ObservationIgnored let gameServices: any GameServices
    @ObservationIgnored var gameTask: Task<Void, Never>?
    @ObservationIgnored var gameStartupTask: Task<Void, Never>?
    @ObservationIgnored var gameActivationTask: Task<Void, Never>?
    var gameOperation: GameOperationToken?
    @ObservationIgnored var gameProgress = GameProgress()
    @ObservationIgnored var gameLastRefresh: [Region: ContinuousClock.Instant] = [:]
    @ObservationIgnored var gameRefreshInFlight: Set<Region> = []
    @ObservationIgnored var gameRevisions: [String: UUID] = [:]
    @ObservationIgnored let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var working: [String: RowState] = [:]
    @ObservationIgnored private var errors: [String: String] = [:]
    @ObservationIgnored var installed: [InstalledComponent] = []
    private(set) var installedBundles: [String: InstalledRuntimeBundle] = [:]
    private(set) var rosetta: RosettaStatus = .unknown
    private(set) var rosettaInstallInProgress = false
    @ObservationIgnored let rosettaProbe: any RosettaProbing
    @ObservationIgnored let activationCenter: NotificationCenter
    @ObservationIgnored let rosettaClock: any Clock<Duration>
    @ObservationIgnored let rosettaPollInterval: Duration
    @ObservationIgnored let rosettaPollTimeout: Duration
    @ObservationIgnored let rosettaPrompt: @MainActor @Sendable () async throws -> Void
    @ObservationIgnored var rosettaRefreshTask: Task<Void, Never>?
    @ObservationIgnored var rosettaRefreshGeneration = UUID()
    @ObservationIgnored var rosettaPollTask: Task<Void, Never>?
    @ObservationIgnored var rosettaPollGeneration = UUID()
    @ObservationIgnored var rosettaInstallTask: Task<Void, Never>?
    @ObservationIgnored var rosettaPromptGeneration = UUID()
    @ObservationIgnored var rosettaHelperLaunchFailed = false
    @ObservationIgnored var runtimeSetupRosettaChecks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private(set) var runtimeSetupProgress: [String: RuntimeSetupProgress] = [:]
    var runtimeConsentAccepted: [String: Bool] = [:]
    @ObservationIgnored var runtimeConsentRevision = UUID()
    @ObservationIgnored var runtimeSetupChains: [String: RuntimeSetupChain] = [:]
    @ObservationIgnored var runtimeSetupOwnedItems: Set<String> = []
    @ObservationIgnored var runtimeSetupUpdateScheduled = false
    @ObservationIgnored private var importRuntimeBundle: RuntimeBundle?
    @ObservationIgnored private var invalid: [String: InvalidRuntimeEntry] = [:]
    @ObservationIgnored private var requestModes: [String: ConsentMode] = [:]
    @ObservationIgnored private var progressTimes: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var importComponent: RuntimeComponent?
    @ObservationIgnored private var extraRoots: [URL] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var scanGeneration = UUID()
    #if DEBUG
    var debugLaunchRuntimesReady = false
    #endif
    var launchSettingsRevisions: [String: UUID] = [:]
    var launchStates: [String: LaunchUIState] = [:]
    @ObservationIgnored var launchFailures: [String: LaunchFailureInfo] = [:]
    var recoveryNotices: [RecoveryNotice] = []
    var durableLaunchSettings: [String: LaunchSettings] = [:]
    var durableGlobalLaunchSettings = GlobalLaunchSettings()
    var launchSettingsCache: [String: LaunchSettings] = [:]
    var globalLaunchSettings = GlobalLaunchSettings()
    var knownEndedLaunchGames: Set<String> = []
    var liveLaunchGames: Set<String> = []
    /// Includes preparation and file-only recovery, even after verified game end.
    var launchSlotOwner: String?
    @ObservationIgnored var launchObservationGenerations: [String: UUID] = [:]
    @ObservationIgnored var launchRecoveryConflicts: Set<String> = []
    @ObservationIgnored var recoveryRetryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var recoveryInFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let recoverySleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored let launchPreferences: any LaunchPreferencesPersistence
    @ObservationIgnored let launchServices: any LaunchServices
    @ObservationIgnored let launchWindows: LaunchWindowCoordinator
    @ObservationIgnored let launchSleep: @Sendable () async throws -> Void
    @ObservationIgnored var launchTaskGenerations: [String: UUID] = [:]
    @ObservationIgnored var reattachedLaunchMonitors: Set<String> = []
    @ObservationIgnored var launchRecoveryPolls: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var launchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var launchStartupTask: Task<Void, Never>?
    @ObservationIgnored var settingsWriteTask: Task<Void, Never>?
    @ObservationIgnored var settingsWriteErrors: [String: LauncherError] = [:]
    @ObservationIgnored var launchStartupError: LauncherError?
    @ObservationIgnored var launchLogURLs: [String: URL] = [:]
    @ObservationIgnored var launchSettingsRevision = UUID()
    @ObservationIgnored var quitConfirmation: (@MainActor (String, @escaping @MainActor (NSApplication.TerminateReply) -> Void) -> Void)?


    init(paths: AppPaths = .standard(), manifest: RuntimeManifest? = nil,
        services: (any RuntimeServices)? = nil, defaults: UserDefaults? = .standard,
        artService: any GameArtProviding = EmptyGameArtProvider(),
        artServices: [Region: any GameArtProviding] = [:],
        eventsServices: [Region: any GameEventsProviding] = [:],
        gameServices: any GameServices = PreviewGameServices(),
        rosettaProbe: any RosettaProbing = UnknownRosettaProbe(),
        displayProbe: any DisplayProbe = FixedDisplayProbe(),
        displayNames: @escaping @MainActor @Sendable () -> [String: String] = { [:] },
        activationCenter: NotificationCenter = .default,
        rosettaClock: any Clock<Duration> = ContinuousClock(),
        rosettaPollInterval: Duration = .seconds(2), rosettaPollTimeout: Duration = .seconds(300),
        rosettaPrompt: @escaping @MainActor @Sendable () async throws -> Void = { try await RosettaPrompt.open() },
        locale: Locale = .current,
        purgeable: any PurgeableSpaceProbe = SystemPurgeableSpaceProbe(),
        launchServices: any LaunchServices = PreviewLaunchServices(),
        launchPreferences: (any LaunchPreferencesPersistence)? = nil,
        launchWindows: LaunchWindowCoordinator = LaunchWindowCoordinator(),
        launchSleep: @escaping @Sendable () async throws -> Void = { try await ContinuousClock().sleep(for: .milliseconds(500)) },
        recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        eventsNow: @escaping @Sendable () -> Date = Date.init,
        eventsSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        updater: any AppUpdating = InertAppUpdater(), artClock: any Clock<Duration> = ContinuousClock()) {
        self.artClock = artClock
        self.updater = updater
        self.eventsServices = eventsServices
        self.eventsNow = eventsNow; self.eventsSleep = eventsSleep
        self.eventsSnapshots = eventsServices.mapValues { $0.cached() }
        self.displayProbe = displayProbe; self.displayNames = displayNames
        self.launchPreferences = launchPreferences ?? LiveLaunchPreferencesPersistence(paths: paths)
        self.rosettaProbe = rosettaProbe; self.rosettaClock = rosettaClock
        self.activationCenter = activationCenter
        self.rosettaPollInterval = rosettaPollInterval; self.rosettaPollTimeout = rosettaPollTimeout; self.rosettaPrompt = rosettaPrompt
        self.recoverySleep = recoverySleep
        self.launchServices = launchServices; self.launchWindows = launchWindows; self.launchSleep = launchSleep
        self.paths = paths; self.manifest = manifest; self.gameServices = gameServices; self.purgeableSpace = purgeable
        self.services = services ?? LiveRuntimeServices(paths: paths)
        self.defaults = defaults; self.now = now
        let preferred = Self.persistedRegion(defaults: defaults, locale: locale)
        defaults?.set(preferred.rawValue, forKey: "region")
        self.region = Self.initialRegion(defaults: defaults, locale: locale)
        self.artServices = Region.allCases.reduce(into: [.global: artService]) { result, region in
            result[region] = artServices[region] ?? result[region] ?? EmptyGameArtProvider()
        }
        self.gameArt = self.artServices.reduce(into: [:]) { result, provider in
            result.merge(provider.value.cached().filter { GameDefinition.find($0.key)?.region == provider.key }) { _, new in new }
        }
        let stored = defaults?.string(forKey: "installRoot")
        self.installRoot = stored.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/MacGacha", isDirectory: true)
        rebuildRows()
        revalidateGameEvents()
        observeGameActivation()
        observeEventsWindowActivation()
        refreshConnectedDisplays()
        screenChangeObservation = ScreenChangeObservation(center: activationCenter, model: self)
    }

    func setGameState(_ id: String, _ state: GameState) {
        var state = state
        if case .working(let phase, let fraction, _, _, _) = state.activity {
            if case .working(let previous, _, _, _, _) = games[id]?.activity, previous != phase { state.timing = nil }
            if state.timing == nil, case .working(let previous, _, _, _, _) = games[id]?.activity, previous == phase {
                state.timing = games[id]?.timing
            }
            let time = now()
            if gameOperation?.id == id { gameProgress.beginPhase(phase, at: time) }
            state.timing = state.timing ?? GameTiming(phaseStarted: time, lastAdvance: time, remaining: nil, hasFraction: fraction != nil)
            state.timing?.hasFraction = fraction != nil
            if fraction == nil { state.timing?.remaining = nil }
        } else { state.timing = nil }
        games[id] = state
    }
    func setGameRecord(_ id: String, _ record: GameRecord?) { gameRecords[id] = record }
    func setRosetta(_ status: RosettaStatus) { rosetta = status }
    func setRosettaInstallInProgress(_ inProgress: Bool) { rosettaInstallInProgress = inProgress }
    func setArtCacheState(_ state: ArtCacheState, in region: Region) {
        artCacheStates[region] = state
        updateArtReveal()
    }

    func revealLauncher() {
        launcherRevealed = true
        artRevealTask?.cancel()
        revalidateGameEvents()
    }

    /// Call when revealing launcher content. Activation and the nearest expiry
    /// also revalidate automatically; this never makes a network request.
    func revalidateGameEvents() {
        eventsExpiryTask?.cancel(); eventsExpiryTask = nil
        let generation = UUID(); eventsExpiryGeneration = generation
        let date = eventsNow()
        let visible = (eventsSnapshots[region] ?? [:]).filter {
            GameDefinition.find($0.key)?.region == region && $0.value.region == region && $0.value.isFresh(at: date)
        }
        gameEvents = visible.mapValues(\.posts)
        guard let next = visible.values.filter({ !$0.posts.isEmpty }).map(\.expiresAt).min() else { return }
        let sleep = eventsSleep, delay = Duration.seconds(next.timeIntervalSince(date))
        eventsExpiryTask = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() } catch { return }
            guard let self, self.eventsExpiryGeneration == generation else { return }
            self.eventsExpiryTask = nil
            self.revalidateGameEvents()
        }
    }

    func applyArt(_ art: [String: GameArt], in region: Region) {
        gameArt = gameArt.filter { GameDefinition.find($0.key)?.region != region }
            .merging(art.filter { GameDefinition.find($0.key)?.region == region }) { _, new in new }
    }

    static func live() -> AppModel {
        // Keep legacy entry points safe too while the app switches to forCurrentProcess().
        if isRunningUnderXCTest { return inert() }
        let paths = AppPaths.standard()
        let log = EventLog(directory: paths.logs)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let launch = LiveLaunchServices(paths: paths, log: log)
        let art: [Region: any GameArtProviding] = Dictionary(uniqueKeysWithValues: Region.allCases.map {
            ($0, GameArtService(cacheDirectory: gameArtCacheDirectory(in: caches,
                bundleIdentifier: Bundle.main.bundleIdentifier), region: $0,
                language: HoYoPlayLanguage.preferred(Bundle.main.preferredLocalizations), log: log))
        })
        let events: [Region: any GameEventsProviding] = Dictionary(uniqueKeysWithValues: Region.allCases.map {
            ($0, GameEventsService(cacheDirectory: gameArtCacheDirectory(in: caches,
                bundleIdentifier: Bundle.main.bundleIdentifier).deletingLastPathComponent()
                .appendingPathComponent("GameEvents", isDirectory: true), region: $0,
                language: HoYoPlayLanguage.preferred(Bundle.main.preferredLocalizations)))
        })
        return AppModel(paths: paths, services: LiveRuntimeServices(paths: paths, log: log),
            artServices: art, eventsServices: events, gameServices: LiveGameServices(paths: paths, log: log, guard: launch),
            rosettaProbe: SystemRosettaProbe(), displayProbe: SystemDisplayProbe(),
            displayNames: { ScreenDisplayNames.current() }, launchServices: launch, updater: SparkleUpdaterService())
    }

    static func forCurrentProcess() -> AppModel {
        isRunningUnderXCTest ? inert() : live()
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func inert() -> AppModel {
        preview(rows: [], logLines: [], games: [:])
    }

    static func gameArtCacheDirectory(in caches: URL, bundleIdentifier: String?) -> URL {
        let identifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "MacGacha"
        return caches.appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("GameArt", isDirectory: true)
    }

    var runtimesReady: Bool {
        #if DEBUG
        if debugLaunchRuntimesReady { return true }
        #endif
        if manifest?.bundles.isEmpty == false { return !installedBundles.isEmpty }
        return installed.contains { $0.kind == .wine } && installed.contains { $0.kind == .dxmt || $0.kind == .d3dmetal }
    }

    deinit {
        rosettaRefreshTask?.cancel(); rosettaPollTask?.cancel(); rosettaInstallTask?.cancel()
        for check in runtimeSetupRosettaChecks.values { check.task.cancel() }
        for task in tasks.values { task.cancel() }
        searchTask?.cancel()
        for task in launchTasks.values { task.cancel() }
        for task in launchRecoveryPolls.values { task.cancel() }
        for task in recoveryRetryTasks.values { task.cancel() }
        for task in recoveryInFlight.values { task.cancel() }
        for task in regionLoadTasks.values { task.cancel() }
        for task in artTasks.values { task.cancel() }
        for task in artHydrationTasks.values { task.cancel() }
        artStartupTask?.cancel(); artRevealTask?.cancel()
        for task in eventsTasks.values { task.cancel() }
        eventsHydrationTask?.cancel(); eventsExpiryTask?.cancel(); eventsWindowTask?.cancel()
        gameTask?.cancel(); gameStartupTask?.cancel(); gameActivationTask?.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true; isStarting = true
        startArtStartup()
        let eventsHydration = hydrateGameEvents()
        defer { isStarting = false }
        refreshConnectedDisplays()
        await reattachOnStart()
        await refreshRosetta()
        do {
            if manifest == nil { manifest = try await BundledRuntimeManifest.load() }
            do { try await services.sweepStaging() }
            catch LauncherError.busy {
                // Recovery defers mutation, but installed runtimes remain
                // inspectable and must not appear available for replacement.
            }
            try await scanAndApply()
            await refreshLogs()
        } catch { show(error) }
        await refreshGames()
        await eventsHydration.value
        updater.start { [weak self] in self?.isBusyForUpdates ?? true }
    }

    func refreshRuntimes() async {
        do { try await scanAndApply() }
        catch { show(error) }
    }

    private func scanAndApply() async throws {
        let generation = UUID(); scanGeneration = generation
        let consentRevision = runtimeConsentRevision
        let scan = try await services.scan()
        let bundles: [String: InstalledRuntimeBundle]
        if let manifest { bundles = try await services.scanBundles(manifest) } else { bundles = [:] }
        var consent: [String: Bool] = [:]
        for component in manifest?.components ?? [] where component.consent != nil {
            consent[component.id.rawValue] = await services.isConsentAccepted(component)
        }
        try Task.checkCancellation()
        guard scanGeneration == generation else { return }
        if runtimeConsentRevision == consentRevision { runtimeConsentAccepted = consent }
        installedBundles = bundles
        apply(scan)
    }

    func install(_ id: String) { request(id, mode: .download) }
    func importGPTK(_ id: String) { request(id, mode: .importGPTK) }

    private func bundle(_ id: String) -> RuntimeBundle? { manifest?.bundles.first { $0.id.rawValue == id } }
    private func requestedComponent(_ id: String) -> RuntimeComponent? {
        if let bundle = bundle(id) {
            return manifest?.components.first { bundle.components.contains($0.id) && $0.wineBinary != nil }
        }
        return manifest?.components.first { $0.id.rawValue == id }
    }

    private func request(_ id: String, mode: ConsentMode) {
        guard canBeginGameOrRuntimeOperation() else { return }
        guard tasks[id] == nil, consentRequest == nil,
            let component = requestedComponent(id),
            mode != .importGPTK || component.kind == .d3dmetal else { return }
        let generation = UUID(); generations[id] = generation; requestModes[id] = mode
        let services = services
        errors[id] = nil; working[id] = .working(phase: .checkingSpace, fraction: nil); rebuildRows()
        tasks[id] = Task { [weak self] in
            let accepted = await services.isConsentAccepted(component)
            guard !Task.isCancelled, self?.generations[id] == generation else {
                self?.finish(id, generation: generation); return
            }
            self?.cacheRuntimeConsent(accepted, for: component)
            self?.finish(id, generation: generation)
            guard let self else { return }
            if !accepted {
                self.consentRequest = ConsentRequest(id: id, mode: mode, title: AppleNotice.title,
                    body: AppleNotice.body, termsURL: AppleNotice.termsURL)
            } else if mode == .importGPTK { self.beginImport(component, bundle: self.bundle(id)) }
            else { self.beginOperation(component, from: nil, bundle: self.bundle(id)) }
        }
    }

    func respondToConsent(accept: Bool) {
        guard let request = consentRequest else { return }
        defer { scheduleRuntimeSetupUpdate() }
        consentRequest = nil
        guard accept, tasks[request.id] == nil,
            let component = requestedComponent(request.id) else { return }
        let id = request.id; let generation = UUID(); generations[id] = generation; requestModes[id] = request.mode
        let services = services
        working[id] = .working(phase: .checkingSpace, fraction: nil); rebuildRows()
        tasks[id] = Task { [weak self] in
            do {
                try await services.acceptConsent(for: component)
                try Task.checkCancellation()
                guard self?.generations[id] == generation else { return }
                self?.cacheRuntimeConsent(true, for: component)
                self?.finish(id, generation: generation)
                if request.mode == .importGPTK { self?.beginImport(component, bundle: self?.bundle(id)) }
                else { self?.beginOperation(component, from: nil, bundle: self?.bundle(id)) }
            } catch {
                if self?.generations[id] == generation {
                    if launcherError(error) != .cancelled { self?.errors[id] = launcherError(error).userMessage }
                    self?.show(error)
                }
                self?.finish(id, generation: generation)
            }
        }
    }

    func chooseCandidate(_ candidate: GPTKCandidate) {
        guard let component = importComponent, case .choose(let candidates) = importState,
            candidates.contains(candidate), tasks[component.id.rawValue] == nil else { return }
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID()
        let bundle = importRuntimeBundle
        importComponent = nil; importRuntimeBundle = nil; importState = nil
        beginOperation(component, from: candidate, bundle: bundle)
    }

    func rescanGPTK() {
        guard let component = importComponent else { return }
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        let roots = extraRoots; let services = services
        importState = .searching
        searchTask = Task { [weak self] in
            do {
                let candidates = try await services.locateGPTK(extraRoots: roots)
                try Task.checkCancellation()
                guard let self, self.searchGeneration == generation, self.importComponent?.id == component.id else { return }
                self.searchTask = nil
                if candidates.isEmpty { self.importState = .notFound }
                else {
                    self.importState = .choose(candidates)
                    if candidates.count == 1, let first = candidates.first { self.chooseCandidate(first) }
                }
            } catch {
                guard let self, self.searchGeneration == generation else { return }
                self.searchTask = nil
                if launcherError(error) != .cancelled { self.importState = .notFound; self.show(error) }
            }
        }
    }

    func addGPTKSearchRoot(_ url: URL) {
        guard url.isFileURL, !url.path.utf8.contains(0), importComponent != nil else { return }
        let root = url.standardizedFileURL
        if !extraRoots.contains(root) {
            guard extraRoots.count < 32 else { show(LauncherError.io("Too many search roots")); return }
            extraRoots.append(root)
        }
        rescanGPTK()
    }

    func cancelImport() {
        defer { scheduleRuntimeSetupUpdate() }
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID()
        importComponent = nil; importRuntimeBundle = nil; importState = nil; extraRoots = []
        if consentRequest?.mode == .importGPTK { consentRequest = nil }
        for (id, mode) in requestModes where mode == .importGPTK { tasks[id]?.cancel() }
    }

    func cancel(_ id: String) {
        defer { scheduleRuntimeSetupUpdate() }
        tasks[id]?.cancel()
        if consentRequest?.id == id { consentRequest = nil }
        if importComponent?.id.rawValue == id || importRuntimeBundle?.id.rawValue == id { cancelImport() }
    }

    private func beginImport(_ component: RuntimeComponent, bundle: RuntimeBundle? = nil) {
        cancelImport()
        importComponent = component; importRuntimeBundle = bundle
        rescanGPTK()
    }

    private func beginOperation(_ component: RuntimeComponent, from candidate: GPTKCandidate?, bundle: RuntimeBundle? = nil) {
        guard canBeginGameOrRuntimeOperation() else { return }
        let id = bundle?.id.rawValue ?? component.id.rawValue; let generation = UUID(); generations[id] = generation
        let services = services
        errors[id] = nil; progressTimes[id] = nil
        working[id] = .working(phase: .staging, fraction: nil); rebuildRows()
        let manifest = manifest
        tasks[id] = Task { [weak self] in
            let stream: RuntimeInstallStream
            if let bundle, let manifest { stream = services.install(bundle, manifest: manifest, from: candidate) }
            else { stream = RuntimeInstallStream(services.install(component, from: candidate)) }
            do {
                var completed = false
                for try await event in stream {
                    try Task.checkCancellation()
                    guard self?.generations[id] == generation else { return }
                    switch event {
                    case .phase(.completed):
                        try await self?.scanAndApply()
                        completed = true
                    case .failed(let error): throw error
                    case .needsBatchApproval(let required, let available):
                        throw LauncherError.insufficientSpace(required: required, available: available)
                    case .phase(.cancelled): throw LauncherError.cancelled
                    case .phase(.failed): throw LauncherError.io("Runtime operation failed")
                    case .phase(let phase):
                        self?.working[id] = .working(phase: phase, fraction: nil); self?.rebuildRows()
                    case .progress(let downloaded, let network, let staged, let totalStaged):
                        self?.updateProgress(id, downloaded: downloaded, network: network, staged: staged, totalStaged: totalStaged)
                    case .fileVerified: break
                    }
                    if completed { break } // A terminal event is consumed exactly once.
                }
                try Task.checkCancellation()
                if !completed { throw LauncherError.transport("Operation ended before completion") }
            } catch {
                // Also join when cancellation is observed between two iterator pulls.
                await stream.cancelAndWait()
                if launcherError(error) == .cancelled {
                    // Publication can win a late cancellation; show the actual visible tree.
                    let scanToken = UUID(); self?.scanGeneration = scanToken
                    let snapshot = await Task.detached { () -> (RuntimeScan, [String: InstalledRuntimeBundle])? in
                        guard let scan = try? await services.scan() else { return nil }
                        let bundles: [String: InstalledRuntimeBundle]
                        if let manifest {
                            guard let scanned = try? await services.scanBundles(manifest) else { return nil }
                            bundles = scanned
                        } else { bundles = [:] }
                        return (scan, bundles)
                    }.value
                    if self?.generations[id] == generation, self?.scanGeneration == scanToken, let snapshot {
                        self?.installedBundles = snapshot.1; self?.apply(snapshot.0)
                    }
                } else if self?.generations[id] == generation {
                    self?.errors[id] = launcherError(error).userMessage; self?.show(error)
                }
            }
            self?.finish(id, generation: generation)
        }
    }

    private func updateProgress(_ id: String, downloaded: Int64, network: Int64, staged: Int64, totalStaged: Int64) {
        let time = now()
        if let previous = progressTimes[id], previous.duration(to: time) < .milliseconds(100) { return }
        progressTimes[id] = time
        let total = network > 0 ? network : totalStaged
        let count = network > 0 ? downloaded : staged
        let fraction = total > 0 ? min(1, max(0, Double(count) / Double(total))) : nil
        guard case .working(let phase, _) = working[id] else { return }
        working[id] = .working(phase: phase, fraction: fraction)
        rebuildRows()
    }

    private func finish(_ id: String, generation: UUID) {
        guard generations[id] == generation else { return }
        tasks[id] = nil; generations[id] = nil; requestModes[id] = nil; working[id] = nil; progressTimes[id] = nil
        rebuildRows()
    }

    func remove(_ id: String) async {
        guard canBeginGameOrRuntimeOperation() else { return }
        guard tasks[id] == nil, working[id] == nil else { return }
        if let bundle = bundle(id), let manifest {
            working[id] = .working(phase: .deleting, fraction: nil); rebuildRows()
            defer { working[id] = nil; rebuildRows() }
            do { try await services.remove(bundle, manifest: manifest); try await scanAndApply(); errors[id] = nil }
            catch {
                if case LauncherError.busy = error { errors[id] = nil }
                else { errors[id] = launcherError(error).userMessage }
                show(error)
            }
            return
        }
        let component = installed.first { Self.id($0) == id }
        let bad = invalid[id]
        guard component != nil || bad?.removable == true else { return }
        working[id] = .working(phase: .deleting, fraction: nil); rebuildRows()
        defer { working[id] = nil; rebuildRows() }
        do {
            if let component { try await services.remove(component) }
            else if let bad { try await services.removeInvalid(bad) }
            try await scanAndApply()
            errors[id] = nil
        } catch {
            if case LauncherError.busy = error { errors[id] = nil }
            else { errors[id] = launcherError(error).userMessage }
            show(error)
        }
    }

    func refreshLogs() async { logLines = Array((await services.recentLogLines(limit: 200)).suffix(200)) }

    /// Returns a complete temporary ZIP. The caller owns the returned file.
    func makeDiagnosticBundle() async throws -> URL {
        guard !isExporting else { throw LauncherError.busy("Diagnostics export already in progress") }
        isExporting = true
        defer { isExporting = false }
        do { try await flushLaunchSettings(); return try await services.makeDiagnosticBundle() }
        catch { show(error); throw launcherError(error) }
    }

    // Compatibility for existing views: never write to the destination until the bundle is complete.
    func exportDiagnostics(to url: URL) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            try await flushLaunchSettings()
            let bundle = try await services.makeDiagnosticBundle()
            do { try await TemporaryDiagnosticBundle.publish(bundle, to: url) }
            catch { await TemporaryDiagnosticBundle.discard(bundle); throw error }
            await TemporaryDiagnosticBundle.discard(bundle)
        }
        catch { show(error) }
    }

    func setInstallRoot(_ url: URL) {
        guard url.isFileURL, !url.path.utf8.contains(0) else { show(LauncherError.unsafePath("install root")); return }
        installRoot = url.standardizedFileURL
        defaults?.set(installRoot.path, forKey: "installRoot")
    }

    func dismissError() { lastError = nil }

    private func apply(_ scan: RuntimeScan) {
        // Invalidate any older in-flight refresh before it can overwrite this snapshot.
        scanGeneration = UUID()
        installed = scan.components
        invalid = Dictionary(uniqueKeysWithValues: scan.invalid.enumerated().map { index, entry in
            ("invalid:\(entry.kind?.rawValue ?? "unknown"):\(entry.rawName):\(index)", entry)
        })
        rebuildRows()
    }

    private func rebuildRows() {
        isRuntimeOperationRunning = !tasks.isEmpty || !working.isEmpty
        var result: [RuntimeRow] = []
        let covered = Set((manifest?.bundles ?? []).flatMap(\.components))
        for bundle in manifest?.bundles ?? [] {
            let id = bundle.id.rawValue
            let components = (manifest?.components ?? []).filter { bundle.components.contains($0.id) }
            result.append(RuntimeRow(id: id, kindName: bundle.displayName, version: components.map { $0.version.rawValue }.joined(separator: " + "),
                licenseName: components.map { $0.license.name }.joined(separator: " / "),
                state: working[id] ?? errors[id].map { .failed(message: $0) } ?? installedBundles[id].map { .installed(source: $0.source) } ?? .notInstalled,
                canImportGPTK: bundle.backend == .d3dmetal, needsConsent: components.contains { $0.consent != nil },
                summary: bundle.summary, downloadSize: components.reduce(Int64(0)) { $0 + ($1.size ?? 0) }))
        }
        for component in manifest?.components ?? [] where !covered.contains(component.id) {
            let id = component.id.rawValue
            let existing = installed.first { $0.kind == component.kind && $0.version == component.version.rawValue }
            result.append(RuntimeRow(id: id, kindName: Self.kindName(component.kind), version: component.version.rawValue,
                licenseName: component.license.name,
                state: working[id] ?? errors[id].map { .failed(message: $0) } ?? existing.map { .installed(source: $0.source) } ?? .notInstalled,
                canImportGPTK: component.kind == .d3dmetal, needsConsent: component.consent != nil, downloadSize: component.size))
        }
        for component in installed where !covered.contains(where: { $0.rawValue == Self.id(component) }) && !result.contains(where: { $0.id == Self.id(component) }) {
            let id = Self.id(component)
            result.append(RuntimeRow(id: id, kindName: Self.kindName(component.kind), version: component.version,
                licenseName: String(localized: "Installed runtime"), state: working[id] ?? .installed(source: component.source), canImportGPTK: false, needsConsent: false))
        }
        for (id, entry) in invalid.sorted(by: { $0.key < $1.key }) {
            result.append(RuntimeRow(id: id, kindName: entry.kind.map(Self.kindName) ?? String(localized: "Unknown runtime"), version: entry.rawName,
                licenseName: String(localized: "Local runtime"), state: working[id] ?? .invalid(reason: entry.reason, removable: entry.removable),
                canImportGPTK: false, needsConsent: false))
        }
        rows = result
        scheduleRuntimeSetupUpdate()
    }

    func setRuntimeSetupProgress(_ progress: RuntimeSetupProgress?, for id: String) {
        if runtimeSetupProgress[id] != progress { runtimeSetupProgress[id] = progress }
    }

    private func cacheRuntimeConsent(_ accepted: Bool, for component: RuntimeComponent) {
        guard component.consent != nil else { return }
        runtimeConsentRevision = UUID(); runtimeConsentAccepted[component.id.rawValue] = accepted
    }

    var canStartRuntimeSetupItem: Bool {
        tasks.isEmpty && working.isEmpty && consentRequest == nil && importState == nil
    }

    func runtimeSetupItemState(_ id: String) -> RuntimeSetupItemState {
        // A fresh chain must wait for cancellation drainage, not subscribe to
        // an attempt that can no longer complete its install.
        if tasks[id]?.isCancelled == true { return .blocked }
        if tasks[id] != nil || consentRequest?.id == id || importRuntimeBundle?.id.rawValue == id || importComponent?.id.rawValue == id {
            if case .working(_, let fraction) = working[id] { return .busy(fraction: fraction) }
            return .busy(fraction: nil)
        }
        if working[id] != nil { return .blocked }
        if let error = errors[id] { return .failed(error) }
        if bundle(id) != nil { return installedBundles[id] == nil ? .idle : .installed }
        if let component = requestedComponent(id), installed.contains(where: { $0.kind == component.kind && $0.version == component.version.rawValue }) { return .installed }
        return .idle
    }

    func show(_ error: any Error) {
        let error = launcherError(error)
        if error != .cancelled { lastError = error.userMessage }
    }
    private static func id(_ component: InstalledComponent) -> String { "\(component.kind.idPrefix)-\(component.version)" }
    static func kindName(_ kind: ComponentKind) -> String {
        switch kind {
        case .wine: "Wine"; case .dxmt: "DXMT"; case .d3dmetal: "D3DMetal"
        case .crypt32Fix: String(localized: "Wine crypt32 fix", comment: "Runtime component name")
        case .jadeite: String(localized: "Jadeite", comment: "Runtime component name"); case .steamShim: String(localized: "Steam shim", comment: "Runtime component name")
        }
    }
}

// Both scoped and unqualified names are available to the view layer.
typealias ConsentMode = AppModel.ConsentMode
typealias ConsentRequest = AppModel.ConsentRequest
typealias ImportState = AppModel.ImportState
typealias RowState = AppModel.RowState
typealias RuntimeRow = AppModel.RuntimeRow

extension GPTKCandidate: @retroactive Identifiable {
    public var id: String { root.path }
}

struct BundledRuntimeManifest {
    @concurrent static func load() async throws -> RuntimeManifest {
        guard let url = Bundle.main.url(forResource: "runtime-manifest", withExtension: "json") else {
            throw LauncherError.io("Bundled runtime manifest is missing")
        }
        return try await BlockingIO.run { try RuntimeManifest.load(from: url) }
    }
}

extension AppModel {
    static var sampleGameStates: [String: GameState] {
        Dictionary(uniqueKeysWithValues: GameDefinition.all.map { game in
            let status: GameStatus = switch game.family {
            case .genshin: .installed(tag: "7.1.0")
            case .starrail: .paused(.update)
            case .zzz: .notInstalled
            }
            return (game.id, GameState(status: status))
        })
    }
    static var sampleRows: [RuntimeRow] {
        [RuntimeRow(id: "dxmt-wine11.0-dxmt0.80", kindName: "DXMT", version: "11.0-yaagl + 0.80", licenseName: "LGPL-2.1 / MIT",
            state: .working(phase: .staging, fraction: 0.42), canImportGPTK: false, needsConsent: false,
            summary: "Wine 11.0 with game patches · DXMT 0.80", downloadSize: 465_267_389),
         RuntimeRow(id: "d3dmetal-wine11.20-gptk4.0b3", kindName: "D3DMetal", version: "4.0b3", licenseName: "Apple Game Porting Toolkit",
            state: .notInstalled, canImportGPTK: true, needsConsent: true,
            summary: "Wine 11.20 · Apple D3DMetal 4.0 beta 3", downloadSize: 307_352_548)]
    }

    static func preview(rows: [RuntimeRow] = sampleRows, consent: ConsentRequest? = nil,
        importState: ImportState? = nil, lastError: String? = nil,
        logLines: [String] = ["Runtime manager ready", "D3DMetal requires acceptance of Apple's license terms"],
        games: [String: GameState] = sampleGameStates, region: Region = .global) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGacha-Preview-\(UUID().uuidString)")
        let model = AppModel(paths: AppPaths(root: root), manifest: try? RuntimeManifest(components: []),
            services: PreviewRuntimeServices(), defaults: nil, gameServices: PreviewGameServices(states: games))
        model.regionLoadingEnabled = false; model.region = region; model.games = [:]
        for (id, state) in games { model.setGameState(id, state) }
        model.rows = rows; model.consentRequest = consent; model.importState = importState
        model.installed = rows.compactMap { row in
            guard case .installed(let source) = row.state,
                let kind = ComponentKind.allCases.first(where: { row.id.hasPrefix($0.idPrefix + "-") }) else { return nil }
            return try? InstalledComponent(kind: kind, version: row.version, installedAt: Date(), source: source)
        }
        model.lastError = lastError; model.logLines = Array(logLines.suffix(200))
        model.isStarting = false; model.started = true; model.launcherRevealed = true; model.installRoot = root.appendingPathComponent("Games")
        return model
    }
}
