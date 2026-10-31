// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import Launch

private let installRoot = URL(fileURLWithPath: "/Users/x/Games/MacGacha/Honkai: Star Rail", isDirectory: true)
private let prefix = URL(fileURLWithPath: "/Prefixes/game-bundle", isDirectory: true)
private let wine = URL(fileURLWithPath: "/Runtimes/bundle/bin/wine")
private let roots: [ComponentKind: URL] = [.jadeite: URL(fileURLWithPath: "/Components/jadeite 4.1.0"),
    .steamShim: URL(fileURLWithPath: "/Components/steam-shim")]

private func resolve(_ game: String, settings: LaunchSettings? = nil, components: [ComponentKind: URL] = roots,
    base: [String: String] = [:]) throws -> ResolvedLaunch {
    try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: game)), settings: settings ?? .defaults(for: game),
        installRoot: installRoot, prefix: prefix, wineBinary: wine, proxyPort: 12345,
        componentRoots: components, baseEnvironment: base)
}

@Test func genshinDefaultsD3DMetal() throws {
    let value = try resolve("genshin")
    #expect(value.executable == wine)
    #expect(value.currentDirectory == installRoot)
    #expect(value.arguments == [#"C:\windows\system32\steam.exe"#, #"Z:\Users\x\Games\MacGacha\Honkai: Star Rail\GenshinImpact.exe"#])
    #expect(value.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "WINEPREFIX": prefix.path,
        "D3DM_MAX_FPS": "60", "WINE_ENABLE_TIMEOUT_FIX": "1", "WINEESYNC": "1", "WINEDLLOVERRIDES": "", "WINEDEBUG": "fixme-all",
        "HTTP_PROXY": "http://127.0.0.1:12345", "HTTPS_PROXY": "http://127.0.0.1:12345",
        "http_proxy": "http://127.0.0.1:12345", "https_proxy": "http://127.0.0.1:12345"])
    #expect(value.hidden.map(\.description) == ["GenshinImpact_Data/upload_crash.exe", "GenshinImpact_Data/Plugins/crashreport.exe", "GenshinImpact_Data/Plugins/vulkan-1.dll"])
    #expect(value.blockedHosts.isEmpty)
    #expect(value.copyIfPresent.count == 1)
    #expect(value.copyIfPresent.first?.source.description == "HoYoKProtect.sys")
    #expect(value.copyIfPresent.first?.toSystem32 == "HoYoKProtect.sys")
    #expect(value.requiredComponents == [.steamShim])
    #expect(value.preparation == PreparationRequest(retina: false, steamShim: roots[.steamShim], dxmtExtras: [], nvidiaKeys: false))
}

@Test func starRailDefaults() throws {
    let value = try resolve("starrail")
    #expect(value.arguments == [#"Z:\Components\jadeite 4.1.0\jadeite.exe"#, #"Z:\Users\x\Games\MacGacha\Honkai: Star Rail\StarRail.exe"#])
    #expect(value.blockedHosts == ["globaldp-prod-os01.starrails.com"])
    #expect(value.hidden.map(\.description) == ["StarRail_Data/Plugins/x86_64/crashreport.exe", "StarRail_Data/Plugins/x86_64/vulkan-1.dll"])
    #expect(value.environment["D3DM_MAX_FPS"] == "60")
    #expect(value.environment["WINE_ENABLE_TIMEOUT_FIX"] == nil)
    #expect(value.requiredComponents == [.jadeite])
    #expect(value.copyIfPresent.isEmpty)
}

@Test(arguments: [RuntimeBackend.d3dmetal, .dxmt]) func zzzDirectX12(backend: RuntimeBackend) throws {
    var settings = LaunchSettings.defaults(for: "zzz"); settings.backend = backend
    let value = try resolve("zzz", settings: settings)
    #expect(value.arguments == [#"C:\windows\system32\steam.exe"#, #"Z:\Users\x\Games\MacGacha\Honkai: Star Rail\ZenlessZoneZero.exe"#]
        + (backend == .d3dmetal ? ["-use-d3d12"] : []))
    #expect(value.environment["WINE_ENABLE_TIMEOUT_FIX"] == "1")
    #expect(value.hidden.map(\.description) == ["ZenlessZoneZero_Data/Plugins/x86_64/vulkan-1.dll"])
    #expect(value.copyIfPresent.first?.source.description == "HoYoKProtect.sys")
    #expect(value.blockedHosts.isEmpty)
    settings.directX12 = false
    #expect(try !resolve("zzz", settings: settings).arguments.contains("-use-d3d12"))
}

@Test(arguments: ["genshin", "starrail", "zzz"], [Int?.none, 30, 60, 90, 120]) func dxmtFrameLimit(game: String, limit: Int?) throws {
    var settings = LaunchSettings.defaults(for: game); settings.backend = .dxmt; settings.frameLimit = limit; settings.retina = true
    let value = try resolve(game, settings: settings)
    let config = value.environment["DXMT_CONFIG"] ?? ""
    #expect(config.contains("d3d11.preferredMaxFrameRate=") == (limit != nil))
    if let limit { #expect(config.contains("d3d11.preferredMaxFrameRate=\(limit)")) }
    #expect(value.environment["D3DM_MAX_FPS"] == nil)
    #expect(value.environment["WINEESYNC"] == nil)
    #expect(value.environment["WINEMSYNC"] == "1")
    #expect(value.environment["GST_PLUGIN_FEATURE_RANK"] == "atdec:MAX,avdec_h264:MAX")
    #expect(value.preparation.retina)
    #expect(value.preparation.dxmtExtras == (game == "starrail" ? ["winemetal.dll", "nvngx.dll"] : ["winemetal.dll"]))
    #expect(value.preparation.nvidiaKeys == (game == "starrail"))
    #expect(value.environment["DXMT_ENABLE_NVEXT"] == (game == "starrail" ? "1" : nil))
    #expect(config.contains("dxgi.customVendorId=10de;dxgi.customDeviceId=2684") == (game == "starrail"))
}

@Test(arguments: ["genshin", "starrail", "zzz"], [RuntimeBackend.dxmt, .d3dmetal]) func patchesOffIsDirectLaunch(game: String, backend: RuntimeBackend) throws {
    var settings = LaunchSettings.defaults(for: game); settings.compatibilityPatches = false; settings.backend = backend; settings.frameLimit = 30
    let value = try resolve(game, settings: settings, components: [:])
    let exe = ["genshin": "GenshinImpact.exe", "starrail": "StarRail.exe", "zzz": "ZenlessZoneZero.exe"][game]!
    #expect(value.arguments == [WinePath.windowsPath(for: installRoot.appendingPathComponent(exe))]
        + (game == "zzz" && backend == .d3dmetal ? ["-use-d3d12"] : []))
    #expect(value.hidden.isEmpty && value.copyIfPresent.isEmpty && value.blockedHosts.isEmpty)
    #expect(value.environment["WINE_ENABLE_TIMEOUT_FIX"] == nil)
    #expect(value.requiredComponents.isEmpty && value.preparation.steamShim == nil)
    if backend == .d3dmetal { #expect(value.environment["D3DM_MAX_FPS"] == "30") }
    else { #expect(value.environment["DXMT_CONFIG"]?.contains("d3d11.preferredMaxFrameRate=30") == true) }
}

@Test(arguments: [RuntimeBackend.dxmt, .d3dmetal]) func environmentIsAllowlistedAndBackendExclusive(backend: RuntimeBackend) throws {
    let base = ["HOME": "/Users/x", "USER": "x", "LOGNAME": "x", "TMPDIR": "/tmp/private", "LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_TIME": "ja_JP",
        "PATH": "/untrusted", "HTTP_PROXY": "bad", "HTTPS_PROXY": "bad", "http_proxy": "bad", "https_proxy": "bad",
        "ALL_PROXY": "bad", "all_proxy": "bad", "NO_PROXY": "*", "no_proxy": "*", "D3DM_EVIL": "bad", "D3DM_MAX_FPS": "999",
        "DXMT_EVIL": "bad", "DXMT_CONFIG": "bad", "DXMT_ENABLE_NVEXT": "bad", "WINEPREFIX": "bad", "WINEDEBUG": "bad", "WINEEVIL": "bad",
        "WINEMSYNC": "bad", "WINEESYNC": "bad", "WINEDLLOVERRIDES": "bad", "GST_PLUGIN_FEATURE_RANK": "bad", "SECRET": "bad"]
    var settings = LaunchSettings.defaults(for: "genshin"); settings.backend = backend
    let value = try resolve("genshin", settings: settings, base: base)
    let clean = try resolve("genshin", settings: settings)
    var expected = clean.environment
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_TIME"] { expected[key] = base[key] }
    #expect(value.environment == expected)
    #expect(!value.environment.values.contains("bad"))
    if backend == .d3dmetal { #expect(!value.environment.keys.contains { $0.hasPrefix("DXMT_") }) }
    else { #expect(!value.environment.keys.contains { $0.hasPrefix("D3DM_") }) }
}

@Test(arguments: ["genshin", "starrail", "zzz"]) func missingRequiredComponentThrows(game: String) throws {
    let kind = game == "starrail" ? "jadeite" : "steamShim"
    #expect(throws: LauncherError.io("Missing required component: \(kind)")) { try resolve(game, components: [:]) }
}

@Test(arguments: [0, -1, 59, 144]) func invalidFrameLimitThrows(limit: Int) throws {
    var settings = LaunchSettings.defaults(for: "genshin"); settings.frameLimit = limit
    #expect(throws: LauncherError.io("Frame limit must be Off, 30, 60, 90 or 120")) { try resolve("genshin", settings: settings) }
}

@Test func unknownGameThrows() throws {
    #expect(Recipes.recipe(for: "unknown") == nil)
    let recipe = LaunchRecipe(game: "unknown", recipeVersion: 1, verifiedBuilds: [], executable: try SafeRelativePath("game.exe"),
        wrapper: .none, blockedHosts: [], hidden: [], copyIfPresent: [], timeoutFix: false, supportsDirectX12: false)
    #expect(throws: LauncherError.io("Unknown launch game: unknown")) {
        try LaunchResolver.resolve(recipe: recipe, settings: .defaults(for: "unknown"), installRoot: installRoot,
            prefix: prefix, wineBinary: wine, proxyPort: 1, componentRoots: [:], baseEnvironment: [:])
    }
}

@Test func recipeVersionsAndVerifiedBuildsMatchSpec() throws {
    #expect(try #require(Recipes.recipe(for: "genshin")).verifiedBuilds == ["7.1.0"])
    #expect(try #require(Recipes.recipe(for: "starrail")).verifiedBuilds == ["4.6.0"])
    #expect(try #require(Recipes.recipe(for: "zzz")).verifiedBuilds == ["3.3.0"])
    for game in ["genshin", "starrail", "zzz"] { #expect(try #require(Recipes.recipe(for: game)).recipeVersion == 1) }
}

@Test func d3dmetalFrameLimitOffOmitsVariable() throws {
    var settings = LaunchSettings.defaults(for: "genshin"); settings.frameLimit = nil
    #expect(try resolve("genshin", settings: settings).environment["D3DM_MAX_FPS"] == nil)
}

@Test func gameModeUsesMirroredWrapperLoaderAndServerOnlyWhenEnabled() throws {
    let root = URL(fileURLWithPath: "/Runtimes/GameMode/bundle/MacGacha Game.app/Contents")
    let helper = GameModeRuntime(game: GameDefinition.find("starrail")!, root: root, wineBinary: root.appendingPathComponent("MacOS/wine-wrapper"), wineserver: root.appendingPathComponent("bin/wineserver"))
    let recipe = try #require(Recipes.recipe(for: "starrail"))
    for enabled in [true, false] {
        let result = try LaunchResolver.resolve(recipe: recipe, settings: .defaults(for: "starrail"), installRoot: installRoot,
            prefix: prefix, wineBinary: wine, proxyPort: 1, componentRoots: roots, baseEnvironment: ["WINELOADER": "/inherited/bad"],
            gameModeRuntime: helper, gameModeEnabled: enabled)
        #expect(result.executable == (enabled ? helper.wineBinary : wine))
        #expect(result.environment["WINELOADER"] == (enabled ? helper.loader.path : nil))
        #expect(result.environment["WINESERVER"] == (enabled ? helper.wineserver.path : nil))
        #expect(result.arguments == [WinePath.windowsPath(for: roots[.jadeite]!.appendingPathComponent("jadeite.exe")),
            WinePath.windowsPath(for: installRoot.appendingPathComponent("StarRail.exe"))])
    }
    #expect(try resolve("starrail").environment["WINELOADER"] == nil)
}

@Test(arguments: [false, true])
func starRailUnlockRequestsOneTwenty(patches: Bool) throws {
    let game = "starrail"
    var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = true; settings.compatibilityPatches = patches
    let value = try resolve(game, settings: settings)
    #expect(value.preparation.starRailFrameRate == .unlock120)
    #expect(value.preparation.starRailRegion == GameDefinition.find(game)?.region)
}
@Test func starRailOffRequestsRestore() throws {
    let game = "starrail"
    #expect(try resolve(game).preparation.starRailFrameRate == .restore)
    var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = true; settings.unlockTarget = 90
    #expect(throws: LauncherError.self) { try resolve(game, settings: settings) }
}
@Test(arguments: [false, true], [RuntimeBackend.d3dmetal, .dxmt])
func unverifiedChinaStarRailNeverPreparesFrameRate(unlock: Bool, backend: RuntimeBackend) throws {
    var settings = LaunchSettings.defaults(for: "starrail-cn"); settings.unlockFPS = unlock; settings.backend = backend
    #expect(try resolve("starrail-cn", settings: settings).preparation.starRailFrameRate == nil)
}
@Test(arguments: [("starrail", true), ("starrail-cn", false), ("genshin", false), ("genshin-cn", false),
    ("zzz", false), ("zzz-cn", false), ("unknown", false)])
func starRailUnlockEligibilityIsGlobalOnly(game: String, offered: Bool) {
    #expect(LaunchResolver.offersStarRailUnlock(game) == offered)
}
@Test(arguments: ["genshin", "genshin-cn", "zzz", "zzz-cn"], [false, true])
func genshinAndZZZNeverTouchStarRailValue(game: String, unlock: Bool) throws {
    var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = unlock
    #expect(try resolve(game, settings: settings).preparation.starRailFrameRate == nil)
}
@Test(arguments: [RuntimeBackend.d3dmetal, .dxmt]) func ninetyFrameLimitReachesBackend(backend: RuntimeBackend) throws {
    var settings = LaunchSettings.defaults(for: "starrail"); settings.backend = backend; settings.frameLimit = 90
    let value = try resolve("starrail", settings: settings)
    if backend == .d3dmetal { #expect(value.environment["D3DM_MAX_FPS"] == "90") }
    else { #expect(value.environment["DXMT_CONFIG"]?.contains("d3d11.preferredMaxFrameRate=90") == true) }
}
