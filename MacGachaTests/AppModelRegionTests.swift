// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import GameLibrary
import HoYoPlayAPI
import Launch
import RuntimeManager
@testable import MacGacha

@Suite @MainActor struct AppModelRegionTests {
    @Test(arguments: ["zh_CN", "en_CN", "en_US", "zh_Hans_US", "zh_Hant_TW", "zh_Hant_HK"])
    func initialRegionUsesTerritoryNotLanguage(identifier: String) {
        let model = model(locale: Locale(identifier: identifier))
        #expect(model.region == (identifier.hasSuffix("_CN") ? .mainlandChina : .global))
        #expect(model.regionIsBeta == (model.region == .mainlandChina))
    }

    @Test func regionPersistsAndOverridesLaterLocaleChanges() throws {
        let name = "MacGacha-RegionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = model(defaults: defaults, locale: Locale(identifier: "en_CN"))
        #expect(first.region == .mainlandChina)
        #expect(defaults.string(forKey: "region") == Region.mainlandChina.rawValue)
        let second = model(defaults: defaults, locale: Locale(identifier: "en_US"))
        #expect(second.region == .mainlandChina)
        second.region = .global
        #expect(defaults.string(forKey: "region") == Region.global.rawValue)
        #expect(model(defaults: defaults, locale: Locale(identifier: "zh_CN")).region == .global)
    }

    @Test func invalidStoredRegionFallsBackToLocale() throws {
        let name = "MacGacha-InvalidRegion-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: "region")
        #expect(model(defaults: defaults, locale: Locale(identifier: "zh_CN")).region == .mainlandChina)
        #expect(defaults.string(forKey: "region") == Region.mainlandChina.rawValue)
    }

    @Test func visibleGamesHaveEditionNamesOrderAndSharedTints() throws {
        let model = model()
        #expect(LauncherGame.all.map(\.id) == GameDefinition.all.map(\.id))
        #expect(model.visibleGames.map(\.id) == ["genshin", "starrail", "zzz"])
        model.region = .mainlandChina
        #expect(model.visibleGames.map(\.id) == ["genshin-cn", "starrail-cn", "zzz-cn"])
        #expect(model.visibleGames.allSatisfy { $0.region == .mainlandChina })
        for (global, cn) in zip(LauncherGame.games(in: .global), model.visibleGames) {
            #expect(global.tint == cn.tint && global.deepTint == cn.deepTint)
        }
        #expect(model.visibleGames[0].name == "原神")
        #expect(model.visibleGames[1].name == "崩坏：星穹铁道")
        #expect(model.visibleGames[2].name == "绝区零")
    }

    @Test(arguments: [OtherRegionActivity.downloading, .updating, .verifying, .playing, .restoring])
    func otherRegionActivityFollowsReservation(kind: OtherRegionActivity) {
        let model = model()
        switch kind {
        case .downloading, .updating, .verifying:
            model.gameOperation = GameOperationToken(id: "genshin-cn", generation: UUID(), kind: kind)
        case .playing:
            model.launchSlotOwner = "genshin-cn"; model.liveLaunchGames.insert("genshin-cn")
            model.launchStates["genshin-cn"] = .running
        case .restoring:
            model.launchSlotOwner = "genshin-cn"; model.knownEndedLaunchGames.insert("genshin-cn")
            model.launchStates["genshin-cn"] = .recoveryNeeded("pending")
        }
        #expect(model.otherRegionActivity?.game.id == "genshin-cn")
        #expect(model.otherRegionActivity?.kind == kind)
        model.region = .mainlandChina
        #expect(model.otherRegionActivity == nil)
        model.region = .global
        #expect(model.otherRegionActivity?.kind == kind)
    }

    @Test func verificationPhaseAndVerifiedEndOverrideEarlierActivity() {
        let model = model()
        model.gameOperation = GameOperationToken(id: "genshin-cn", generation: UUID(), kind: .updating)
        model.setGameState("genshin-cn", GameState(status: .installed(tag: "1"),
            activity: .working(.verifying, fraction: nil, bytesPerSecond: nil)))
        #expect(model.otherRegionActivity?.kind == .verifying)
        model.gameOperation = nil
        model.launchSlotOwner = "genshin-cn"; model.launchStates["genshin-cn"] = .running
        model.knownEndedLaunchGames.insert("genshin-cn")
        #expect(model.otherRegionActivity?.kind == .restoring)
    }

    @Test(arguments: [OtherRegionActivity.downloading, .updating, .verifying])
    func switchingRegionDoesNotCancelAnOperation(kind: OtherRegionActivity) async throws {
        let services = RegionGameServices(), model = model(services: services)
        await model.start()
        switch kind {
        case .downloading: model.installGame("genshin", voices: [], at: root, approved: true)
        case .updating: model.updateGame("genshin")
        default: model.verifyGame("genshin")
        }
        await services.operationStarted.wait()
        let token = model.gameOperation
        model.region = .mainlandChina
        await model.regionLoadTasks[.mainlandChina]?.value
        #expect(model.gameOperation == token)
        #expect(model.otherRegionActivity?.game.id == "genshin")
        #expect(model.otherRegionActivity?.kind == kind)
        #expect(await services.cancellations == 0)
        await services.completeOperation()
        await model.gameTask?.value
        #expect(model.otherRegionActivity == nil)
    }

    @Test func remoteRefreshIsLazyAndThrottledPerRegionWhileRecordsCoverSix() async {
        let services = RegionGameServices(), model = model(services: services)
        await model.start()
        #expect(Set(await services.statusReads) == Set(GameDefinition.inRegion(.global).map(\.id)))
        #expect(Set(await services.recordReads) == Set(GameDefinition.all.map(\.id)))
        #expect(model.gameRecord("genshin-cn") != nil)
        model.region = .mainlandChina
        await model.regionLoadTasks[.mainlandChina]?.value
        #expect(Set(await services.statusReads) == Set(GameDefinition.all.map(\.id)))
        #expect(model.games["starrail-cn"]?.status == .installed(tag: "1.0"))
        model.region = .global
        await model.regionLoadTasks[.global]?.value
        #expect(await services.statusReads.count == 6)
    }

    @Test func artLoadsBothCachesButRefreshesOnlySelectedRegionAndKeepsBoth() async {
        let global = RegionArt(id: "genshin"), cn = RegionArt(id: "genshin-cn")
        let model = model(art: [.global: global, .mainlandChina: cn])
        #expect(Set(model.gameArt.keys) == ["genshin", "genshin-cn"])
        await model.loadGameArt()
        #expect(global.refreshes == 1 && cn.refreshes == 0)
        #expect(global.hydrations == 1 && cn.hydrations == 1)
        #expect(model.gameArt["genshin"]?.background == global.fresh)
        model.region = .mainlandChina
        await model.loadGameArt()
        #expect(cn.refreshes == 1)
        #expect(model.gameArt["genshin-cn"]?.background == cn.fresh)
        #expect(model.gameArt["genshin"]?.background == global.fresh)
    }

    @Test func lateArtFromPreviousRegionCannotEraseCurrentRegionArt() async {
        let gate = RegionSignal(), entered = RegionSignal()
        let global = RegionArt(id: "genshin", gate: gate, entered: entered), cn = RegionArt(id: "genshin-cn")
        let model = model(art: [.global: global, .mainlandChina: cn])
        let first = Task { await model.loadGameArt() }
        await entered.wait()
        model.region = .mainlandChina
        await model.loadGameArt()
        #expect(model.gameArt["genshin-cn"]?.background == cn.fresh)
        await gate.signal(); await first.value
        #expect(model.gameArt["genshin"]?.background == global.fresh)
        #expect(model.gameArt["genshin-cn"]?.background == cn.fresh)
    }

    @Test func liveAdaptersNeverRequestCNMetadataUntilCNIsSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Region-Network-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app")), http = RegionHTTP()
        let store = GameRecordStore(directory: paths.games)
        for game in GameDefinition.all {
            let install = root.appendingPathComponent(game.id)
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: root)
                try fs.createDirectory(at: SafeRelativePath(game.id))
            }
            let record = GameRecord(installPath: install, ownership: .created, executable: try SafeRelativePath(game.executableName),
                installed: InstalledBuild(tag: "1.0", buildID: "old", categories: [], voices: []),
                installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
            try await store.save(record, for: game.id)
        }
        let art: [Region: any GameArtProviding] = Dictionary(uniqueKeysWithValues: Region.allCases.map {
            ($0, GameArtService(cacheDirectory: root.appendingPathComponent("cache"), region: $0, http: http))
        })
        let model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, artServices: art, gameServices: LiveGameServices(paths: paths, http: http), locale: Locale(identifier: "en_US"))
        await model.start(); await model.loadGameArt()
        #expect(!http.requests.isEmpty)
        #expect(http.requests.allSatisfy { $0.host == Region.global.hypAPIHost })
        model.region = .mainlandChina
        await model.regionLoadTasks[.mainlandChina]?.value
        #expect(http.requests.contains { $0.host == Region.mainlandChina.hypAPIHost })
    }

    #if DEBUG
    @Test func regionDebugFlagOverridesSelectionWithoutChangingPreference() throws {
        let name = "MacGacha-DebugRegionOnly-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Region.global.rawValue, forKey: "region")
        defaults.set("cn", forKey: "MacGachaDebugRegion")
        #expect(model(defaults: defaults).region == .mainlandChina)
        #expect(defaults.string(forKey: "region") == Region.global.rawValue)
    }

    @Test(arguments: ["playing", "launching", "launchFailed", "recoveryNeeded", "progress", "busy", "ready"])
    func debugRegionAndStatesUseVisibleGames(state: String) throws {
        let name = "MacGacha-DebugRegion-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cn", forKey: "MacGachaDebugRegion")
        defaults.set(state, forKey: "MacGachaDebugGameState")
        defaults.set(true, forKey: "MacGachaDebugRecoveryNotice")
        let model = try #require(AppModel.debugPreview(defaults: defaults))
        #expect(model.region == .mainlandChina)
        #expect(model.visibleGames.allSatisfy { $0.region == .mainlandChina })
        #expect(model.launchStates.keys.allSatisfy { $0.hasSuffix("-cn") })
        #expect(model.launchSlotOwner.map { $0.hasSuffix("-cn") } ?? true)
        #expect(model.recoveryNotices.first?.game == "starrail-cn")
    }
    #endif

    private var root: URL { URL(fileURLWithPath: "/inert/RegionTests") }
    private func model(defaults: UserDefaults? = nil, locale: Locale = Locale(identifier: "en_US"),
        services: any GameServices = RegionGameServices(), art: [Region: any GameArtProviding] = [:]) -> AppModel {
        AppModel(paths: AppPaths(root: root), manifest: try? RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: defaults, artServices: art, gameServices: services, locale: locale)
    }
}

private actor RegionSignal {
    private var signaled = false
    private var waits: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waits.append($0) }
    }
    func signal() { signaled = true; let pending = waits; waits = []; for wait in pending { wait.resume() } }
}

private actor RegionGameServices: GameServices {
    let operationStarted = RegionSignal()
    private var continuation: GameEventStream.Continuation?
    private(set) var statusReads: [String] = [], recordReads: [String] = []
    private(set) var cancellations = 0
    func start() async { }
    func waitUntilIdle(_ id: String) async throws {}
    func checkForUpdate(_ id: String) async throws -> GameStatus { status(id) }
    func status(_ id: String) -> GameStatus { statusReads.append(id); return .installed(tag: "1.0") }
    func record(_ id: String) throws -> GameRecord? {
        recordReads.append(id)
        return GameRecord(installPath: URL(fileURLWithPath: "/inert/\(id)"), ownership: .created,
            executable: try SafeRelativePath("Game.exe"), installed: InstalledBuild(tag: "1.0", buildID: "1", categories: [], voices: []),
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func estimate(_ id: String, voices: Set<String>, at location: URL) throws -> GameEstimate { throw LauncherError.cancelled }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> GameEventStream { await open() }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> GameEventStream { await open() }
    func update(_ id: String, approved: Bool) async -> GameEventStream { await open() }
    func resume(_ id: String, approved: Bool) async -> GameEventStream { await open() }
    func verify(_ id: String, mode: Verifier.Mode) async -> GameEventStream { await open() }
    func setVoices(_ id: String, _ voices: Set<String>) async -> GameEventStream { await open() }
    func uninstall(_ id: String) async throws { }
    private func open() async -> GameEventStream {
        let pair = GameEventStream.makeStream()
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.cancelled() } }
        }
        await operationStarted.signal()
        return pair.stream
    }
    private func cancelled() { cancellations += 1 }
    func completeOperation() { continuation?.yield(.phase(.completed)); continuation?.finish(); continuation = nil }
}

private final class RegionArt: GameArtProviding, Sendable {
    let id: String, fresh: URL
    private let gate: RegionSignal?, entered: RegionSignal?
    private let counts = Mutex((hydrations: 0, refreshes: 0))
    init(id: String, gate: RegionSignal? = nil, entered: RegionSignal? = nil) {
        self.id = id; self.gate = gate; self.entered = entered; fresh = URL(fileURLWithPath: "/fixture/\(id)-fresh.png")
    }
    var hydrations: Int { counts.withLock { $0.hydrations } }
    var refreshes: Int { counts.withLock { $0.refreshes } }
    func cached() -> [String: GameArt] { [id: GameArt(background: URL(fileURLWithPath: "/fixture/\(id)-cached.png"))] }
    func loadCached() async -> [String: GameArt] { counts.withLock { $0.hydrations += 1 }; return cached() }
    func refresh() async -> [String: GameArt] {
        counts.withLock { $0.refreshes += 1 }; await entered?.signal(); await gate?.wait()
        return [id: GameArt(background: fresh)]
    }
}

private final class RegionHTTP: HTTPClient, Sendable {
    private let urls = Mutex<[URL]>([])
    var requests: [URL] { urls.withLock { $0 } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        urls.withLock { $0.append(url) }; throw LauncherError.transport("offline fixture")
    }
}
