// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

@Suite struct LaunchSettingsTests {
    @Test func legacySettingsDecodeWithUnlockOff() throws {
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"backend":"dxmt","frameLimit":60}"#.utf8))
        #expect(!settings.unlockFPS && settings.unlockTarget == 120)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["unlockFPS"] as? Bool == false && encoded["unlockTarget"] as? Int == 120)
    }
    @Test func unlockSettingsRoundTrip() throws {
        var settings = LaunchSettings.defaults(for: "genshin-cn")
        settings.unlockFPS = true; settings.unlockTarget = 360
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func ninetyIsAValidFrameLimit() throws {
        var settings = LaunchSettings.defaults(for: "genshin"); settings.frameLimit = 90
        try settings.validate()
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.frameLimit = 45
        #expect(throws: LauncherError.self) { try settings.validate() }
    }
    @Test(arguments: [60, 61, 120, 360, 361]) func unlockTargetBounds(target: Int) throws {
        var settings = LaunchSettings.defaults(for: "genshin"); settings.unlockFPS = true; settings.unlockTarget = target
        if (61...360).contains(target) { try settings.validate() }
        else { #expect(throws: LauncherError.self) { try settings.validate() } }
    }
    @Test(arguments: ["starrail", "starrail-cn"]) func starRailOnlyUnlocksTo120(game: String) async throws {
        var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = true
        try settings.validate(for: game)
        settings.unlockTarget = 90
        #expect(throws: LauncherError.self) { try settings.validate(for: game) }
        let invalid = settings
        try await BlockingIO.run {
            let root = try TempDir(), paths = AppPaths(root: root.url)
            #expect(throws: LauncherError.self) { try LaunchSettingsStore(paths: paths).save(invalid, for: game) }
            let decoder = JSONDecoder(); decoder.userInfo[LaunchSettings.gameKey] = game
            #expect(throws: LauncherError.self) { try decoder.decode(LaunchSettings.self, from: JSONEncoder().encode(invalid)) }
        }
    }
}
