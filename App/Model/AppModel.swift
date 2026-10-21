// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
    }

    private(set) var games: [String: GameState] = Dictionary(uniqueKeysWithValues: GameDefinition.all.map { ($0.id, GameState(status: .unknown)) })
    private(set) var gameRecords: [String: GameRecord] = [:]
    private(set) var gameArt: [String: GameArt]
    private(set) var rows: [RuntimeRow] = []
    private(set) var consentRequest: ConsentRequest?
    private(set) var importState: ImportState?
    private(set) var lastError: String?
    private(set) var logLines: [String] = []
    private(set) var isExporting = false
    private(set) var isStarting = true
    private(set) var installRoot: URL

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private var manifest: RuntimeManifest?
    @ObservationIgnored private let services: any RuntimeServices
    @ObservationIgnored private let artService: any GameArtProviding
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored let gameServices: any GameServices
    @ObservationIgnored var gameTask: Task<Void, Never>?
    @ObservationIgnored var gameStartupTask: Task<Void, Never>?
    @ObservationIgnored var gameActivationTask: Task<Void, Never>?
    @ObservationIgnored var gameOperation: GameOperationToken?
    @ObservationIgnored var gameProgress = GameProgress()
    @ObservationIgnored var gameLastRefresh: ContinuousClock.Instant?
    @ObservationIgnored var gameRefreshInFlight = false
    @ObservationIgnored var gameRevisions: [String: UUID] = [:]
    @ObservationIgnored let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var working: [String: RowState] = [:]
    @ObservationIgnored private var errors: [String: String] = [:]
    @ObservationIgnored private var installed: [InstalledComponent] = []
    @ObservationIgnored private var invalid: [String: InvalidRuntimeEntry] = [:]
    @ObservationIgnored private var requestModes: [String: ConsentMode] = [:]
    @ObservationIgnored private var progressTimes: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var importComponent: RuntimeComponent?
    @ObservationIgnored private var extraRoots: [URL] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var scanGeneration = UUID()

    init(paths: AppPaths = .standard(), manifest: RuntimeManifest? = nil,
        services: (any RuntimeServices)? = nil, defaults: UserDefaults? = .standard,
        artService: any GameArtProviding = EmptyGameArtProvider(),
        gameServices: any GameServices = PreviewGameServices(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.paths = paths; self.manifest = manifest; self.gameServices = gameServices
        self.services = services ?? LiveRuntimeServices(paths: paths)
        self.defaults = defaults; self.now = now; self.artService = artService; self.gameArt = artService.cached()
        let stored = defaults?.string(forKey: "installRoot")
        self.installRoot = stored.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/MacGacha", isDirectory: true)
        rebuildRows()
        observeGameActivation()
    }

    func setGameState(_ id: String, _ state: GameState) { games[id] = state }
    func setGameRecord(_ id: String, _ record: GameRecord?) { gameRecords[id] = record }

    static func live() -> AppModel {
        // Keep legacy entry points safe too while the app switches to forCurrentProcess().
        if isRunningUnderXCTest { return inert() }
        let paths = AppPaths.standard()
        let log = EventLog(directory: paths.logs)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return AppModel(paths: paths, services: LiveRuntimeServices(paths: paths, log: log),
            artService: GameArtService(cacheDirectory: gameArtCacheDirectory(in: caches,
                bundleIdentifier: Bundle.main.bundleIdentifier), log: log), gameServices: LiveGameServices(paths: paths, log: log))
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
        installed.contains { $0.kind == .wine } && installed.contains { $0.kind == .dxmt || $0.kind == .d3dmetal }
    }

    func loadGameArt() async {
        let persisted = await artService.loadCached()
        guard !Task.isCancelled else { return }
        gameArt = persisted
        let updated = await artService.refresh()
        if !Task.isCancelled { gameArt = updated }
    }

    deinit {
        for task in tasks.values { task.cancel() }
        searchTask?.cancel()
        gameTask?.cancel(); gameStartupTask?.cancel(); gameActivationTask?.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true; isStarting = true
        defer { isStarting = false }
        do {
            if manifest == nil { manifest = try await BundledRuntimeManifest.load() }
            try await services.sweepStaging()
            try await scanAndApply()
            await refreshLogs()
        } catch { show(error) }
        await refreshGames()
    }

    func refreshRuntimes() async {
        do { try await scanAndApply() }
        catch { show(error) }
    }

    private func scanAndApply() async throws {
        let generation = UUID(); scanGeneration = generation
        let scan = try await services.scan()
        try Task.checkCancellation()
        guard scanGeneration == generation else { return }
        apply(scan)
    }

    func install(_ id: String) { request(id, mode: .download) }
    func importGPTK(_ id: String) { request(id, mode: .importGPTK) }

    private func request(_ id: String, mode: ConsentMode) {
        guard tasks[id] == nil, consentRequest == nil,
            let component = manifest?.components.first(where: { $0.id.rawValue == id }),
            mode != .importGPTK || component.kind == .d3dmetal else { return }
        let generation = UUID(); generations[id] = generation; requestModes[id] = mode
        let services = services
        errors[id] = nil; working[id] = .working(phase: .checkingSpace, fraction: nil); rebuildRows()
        tasks[id] = Task { [weak self] in
            let accepted = await services.isConsentAccepted(component)
            guard !Task.isCancelled, self?.generations[id] == generation else {
                self?.finish(id, generation: generation); return
            }
            self?.finish(id, generation: generation)
            guard let self else { return }
            if !accepted {
                self.consentRequest = ConsentRequest(id: id, mode: mode, title: AppleNotice.title,
                    body: AppleNotice.body, termsURL: AppleNotice.termsURL)
            } else if mode == .importGPTK { self.beginImport(component) }
            else { self.beginOperation(component, from: nil) }
        }
    }

    func respondToConsent(accept: Bool) {
        guard let request = consentRequest else { return }
        consentRequest = nil
        guard accept, tasks[request.id] == nil,
            let component = manifest?.components.first(where: { $0.id.rawValue == request.id }) else { return }
        let id = request.id; let generation = UUID(); generations[id] = generation; requestModes[id] = request.mode
        let services = services
        working[id] = .working(phase: .checkingSpace, fraction: nil); rebuildRows()
        tasks[id] = Task { [weak self] in
            do {
                try await services.acceptConsent(for: component)
                try Task.checkCancellation()
                guard self?.generations[id] == generation else { return }
                self?.finish(id, generation: generation)
                if request.mode == .importGPTK { self?.beginImport(component) }
                else { self?.beginOperation(component, from: nil) }
            } catch {
                if self?.generations[id] == generation { self?.show(error) }
                self?.finish(id, generation: generation)
            }
        }
    }

    func chooseCandidate(_ candidate: GPTKCandidate) {
        guard let component = importComponent, case .choose(let candidates) = importState,
            candidates.contains(candidate), tasks[component.id.rawValue] == nil else { return }
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID()
        importComponent = nil; importState = nil
        beginOperation(component, from: candidate)
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
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID()
        importComponent = nil; importState = nil; extraRoots = []
        if consentRequest?.mode == .importGPTK { consentRequest = nil }
        for (id, mode) in requestModes where mode == .importGPTK { tasks[id]?.cancel() }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        if consentRequest?.id == id { consentRequest = nil }
        if importComponent?.id.rawValue == id { cancelImport() }
    }

    private func beginImport(_ component: RuntimeComponent) {
        cancelImport()
        importComponent = component
        rescanGPTK()
    }

    private func beginOperation(_ component: RuntimeComponent, from candidate: GPTKCandidate?) {
        let id = component.id.rawValue; let generation = UUID(); generations[id] = generation
        let services = services
        errors[id] = nil; progressTimes[id] = nil
        working[id] = .working(phase: .staging, fraction: nil); rebuildRows()
        tasks[id] = Task { [weak self] in
            do {
                var completed = false
                for try await event in services.install(component, from: candidate) {
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
                if launcherError(error) == .cancelled {
                    // Publication can win a late cancellation; show the actual visible tree.
                    let scanToken = UUID(); self?.scanGeneration = scanToken
                    let scan = await Task.detached { try? await services.scan() }.value
                    if self?.generations[id] == generation, self?.scanGeneration == scanToken,
                        let scan { self?.apply(scan) }
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
        guard tasks[id] == nil, working[id] == nil else { return }
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
        } catch { errors[id] = launcherError(error).userMessage; show(error) }
    }

    func refreshLogs() async { logLines = Array((await services.recentLogLines(limit: 200)).suffix(200)) }

    /// Returns a complete temporary ZIP. The caller owns the returned file.
    func makeDiagnosticBundle() async throws -> URL {
        guard !isExporting else { throw LauncherError.busy("Diagnostics export already in progress") }
        isExporting = true
        defer { isExporting = false }
        do { return try await services.makeDiagnosticBundle() }
        catch { show(error); throw launcherError(error) }
    }

    // Compatibility for existing views: never write to the destination until the bundle is complete.
    func exportDiagnostics(to url: URL) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        do {
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
        var result: [RuntimeRow] = []
        for component in manifest?.components ?? [] {
            let id = component.id.rawValue
            let existing = installed.first { $0.kind == component.kind && $0.version == component.version.rawValue }
            result.append(RuntimeRow(id: id, kindName: Self.kindName(component.kind), version: component.version.rawValue,
                licenseName: component.license.name,
                state: working[id] ?? errors[id].map { .failed(message: $0) } ?? existing.map { .installed(source: $0.source) } ?? .notInstalled,
                canImportGPTK: component.kind == .d3dmetal, needsConsent: component.consent != nil))
        }
        for component in installed where !result.contains(where: { $0.id == Self.id(component) }) {
            let id = Self.id(component)
            result.append(RuntimeRow(id: id, kindName: Self.kindName(component.kind), version: component.version,
                licenseName: "Installed runtime", state: working[id] ?? .installed(source: component.source), canImportGPTK: false, needsConsent: false))
        }
        for (id, entry) in invalid.sorted(by: { $0.key < $1.key }) {
            result.append(RuntimeRow(id: id, kindName: entry.kind.map(Self.kindName) ?? "Unknown runtime", version: entry.rawName,
                licenseName: "Local runtime", state: working[id] ?? .invalid(reason: entry.reason, removable: entry.removable),
                canImportGPTK: false, needsConsent: false))
        }
        rows = result
    }

    func show(_ error: any Error) {
        let error = launcherError(error)
        if error != .cancelled { lastError = error.userMessage }
    }
    private static func id(_ component: InstalledComponent) -> String { "\(component.kind.rawValue)-\(component.version)" }
    private static func kindName(_ kind: ComponentKind) -> String {
        switch kind { case .wine: "Wine"; case .dxmt: "DXMT"; case .d3dmetal: "D3DMetal" }
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
        return try RuntimeManifest.load(from: url)
    }
}

extension AppModel {
    static var sampleGameStates: [String: GameState] {
        ["genshin": GameState(status: .installed(tag: "7.1.0")),
         "starrail": GameState(status: .paused(.update)),
         "zzz": GameState(status: .notInstalled)]
    }
    static var sampleRows: [RuntimeRow] {
        [RuntimeRow(id: "wine-10.0", kindName: "Wine", version: "10.0", licenseName: "LGPL-2.1",
            state: .installed(source: .download), canImportGPTK: false, needsConsent: false),
         RuntimeRow(id: "dxmt-0.62", kindName: "DXMT", version: "0.62", licenseName: "MIT",
            state: .working(phase: .staging, fraction: 0.42), canImportGPTK: false, needsConsent: false),
         RuntimeRow(id: "d3dmetal-3.0", kindName: "D3DMetal", version: "3.0", licenseName: "Apple Game Porting Toolkit",
            state: .notInstalled, canImportGPTK: true, needsConsent: true)]
    }

    static func preview(rows: [RuntimeRow] = sampleRows, consent: ConsentRequest? = nil,
        importState: ImportState? = nil, lastError: String? = nil,
        logLines: [String] = ["Runtime manager ready", "D3DMetal requires acceptance of Apple's license terms"],
        games: [String: GameState] = sampleGameStates) -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGacha-Preview-\(UUID().uuidString)")
        let model = AppModel(paths: AppPaths(root: root), manifest: try? RuntimeManifest(components: []),
            services: PreviewRuntimeServices(), defaults: nil, gameServices: PreviewGameServices(states: games))
        model.games = games
        model.rows = rows; model.consentRequest = consent; model.importState = importState
        model.installed = rows.compactMap { row in
            guard case .installed(let source) = row.state,
                let kind = ComponentKind.allCases.first(where: { row.id.hasPrefix($0.rawValue + "-") }) else { return nil }
            return try? InstalledComponent(kind: kind, version: row.version, installedAt: Date(), source: source)
        }
        model.lastError = lastError; model.logLines = Array(logLines.suffix(200))
        model.isStarting = false; model.started = true; model.installRoot = root.appendingPathComponent("Games")
        return model
    }
}
