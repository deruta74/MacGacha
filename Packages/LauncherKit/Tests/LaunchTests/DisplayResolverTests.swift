// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import Launch

private let mainDisplay = "00000000-0000-0000-0000-000000000001"
private let secondDisplay = "00000000-0000-0000-0000-000000000002"

@Suite struct DisplayResolverTests {
    @Test func resolverSelectsMainChosenFallbackAndUnknownProbe() throws {
        var settings = LaunchSettings.defaults(for: "genshin")
        let main = try resolve("genshin", settings, displays: [mainDisplay, secondDisplay])
        #expect(Array(main.arguments.suffix(2)) == ["-monitor", "1"])
        #expect(!main.displayFallback)
        settings.display = DisplayChoice(id: secondDisplay, name: "Remembered screen")
        let chosen = try resolve("genshin", settings, displays: [mainDisplay, secondDisplay])
        #expect(Array(chosen.arguments.suffix(2)) == ["-monitor", "2"])
        #expect(!chosen.displayFallback)
        let fallback = try resolve("genshin", settings, displays: [mainDisplay])
        #expect(Array(fallback.arguments.suffix(2)) == ["-monitor", "1"])
        #expect(fallback.displayFallback)
        let unknown = try resolve("genshin", settings, displays: [])
        #expect(!unknown.arguments.contains("-monitor"))
        #expect(!unknown.displayFallback)
    }

    @Test(arguments: GameDefinition.all.map(\.id)) func exactArgumentsKeepGameBeforeUnityOptions(game: String) throws {
        let recipe = try #require(Recipes.recipe(for: game))
        var settings = LaunchSettings.defaults(for: game)
        settings.display = DisplayChoice(id: secondDisplay, name: "Screen")
        let gamePath = WinePath.windowsPath(for: recipe.executable.resolved(against: URL(fileURLWithPath: "/games")))
        var expected: [String]
        switch recipe.wrapper {
        case .none: expected = [gamePath]
        case .jadeite: expected = [#"Z:\components\jadeite\jadeite.exe"#, gamePath, "--"]
        case .steamShim: expected = [#"C:\windows\system32\steam.exe"#, gamePath]
        }
        expected += ["-monitor", "2"]
        if recipe.supportsDirectX12 && settings.directX12 { expected += ["-use-d3d12"] }
        #expect(try resolve(game, settings, displays: [mainDisplay, secondDisplay]).arguments == expected)
        settings.compatibilityPatches = false
        #expect(try resolve(game, settings, displays: [mainDisplay, secondDisplay]).arguments == [gamePath, "-monitor", "2"]
            + (recipe.supportsDirectX12 && settings.directX12 ? ["-use-d3d12"] : []))
    }

    private func resolve(_ game: String, _ settings: LaunchSettings, displays: [String]) throws -> ResolvedLaunch {
        try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: game)), settings: settings,
            installRoot: URL(fileURLWithPath: "/games"), prefix: URL(fileURLWithPath: "/prefix"),
            wineBinary: URL(fileURLWithPath: "/runtime/wine"), proxyPort: 1,
            componentRoots: [.jadeite: URL(fileURLWithPath: "/components/jadeite"), .steamShim: URL(fileURLWithPath: "/components/steam")],
            baseEnvironment: [:], displays: displays)
    }
}
