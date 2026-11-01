// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
import Launch
@testable import MacGacha

@Suite @MainActor struct GenshinFpsModelTests {
    @Test func defaultsRequireAcknowledgmentAndPersistItAcrossEditions() async throws {
        let preferences = FpsPreferences(), model = try fixture(preferences)
        #expect(!model.genshinFpsRiskAcknowledged)
        #expect(!model.genshinFpsUnlock(for: "genshin"))
        #expect(model.genshinFpsTarget(for: "genshin") == 120)
        #expect(throws: LauncherError.genshinFpsRiskNotAcknowledged) {
            try model.setGenshinFpsUnlock(true, for: "genshin")
        }
        var bypass = LaunchSettings.defaults(for: "genshin"); bypass.unlockFPS = true
        #expect(throws: LauncherError.genshinFpsRiskNotAcknowledged) { try model.saveLaunchSettings(bypass, for: "genshin") }
        #expect(!model.genshinFpsUnlock(for: "genshin"))
        model.acknowledgeGenshinFpsRisk()
        try model.setGenshinFpsUnlock(true, for: "genshin-cn")
        try await model.flushLaunchSettings()
        let second = try fixture(preferences)
        await second.reattachOnStart()
        #expect(second.genshinFpsRiskAcknowledged)
        #expect(second.genshinFpsUnlock(for: "genshin-cn"))
        #expect(!second.genshinFpsUnlock(for: "genshin"))
        #expect(second.offersGenshinFps(for: "genshin") && second.offersGenshinFps(for: "genshin-cn"))
        for id in ["starrail", "starrail-cn", "zzz", "zzz-cn", "unknown"] { #expect(!second.offersGenshinFps(for: id)) }
    }

    @Test(arguments: [61, 90, 91, 120, 121, 360]) func enablingRaisesOnlyALowerLimit(target: Int) async throws {
        let model = try fixture(); model.acknowledgeGenshinFpsRisk()
        try model.setGenshinFpsTarget(target, for: "genshin")
        try model.setGenshinFpsUnlock(true, for: "genshin")
        #expect(model.launchSettings(for: "genshin").frameLimit == (target <= 90 ? 90 : target <= 120 ? 120 : nil))
        var settings = model.launchSettings(for: "genshin"); settings.frameLimit = 30
        try model.saveLaunchSettings(settings, for: "genshin")
        try model.setGenshinFpsUnlock(true, for: "genshin")
        #expect(model.launchSettings(for: "genshin").frameLimit == 30) // The user's later cap wins.
        try model.setGenshinFpsUnlock(false, for: "genshin")
        #expect(model.launchSettings(for: "genshin").frameLimit == 30)
        try await model.flushLaunchSettings()
    }

    @Test func targetClampsAndOffLimitStaysOff() async throws {
        let model = try fixture(); model.acknowledgeGenshinFpsRisk()
        try model.setGenshinFpsTarget(Int.min, for: "genshin")
        #expect(model.genshinFpsTarget(for: "genshin") == 61)
        try model.setGenshinFpsTarget(Int.max, for: "genshin")
        #expect(model.genshinFpsTarget(for: "genshin") == 360)
        var settings = model.launchSettings(for: "genshin"); settings.frameLimit = nil
        try model.saveLaunchSettings(settings, for: "genshin")
        try model.setGenshinFpsUnlock(true, for: "genshin")
        #expect(model.launchSettings(for: "genshin").frameLimit == nil)
        try await model.flushLaunchSettings()
    }

    @Test func restartReservationRefusesAllChangesAndStarRailIsUnchanged() async throws {
        let model = try fixture()
        var starRail = LaunchSettings.defaults(for: "starrail"); starRail.unlockFPS = true
        try model.saveLaunchSettings(starRail, for: "starrail")
        #expect(model.launchSettings(for: "starrail").frameLimit == 60)
        model.setLanguageRestart(UUID())
        model.acknowledgeGenshinFpsRisk()
        #expect(!model.genshinFpsRiskAcknowledged)
        #expect(throws: (any Error).self) { try model.setGenshinFpsUnlock(false, for: "genshin") }
        #expect(throws: (any Error).self) { try model.setGenshinFpsTarget(90, for: "genshin") }
        #expect(model.genshinFpsTarget(for: "genshin") == 120)
        try await model.flushLaunchSettings()
    }

    @Test func setupRequirementOnlyAppearsWhenEnabled() async throws {
        let model = try fixture()
        #expect(model.runtimeSetupPlan(for: "genshin")?.items.contains { $0.id == GenshinFps.componentID } == false)
        model.acknowledgeGenshinFpsRisk()
        try model.setGenshinFpsUnlock(true, for: "genshin")
        #expect(model.runtimeSetupPlan(for: "genshin")?.items.contains { $0.id == GenshinFps.componentID } == true)
        #expect(model.missingComponents(for: "genshin"))
        #expect(model.runtimeSetupPlan(for: "genshin-cn")?.items.contains { $0.id == GenshinFps.componentID } == false)
        try model.setGenshinFpsUnlock(false, for: "genshin")
        #expect(model.runtimeSetupPlan(for: "genshin")?.items.contains { $0.id == GenshinFps.componentID } == false)
        try await model.flushLaunchSettings()
    }

    private func fixture(_ preferences: FpsPreferences = FpsPreferences()) throws -> AppModel {
        let url = try #require(Bundle.main.url(forResource: "runtime-manifest", withExtension: "json"))
        return AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/FpsSettings")),
            manifest: try RuntimeManifest.load(from: url), services: PreviewRuntimeServices(), defaults: nil,
            launchPreferences: preferences)
    }
}

private final class FpsPreferences: LaunchPreferencesPersistence, Sendable {
    private struct Values { var games: [String: LaunchSettings] = [:]; var global = GlobalLaunchSettings() }
    private let values = Mutex(Values())
    func loadGames() throws -> [String: LaunchSettings] { values.withLock { $0.games } }
    func loadGlobal() throws -> GlobalLaunchSettings { values.withLock { $0.global } }
    func save(_ settings: LaunchSettings, game: String) throws { values.withLock { $0.games[game] = settings } }
    func saveGlobal(_ settings: GlobalLaunchSettings) throws { values.withLock { $0.global = settings } }
}
