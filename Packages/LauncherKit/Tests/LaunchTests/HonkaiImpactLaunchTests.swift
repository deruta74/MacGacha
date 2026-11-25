// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import Testing
@testable import Launch

@Suite struct HonkaiImpactLaunchTests {
    @Test func globalEditionAndRecipe() throws {
        let game = try #require(GameDefinition.find("hi3"))
        #expect(game.family == .honkaiImpact && game.region == .global)
        #expect(game.biz == "bh3_global" && game.gameID == "5TIVvvcwtM")
        #expect(game.executableName == "BH3.exe" && game.dataDirectoryName == "BH3_Data")
        #expect(game.defaultInstallDirectoryName == "Honkai Impact 3rd")
        #expect(game.unityLogProductName == "Honkai Impact 3rd")
        #expect(game.screenshotsPath.description == "ScreenShot")
        #expect(game.voices.isEmpty)
        let recipe = try #require(Recipes.recipe(for: game.id))
        #expect(recipe.verifiedBuilds == ["9.1.0"])
        #expect(recipe.executable.description == "BH3.exe" && recipe.wrapper == .steamShim)
        #expect(recipe.hidden.map(\.description) == ["BH3_Data/Plugins/crashreport.exe", "BH3_Data/Plugins/vulkan-1.dll"])
        #expect(recipe.copyIfPresent.map { $0.source.description } == ["HoYoKProtect.sys"])
        #expect(recipe.copyIfPresent.map { $0.toSystem32 } == ["HoYoKProtect.sys"])
        #expect(recipe.blockedHosts.isEmpty && !recipe.timeoutFix && !recipe.supportsDirectX12)
        #expect(recipe.gameLogPaths.map(\.description) == [
            "AppData/LocalLow/miHoYo/Honkai Impact 3rd/Player.log",
            "AppData/LocalLow/miHoYo/Honkai Impact 3rd/output_log.txt",
            "AppData/LocalLow/Cognosphere/Honkai Impact 3rd/Player.log",
            "AppData/LocalLow/Cognosphere/Honkai Impact 3rd/output_log.txt"
        ])
    }

    @Test func allServersUseSeparateIdentitiesAndTheSameRecipe() throws {
        let editions = GameDefinition.inRegion(.global).filter { $0.family == .honkaiImpact }
        #expect(editions.map(\.id) == ["hi3", "hi3-jp", "hi3-kr", "hi3-sea", "hi3-tw"])
        #expect(editions.map(\.gameID) == ["5TIVvvcwtM", "g0mMIvshDb", "uxB4MC7nzC", "bxPTXSET5t", "wkE5P5WsIf"])
        #expect(editions.map(\.defaultInstallDirectoryName) == [
            "Honkai Impact 3rd", "Houkai3rd", "Honkai Impact 3rd kr", "Honkai Impact 3", "Honkai Impact 3rd asia"
        ])
        #expect(editions.map(\.unityLogProductName) == ["Honkai Impact 3rd", "崩壊3rd", "붕괴3rd", "Honkai Impact 3", "崩壊3rd"])
        #expect(editions.allSatisfy { $0.voices.isEmpty && $0.biz == "bh3_global" })
        #expect(GameDefinition.inRegion(.mainlandChina).allSatisfy { $0.family != .honkaiImpact })
        let base = try #require(Recipes.recipe(for: "hi3"))
        for edition in editions {
            let recipe = try #require(Recipes.recipe(for: edition.id))
            #expect(recipe.executable == base.executable && recipe.wrapper == .steamShim)
            #expect(recipe.hidden == base.hidden && recipe.copyIfPresent.count == 1)
            #expect(recipe.verifiedBuilds == (edition.id == "hi3" ? ["9.1.0"] : []))
            let settings = LaunchSettings.defaults(for: edition.id)
            let launch = try LaunchResolver.resolve(recipe: recipe, settings: settings,
                installRoot: URL(filePath: "/games/\(edition.defaultInstallDirectoryName)"), prefix: URL(filePath: "/prefix"),
                wineBinary: URL(filePath: "/wine"), proxyPort: 1234,
                componentRoots: [.steamShim: URL(filePath: "/steam-shim")], baseEnvironment: [:])
            #expect(launch.preparation.windowsVersion == .win11 && launch.requiredComponents == [.steamShim])
            #expect(launch.environment["WINEESYNC"] == "1")
        }
    }

    @Test(arguments: [RuntimeBackend.d3dmetal, .dxmt])
    func resolvesSteamShimAndGenericSettings(backend: RuntimeBackend) throws {
        let recipe = try #require(Recipes.recipe(for: "hi3"))
        let shim = URL(filePath: "/steam-shim")
        let bundle = "d3dmetal-wine11.22mg1.0-gptk4.0b3"
        var settings = LaunchSettings.defaults(for: "hi3")
        #expect(settings.backend == .d3dmetal && !settings.directX12)
        settings.backend = backend
        #expect(recipe.isVerified(build: "9.1.0", settings: settings, runtimeBundleID: bundle) == (backend == .d3dmetal))
        #expect(!recipe.isVerified(build: "9.0.0", settings: settings, runtimeBundleID: bundle))
        #expect(!recipe.isVerified(build: "9.1.0", settings: settings, runtimeBundleID: Crypt32Fix.bundleID))
        settings.directX12 = true
        settings.unlockFPS = true
        settings.surroundSound = true
        settings.metalHUD = true
        let launch = try LaunchResolver.resolve(recipe: recipe, settings: settings,
            installRoot: URL(filePath: "/games/Honkai Impact 3rd"), prefix: URL(filePath: "/prefix"),
            wineBinary: URL(filePath: "/runtime/bin/wine"), proxyPort: 1234, componentRoots: [.steamShim: shim],
            baseEnvironment: [:], runtimeBundleID: bundle, displays: ["main"], genshinFpsRiskAcknowledged: true)
        #expect(launch.arguments == [#"C:\windows\system32\steam.exe"#, #"Z:\games\Honkai Impact 3rd\BH3.exe"#, "-monitor", "1"])
        #expect(launch.environment["WINEESYNC"] == (backend == .d3dmetal ? "1" : nil))
        #expect(launch.environment["WINEMSYNC"] == (backend == .dxmt ? "1" : nil))
        #expect(launch.environment["MTL_HUD_ENABLED"] == "1")
        #expect(launch.environment["WINE_ENABLE_TIMEOUT_FIX"] == nil && launch.environment["MACGACHA_SURROUND"] == nil)
        #expect(launch.hidden == recipe.hidden && launch.copyIfPresent.count == 1 && launch.blockedHosts.isEmpty)
        #expect(launch.requiredComponents == [.steamShim] && launch.componentCopies.isEmpty && launch.fpsInjector == nil)
        #expect(launch.preparation.steamShim == shim && launch.preparation.windowsVersion == .win11)
        #expect(launch.preparation.starRailFrameRate == nil && !launch.preparation.crypt32Native && !launch.preparation.wpfSoftwareRendering)
        #expect(!LaunchResolver.offersStarRailUnlock("hi3"))
        #expect(!LaunchResolver.offersSurroundSound("hi3", backend: backend, runtimeBundleID: bundle))
        #expect(!Crypt32Fix.applies(game: "hi3", backend: backend, bundleID: Crypt32Fix.bundleID))
    }
}
