// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

public enum Recipes {
    public static func recipe(for game: String) -> LaunchRecipe? { all[game] }
    package static var games: [String] { all.keys.sorted() }

    // Edition identities and paths come from the shared, fixed registry.
    private static let all = Dictionary(uniqueKeysWithValues: GameDefinition.all.map { game in
        let data = game.dataDirectoryName
        let hidden: [String]
        let wrapper: LaunchRecipe.Wrapper
        let hosts: [String]
        let verified: Set<String>
        switch game.family {
        case .genshin:
            hidden = ["\(data)/upload_crash.exe", "\(data)/Plugins/crashreport.exe", "\(data)/Plugins/vulkan-1.dll"]
            wrapper = .steamShim; hosts = []; verified = ["7.1.0"]
        case .starrail:
            hidden = ["\(data)/Plugins/x86_64/crashreport.exe", "\(data)/Plugins/x86_64/vulkan-1.dll"]
            wrapper = .jadeite
            hosts = [game.region == .global ? "globaldp-prod-os01.starrails.com" : "globaldp-prod-cn01.bhsr.com"]
            verified = ["4.6.0"]
        case .zzz:
            hidden = ["\(data)/Plugins/x86_64/vulkan-1.dll"]
            wrapper = .steamShim; hosts = []; verified = ["3.3.0"]
        }
        return (game.id, LaunchRecipe(game: game.id, recipeVersion: 1,
            verifiedBuilds: game.region == .global ? verified : [], executable: try! SafeRelativePath(game.executableName),
            wrapper: wrapper, blockedHosts: hosts, hidden: hidden.map { try! SafeRelativePath($0) },
            copyIfPresent: game.family == .starrail ? [] : [(try! SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")],
            timeoutFix: game.family != .starrail, supportsDirectX12: game.family == .zzz,
            gameLogPaths: LaunchLogFiles.gameLogPaths(for: game.id)))
    })
}
