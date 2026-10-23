// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

public enum Recipes {
    public static func recipe(for game: String) -> LaunchRecipe? { all[game] }

    // All paths are fixed recipe literals, not manifest or user input.
    private static let all: [String: LaunchRecipe] = [
        "genshin": LaunchRecipe(game: "genshin", recipeVersion: 1, verifiedBuilds: ["7.1"],
            executable: try! SafeRelativePath("GenshinImpact.exe"), wrapper: .steamShim, blockedHosts: [],
            hidden: ["GenshinImpact_Data/upload_crash.exe", "GenshinImpact_Data/Plugins/crashreport.exe",
                "GenshinImpact_Data/Plugins/vulkan-1.dll"].map { try! SafeRelativePath($0) },
            copyIfPresent: [(try! SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")],
            timeoutFix: true, supportsDirectX12: false),
        "starrail": LaunchRecipe(game: "starrail", recipeVersion: 1, verifiedBuilds: ["4.6.0"],
            executable: try! SafeRelativePath("StarRail.exe"), wrapper: .jadeite,
            blockedHosts: ["globaldp-prod-os01.starrails.com"],
            hidden: ["StarRail_Data/Plugins/x86_64/crashreport.exe", "StarRail_Data/Plugins/x86_64/vulkan-1.dll"].map { try! SafeRelativePath($0) },
            copyIfPresent: [], timeoutFix: false, supportsDirectX12: false),
        "zzz": LaunchRecipe(game: "zzz", recipeVersion: 1, verifiedBuilds: ["Phase 0 install of 2026-10-23"],
            executable: try! SafeRelativePath("ZenlessZoneZero.exe"), wrapper: .steamShim, blockedHosts: [],
            hidden: [try! SafeRelativePath("ZenlessZoneZero_Data/Plugins/x86_64/vulkan-1.dll")],
            copyIfPresent: [(try! SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")],
            timeoutFix: true, supportsDirectX12: true),
    ]
}
