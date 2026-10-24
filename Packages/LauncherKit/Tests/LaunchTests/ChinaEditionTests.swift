// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

@Suite struct ChinaEditionTests {
    @Test func mainlandSessionsAndRecoveryNoticesPersistIndependently() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url.appendingPathComponent("app"))
            let journal = LaunchJournal(paths: paths)
            let notices = RecoveryNoticeStore(paths: paths)
            var ids: Set<UUID> = []
            for game in GameDefinition.inRegion(.mainlandChina) {
                let root = temp.url.appendingPathComponent(game.defaultInstallDirectoryName)
                let fs = try ContainedFileSystem(root: root); try fs.createRootDurably()
                let session = LaunchSession(sessionID: UUID(), game: game.id, installRoot: root, installIdentity: try fs.rootIdentity(),
                    prefix: paths.prefixes.appendingPathComponent(game.id + "-bundle"), bundleID: "bundle",
                    runtimeDigest: testDigest(Data()), wineBinary: paths.runtimes.appendingPathComponent("bin/wine"),
                    wineserver: paths.runtimes.appendingPathComponent("bin/wineserver"), componentIDs: ["wine-1"],
                    recipeVersion: 1, settings: .defaults(for: game.id), state: .done)
                try journal.write(session)
                #expect(try journal.read(game: game.id) == session)
                let location = paths.games.appendingPathComponent("\(game.id)/recovery/\(session.sessionID)/copy")
                try notices.record(RecoveryNotice(id: session.sessionID, game: game.id, movedTo: [location]))
                try journal.delete(game: game.id)
                ids.insert(session.sessionID)
            }
            #expect(Set(try notices.load().map(\.id)) == ids)
            for id in ids { try notices.acknowledge(id: id) }
            #expect(try notices.load().isEmpty)
        }
    }
    @Test func definitionsAndRecipesCoverExactlyTheSameEditions() {
        #expect(Set(Recipes.games) == Set(GameDefinition.all.map(\.id)))
        #expect(Set(LaunchLogFiles.games) == Set(GameDefinition.all.map(\.id)))
        #expect(GameDefinition.all.count == 6)
        #expect(Set(GameDefinition.all.map(\.biz)).count == 6)
        #expect(Set(GameDefinition.all.map(\.gameID)).count == 6)
    }

    @Test(arguments: ["genshin-cn", "starrail-cn", "zzz-cn"])
    func mainlandDefinitionsAndResolution(id: String) throws {
        let game = try #require(GameDefinition.find(id))
        let recipe = try #require(Recipes.recipe(for: id))
        #expect(game.region == .mainlandChina)
        #expect(game.voices.map(\.code) == ["zh-cn", "en-us", "ja-jp", "ko-kr"])
        #expect(recipe.verifiedBuilds.isEmpty)
        let global = try #require(GameDefinition.all.first { $0.family == game.family && $0.region == .global })
        #expect(global.defaultInstallDirectoryName != game.defaultInstallDirectoryName)
        #expect(LaunchSettings.defaults(for: id) == LaunchSettings.defaults(for: global.id))
        let roots: [ComponentKind: URL] = [.steamShim: URL(fileURLWithPath: "/shim"), .jadeite: URL(fileURLWithPath: "/jadeite")]
        var settings = LaunchSettings.defaults(for: id); settings.backend = .dxmt
        let value = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: URL(fileURLWithPath: "/game"),
            prefix: URL(fileURLWithPath: "/prefix"), wineBinary: URL(fileURLWithPath: "/runtime/bin/wine"), proxyPort: 1234,
            componentRoots: roots, baseEnvironment: [:])
        #expect(value.arguments.contains { $0.hasSuffix(game.executableName) })
        switch game.family {
        case .genshin:
            #expect(game.biz == "hk4e_cn" && game.gameID == "1Z8W5NHUQb")
            #expect(game.defaultInstallDirectoryName == "原神")
            #expect(recipe.executable.description == "YuanShen.exe")
            #expect(recipe.hidden.map(\.description) == ["YuanShen_Data/upload_crash.exe", "YuanShen_Data/Plugins/crashreport.exe", "YuanShen_Data/Plugins/vulkan-1.dll"])
            #expect(recipe.wrapper == .steamShim && recipe.timeoutFix && value.blockedHosts.isEmpty)
        case .starrail:
            #expect(game.biz == "hkrpg_cn" && game.gameID == "64kMb5iAWu")
            #expect(game.defaultInstallDirectoryName == "崩坏星穹铁道")
            #expect(recipe.executable.description == "StarRail.exe" && recipe.wrapper == .jadeite)
            #expect(value.hidden == Recipes.recipe(for: global.id)?.hidden)
            #expect(value.blockedHosts == ["globaldp-prod-cn01.bhsr.com"])
            #expect(value.environment["DXMT_ENABLE_NVEXT"] == "1" && value.preparation.nvidiaKeys)
        case .zzz:
            #expect(game.biz == "nap_cn" && game.gameID == "x6znKlJ0xK")
            #expect(game.defaultInstallDirectoryName == "绝区零")
            #expect(recipe.executable.description == "ZenlessZoneZero.exe")
            #expect(recipe.wrapper == .steamShim && recipe.supportsDirectX12 && recipe.timeoutFix)
            #expect(value.blockedHosts.isEmpty)
            var metal = settings; metal.backend = .d3dmetal
            let dx12 = try LaunchResolver.resolve(recipe: recipe, settings: metal, installRoot: URL(fileURLWithPath: "/game"),
                prefix: URL(fileURLWithPath: "/prefix"), wineBinary: URL(fileURLWithPath: "/runtime/bin/wine"), proxyPort: 1234,
                componentRoots: roots, baseEnvironment: [:])
            #expect(dx12.arguments.contains("-use-d3d12"))
        }
        if game.family != .starrail { #expect(value.copyIfPresent.first?.source.description == "HoYoKProtect.sys") }
        let product: String = switch game.family {
        case .genshin: "原神"
        case .starrail: "崩坏：星穹铁道"
        case .zzz: "绝区零"
        }
        #expect(recipe.gameLogPaths.map(\.description) == ["AppData/LocalLow/miHoYo/\(product)/Player.log", "AppData/LocalLow/miHoYo/\(product)/output_log.txt"])
        var off = settings; off.compatibilityPatches = false
        let bare = try LaunchResolver.resolve(recipe: recipe, settings: off, installRoot: URL(fileURLWithPath: "/game"),
            prefix: URL(fileURLWithPath: "/prefix"), wineBinary: URL(fileURLWithPath: "/runtime/bin/wine"), proxyPort: 1234,
            componentRoots: [:], baseEnvironment: [:])
        #expect(bare.hidden.isEmpty && bare.copyIfPresent.isEmpty && bare.blockedHosts.isEmpty)
    }
}
