// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import Launch

@Suite struct GenshinFpsResolverTests {
    @Test(arguments: ["genshin", "genshin-cn"], [RuntimeBackend.d3dmetal, .dxmt])
    func injectorUsesExactWineRouteEnvironmentAndAdjacentDLL(game: String, backend: RuntimeBackend) throws {
        for mirror in [false, true] {
            var settings = LaunchSettings.defaults(for: game); settings.backend = backend; settings.unlockFPS = true; settings.unlockTarget = 144
            let root = URL(fileURLWithPath: "/Components/FPS helper"), wine = URL(fileURLWithPath: "/Runtime/bin/wine")
            let helper = GameModeRuntime(game: GameDefinition.find(game)!, root: URL(fileURLWithPath: "/Runtime/mirror/Contents"),
                wineBinary: URL(fileURLWithPath: "/Runtime/mirror/Contents/MacOS/wine-wrapper"),
                wineserver: URL(fileURLWithPath: "/Runtime/mirror/Contents/bin/wineserver"))
            let resolved = try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: game)), settings: settings,
                installRoot: URL(fileURLWithPath: "/Games/Genshin"), prefix: URL(fileURLWithPath: "/Prefixes/Genshin"),
                wineBinary: wine, proxyPort: 1234, componentRoots: [.genshinFps: root, .steamShim: URL(fileURLWithPath: "/Shim")],
                baseEnvironment: ["UNSAFE": "must not inherit"], runtimeBundleID: "test", gameModeRuntime: mirror ? helper : nil,
                genshinFpsRiskAcknowledged: true)
            let injector = try #require(resolved.fpsInjector)
            #expect(injector.executable == resolved.executable)
            #expect(injector.arguments == [#"Z:\Components\FPS helper\fpsinject.exe"#, "--target", "144"])
            #expect(injector.currentDirectory == root)
            #expect(injector.environment == resolved.environment)
            #expect(injector.environment["WINEPREFIX"] == "/Prefixes/Genshin")
            #expect(injector.environment["UNSAFE"] == nil)
            #expect(injector.environment["WINELOADER"] == (mirror ? helper.loader.path : nil))
            #expect(resolved.requiredComponents.contains(.genshinFps))
        }
    }

    @Test func noAcknowledgmentNoInjectorAndDisabledNeedsNoComponent() throws {
        var settings = LaunchSettings.defaults(for: "genshin"); settings.compatibilityPatches = false; settings.unlockFPS = true
        let root = URL(fileURLWithPath: "/FPS")
        func resolve(_ settings: LaunchSettings, roots: [ComponentKind: URL]) throws -> ResolvedLaunch {
            try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: "genshin")), settings: settings,
                installRoot: root, prefix: root, wineBinary: root.appendingPathComponent("wine"),
                proxyPort: 1, componentRoots: roots, baseEnvironment: [:])
        }
        #expect(try resolve(settings, roots: [.genshinFps: root]).fpsInjector == nil)
        #expect(throws: LauncherError.self) { try resolve(settings, roots: [:]) }
        settings.unlockFPS = false
        let off = try resolve(settings, roots: [:])
        #expect(off.fpsInjector == nil && !off.requiredComponents.contains(.genshinFps))
    }

    @Test(arguments: ["starrail", "starrail-cn", "zzz", "zzz-cn"])
    func otherGamesNeverBuildAnInjector(game: String) throws {
        var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = true; settings.compatibilityPatches = false
        let root = URL(fileURLWithPath: "/Test")
        let resolved = try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: game)), settings: settings,
            installRoot: root, prefix: root, wineBinary: root.appendingPathComponent("wine"), proxyPort: 1,
            componentRoots: [:], baseEnvironment: [:], genshinFpsRiskAcknowledged: true)
        #expect(resolved.fpsInjector == nil)
        #expect(!resolved.requiredComponents.contains(.genshinFps))
    }
}
