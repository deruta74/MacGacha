// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import Launch

@Suite struct GenshinFpsSettingsTests {
    @Test func oldGlobalPreferencesHaveNoAcknowledgmentAndRoundTripPreservesIt() throws {
        let old = try JSONDecoder().decode(GlobalLaunchSettings.self, from: Data(#"{"sessionLogsEnabled":false}"#.utf8))
        #expect(!old.genshinFpsRiskAcknowledged)
        var acknowledged = old; acknowledged.genshinFpsRiskAcknowledged = true
        #expect(try JSONDecoder().decode(GlobalLaunchSettings.self, from: JSONEncoder().encode(acknowledged)) == acknowledged)
    }
    @Test(arguments: GameDefinition.all) func requirementOnlyFollowsEligibleEnabledSetting(game: GameDefinition) throws {
        let recipe = try #require(Recipes.recipe(for: game.id))
        var settings = LaunchSettings.defaults(for: game.id); settings.compatibilityPatches = false
        #expect(!LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: "test").contains(.genshinFps))
        settings.unlockFPS = true
        #expect(LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: "test").contains(.genshinFps) == GenshinFps.applies(to: game.id))
    }
}
