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
    @Test func offeredDecimalLimitsPersistAndSerializeWithOtherGlobalWrites() async throws {
        let preferences = SpeedPreferences(), model = try fixture(preferences)
        #expect(AppModel.downloadSpeedLimitOptions == [nil, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000])
        #expect(model.downloadSpeedLimit == nil)
        for limit in AppModel.downloadSpeedLimitOptions {
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
        for invalid: Int64 in [-1, 0, 5, 5_242_880, Int64.max] {
            #expect(throws: LauncherError.self) { try model.setDownloadSpeedLimit(invalid) }
        }
        #expect(model.downloadSpeedLimit == nil)
        model.setLanguageRestart(UUID())
        #expect(throws: LauncherError.busy("Application language restart is in progress")) {
            try model.setDownloadSpeedLimit(5_000_000)
        }
        #expect(model.downloadSpeedLimit == nil)
        #expect(preferences.writes == 0)
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
