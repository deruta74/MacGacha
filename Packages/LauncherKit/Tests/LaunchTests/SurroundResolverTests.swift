// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import Launch

@Suite struct SurroundResolverTests {
    @Test(arguments: [false, true], [false, true])
    func environmentOnlyOptsInWithTheRequestedModule(gameMode: Bool, audio: Bool) throws {
        let game = GameDefinition.find("genshin")!, recipe = try #require(Recipes.recipe(for: game.id))
        var settings = LaunchSettings.defaults(for: game.id); settings.compatibilityPatches = false; settings.surroundSound = audio
        let root = URL(fileURLWithPath: "/Runtimes/GameMode/helper/Contents"), component = URL(fileURLWithPath: "/Runtimes/surroundAudio/wine-11.20-1")
        let module = SurroundAudio.modulePath.resolved(against: component)
        for actual in [Optional<URL>.none, module, URL(fileURLWithPath: "/foreign/module.so")] {
            let helper = GameModeRuntime(game: game, root: root, wineBinary: root.appendingPathComponent("MacOS/wine-wrapper"),
                wineserver: root.appendingPathComponent("bin/wineserver"), gameModeEnabled: gameMode, surroundModule: actual)
            let result = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: URL(fileURLWithPath: "/game"),
                prefix: URL(fileURLWithPath: "/prefix"), wineBinary: URL(fileURLWithPath: "/runtime/wine"), proxyPort: 1,
                componentRoots: [.surroundAudio: component], baseEnvironment: ["MACGACHA_SURROUND": "1"], runtimeBundleID: SurroundAudio.bundleID,
                gameModeRuntime: helper, gameModeEnabled: gameMode)
            let active = audio && actual == module
            #expect(result.environment["MACGACHA_SURROUND"] == (active ? "1" : nil))
            #expect(result.executable == ((gameMode || active) ? helper.wineBinary : URL(fileURLWithPath: "/runtime/wine")))
        }
        if audio {
            #expect(throws: (any Error).self) {
                try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: URL(fileURLWithPath: "/game"), prefix: URL(fileURLWithPath: "/prefix"),
                    wineBinary: URL(fileURLWithPath: "/runtime/wine"), proxyPort: 1, componentRoots: [:], baseEnvironment: [:], runtimeBundleID: SurroundAudio.bundleID)
            }
        }
    }
}
