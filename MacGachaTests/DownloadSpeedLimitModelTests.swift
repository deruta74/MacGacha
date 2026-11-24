// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import Launch
import RuntimeManager
@testable import DownloadEngine
@testable import MacGacha

@Suite @MainActor struct DownloadSpeedLimitModelTests {
    @Test func gameplayPreferencesPersistAndReservedLaunchUsesTheSmallerCap() async throws {
        let preferences = SpeedPreferences(), model = try fixture(preferences)
        #expect(!model.downloadWhilePlaying)
        #expect(model.playingDownloadSpeedLimit == 10_000_000)
        try model.setDownloadWhilePlaying(true)
        try model.setPlayingDownloadSpeedLimit(3_000_000)
        try model.setDownloadSpeedLimit(8_000_000)
        #expect(model.effectiveDownloadSpeedLimit == 8_000_000)
        model.launchSlotOwner = "genshin"
        #expect(model.effectiveDownloadSpeedLimit == 3_000_000)
        try model.setDownloadSpeedLimit(1_000_000)
        #expect(model.effectiveDownloadSpeedLimit == 1_000_000)
        try model.setDownloadSpeedLimit(nil)
        #expect(model.effectiveDownloadSpeedLimit == 3_000_000)
        model.launchSlotOwner = nil
        #expect(model.effectiveDownloadSpeedLimit == nil)
        try await model.flushLaunchSettings()
        let second = try fixture(preferences)
        await second.reattachOnStart()
        #expect(second.downloadWhilePlaying)
        #expect(second.playingDownloadSpeedLimit == 3_000_000)
    }

    @Test func failedGameplayPreferenceWriteRestoresDurableValuesWhileReserved() async throws {
        let preferences = SpeedPreferences(), model = try fixture(preferences)
        try model.setDownloadWhilePlaying(true)
        try model.setPlayingDownloadSpeedLimit(3_000_000)
        try await model.flushLaunchSettings()
        model.launchSlotOwner = "genshin"
        preferences.failWrites = true
        try model.setDownloadWhilePlaying(false)
        try model.setPlayingDownloadSpeedLimit(8_000_000)
        await #expect(throws: LauncherError.self) { try await model.flushLaunchSettings() }
        #expect(model.downloadWhilePlaying)
        #expect(model.playingDownloadSpeedLimit == 3_000_000)
        #expect(model.effectiveDownloadSpeedLimit == 3_000_000)
    }

    @Test func reservedLaunchChangesTheLiveLimiterAndExitRestoresUnlimited() async throws {
        let preferences = SpeedPreferences(), limiter = DownloadRateLimiter()
        let model = try fixture(preferences, limiter: limiter)
        try model.setPlayingDownloadSpeedLimit(100_000)
        try await model.flushLaunchSettings()
        #expect(!limiter.isLimited)
        model.launchSlotOwner = "genshin"
        #expect(limiter.isLimited)
        #expect(try await limiter.acquire(upTo: 100_000) == 10_000)
        model.launchSlotOwner = nil
        #expect(!limiter.isLimited)
        #expect(try await limiter.acquire(upTo: 100_000) == 100_000)
    }

    @Test func customDecimalLimitsPersistAndSerializeWithOtherGlobalWrites() async throws {
        let preferences = SpeedPreferences(), model = try fixture(preferences)
        #expect(model.downloadSpeedLimit == nil)
        let limits: [Int64?] = [nil, 100_000, 2_500_000, 7_300_000, 10_000_000, 250_000_000, 10_000_000_000]
        for limit in limits {
            try model.setDownloadSpeedLimit(limit)
            #expect(model.downloadSpeedLimit == limit)
            model.gameModeEnabled = false
            model.sessionLogsEnabled = false
            try await model.flushLaunchSettings()
            let second = try fixture(preferences)
            await second.reattachOnStart()
            #expect(second.downloadSpeedLimit == limit)
            #expect(!second.gameModeEnabled && !second.sessionLogsEnabled)
        }
    }

    @Test func invalidValuesAndRestartReservationRefuseChanges() async throws {
        let preferences = SpeedPreferences(), model = try fixture(preferences)
        for invalid: Int64 in [-1, 0, 5, 99_999, 5_242_880, 10_000_100_000, Int64.max] {
            #expect(throws: LauncherError.self) { try model.setDownloadSpeedLimit(invalid) }
            #expect(throws: LauncherError.self) { try model.setPlayingDownloadSpeedLimit(invalid) }
        }
        #expect(model.downloadSpeedLimit == nil)
        model.setLanguageRestart(UUID())
        #expect(throws: LauncherError.busy("Application language restart is in progress")) {
            try model.setDownloadSpeedLimit(5_000_000)
        }
        #expect(throws: LauncherError.busy("Application language restart is in progress")) {
            try model.setPlayingDownloadSpeedLimit(5_000_000)
        }
        #expect(throws: LauncherError.busy("Application language restart is in progress")) {
            try model.setDownloadWhilePlaying(true)
        }
        #expect(model.downloadSpeedLimit == nil)
        #expect(!model.downloadWhilePlaying)
        #expect(model.playingDownloadSpeedLimit == 10_000_000)
        #expect(preferences.writes == 0)
    }

    @Test(arguments: [(0.0, 100_000), (0.04, 100_000), (0.15, 200_000), (7.3, 7_300_000), (12.34, 12_300_000),
        (10_000, 10_000_000_000), (1e300, 10_000_000_000), (-5, 100_000), (.nan, 100_000), (.infinity, 10_000_000_000)] as [(Double, Int64)])
    func typedMegabytesRoundToAValidLimit(typed: Double, expected: Int64) throws {
        #expect(AppModel.downloadSpeedLimit(megabytesPerSecond: typed) == expected)
        let model = try fixture(SpeedPreferences())
        try model.setDownloadSpeedLimit(AppModel.downloadSpeedLimit(megabytesPerSecond: typed))
    }

    @Test func failedWriteRollsBackObservableLimitAndLiveBucket() async throws {
        let preferences = SpeedPreferences(), clock = NativeWindowClock()
        let limiter = DownloadRateLimiter(clock: clock)
        let model = try fixture(preferences, limiter: limiter)
        try model.setDownloadSpeedLimit(5_000_000)
        try await model.flushLaunchSettings()
        let observed = TestEventBox()
        withObservationTracking { _ = model.downloadSpeedLimit } onChange: { observed.changed.withLock { $0 = true } }
        preferences.failWrites = true
        try model.setDownloadSpeedLimit(10_000_000)
        #expect(model.downloadSpeedLimit == 10_000_000)
        #expect(observed.changed.withLock { $0 })
        await #expect(throws: LauncherError.self) { try await model.flushLaunchSettings() }
        #expect(model.downloadSpeedLimit == 5_000_000)
        // The old 500,000-byte burst survives the rollback, without new credit.
        var consumed = 0
        while consumed < 500_000 { consumed += try await limiter.acquire(upTo: 500_000 - consumed) }
        let read = Task { try await limiter.acquire(upTo: 100) }
        await clock.waitForSleep(.seconds(100.0 / 5_000_000))
        read.cancel()
        await #expect(throws: (any Error).self) { try await read.value }
        preferences.failWrites = false
        try model.setDownloadSpeedLimit(nil)
        try await model.flushLaunchSettings()
        #expect(try await limiter.acquire(upTo: 1_000_000) == 1_000_000)
    }

    @Test func persistedStartupLimitReachesLiveService() async throws {
        let preferences = SpeedPreferences(), limiter = DownloadRateLimiter()
        var saved = GlobalLaunchSettings(); saved.downloadSpeedLimit = 5_000_000
        try preferences.saveGlobal(saved)
        let model = try fixture(preferences, limiter: limiter)
        await model.reattachOnStart()
        #expect(model.downloadSpeedLimit == 5_000_000)
        #expect(try await limiter.acquire(upTo: 1_000_000) == 65_536)
    }

    private func fixture(_ preferences: SpeedPreferences, limiter: DownloadRateLimiter = DownloadRateLimiter()) throws -> AppModel {
        AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/SpeedLimit")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            gameServices: LiveGameServices(paths: AppPaths(root: URL(fileURLWithPath: "/inert/SpeedLimit")), downloadRateLimiter: limiter),
            launchPreferences: preferences)
    }
}

private final class TestEventBox: Sendable { let changed = Mutex(false) }
private final class SpeedPreferences: LaunchPreferencesPersistence, Sendable {
    private struct State { var global = GlobalLaunchSettings(); var fail = false; var writes = 0 }
    private let state = Mutex(State())
    var failWrites: Bool {
        get { state.withLock { $0.fail } }
        set { state.withLock { $0.fail = newValue } }
    }
    var writes: Int { state.withLock { $0.writes } }
    func loadGames() throws -> [String: LaunchSettings] { [:] }
    func loadGlobal() throws -> GlobalLaunchSettings { state.withLock { $0.global } }
    func save(_ settings: LaunchSettings, game: String) throws {}
    func saveGlobal(_ settings: GlobalLaunchSettings) throws {
        try state.withLock {
            if $0.fail { throw LauncherError.io("Injected preference failure") }
            $0.global = settings; $0.writes += 1
        }
    }
}
