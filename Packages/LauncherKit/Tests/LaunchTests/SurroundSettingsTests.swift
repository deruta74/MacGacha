// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

@Suite struct SurroundSettingsTests {
    @Test func legacyDefaultsAndPerEditionRoundTrip() async throws {
        let old = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"backend":"d3dmetal"}"#.utf8))
        #expect(!old.surroundSound)
        for game in GameDefinition.all { #expect(!LaunchSettings.defaults(for: game.id).surroundSound) }
        try await BlockingIO.run {
            let temp = try TempDir(), store = LaunchSettingsStore(paths: AppPaths(root: temp.url))
            var chosen = LaunchSettings.defaults(for: "genshin"); chosen.surroundSound = true
            try store.save(chosen, for: "genshin")
            #expect(try store.load("genshin") == chosen)
            #expect(try !store.load("genshin-cn").surroundSound)
            #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(chosen)) == chosen)
        }
    }

    @Test(arguments: GameDefinition.all, [RuntimeBackend.dxmt, .d3dmetal])
    func eligibilityAndRequirementsShareOneRule(game: GameDefinition, backend: RuntimeBackend) throws {
        let eligible = game.family != .starrail && backend == .d3dmetal
        #expect(LaunchResolver.offersSurroundSound(game.id, backend: backend, runtimeBundleID: SurroundAudio.bundleID) == eligible)
        #expect(!LaunchResolver.offersSurroundSound(game.id, backend: backend, runtimeBundleID: "other"))
        let recipe = try #require(Recipes.recipe(for: game.id))
        var settings = LaunchSettings.defaults(for: game.id); settings.backend = backend; settings.compatibilityPatches = false
        #expect(!LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: SurroundAudio.bundleID).contains(.surroundAudio))
        settings.surroundSound = true
        #expect(LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: SurroundAudio.bundleID).contains(.surroundAudio) == eligible)
    }
}
