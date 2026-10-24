// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
@testable import GameLibrary

@Suite struct AdoptEditionTests {
    @Test(arguments: GameDefinition.all.map(\.id))
    func matchingEditionIsAccepted(id: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find(id))
            let fs = try ContainedFileSystem(root: temp.url)
            try seed(game, fs: fs)
            try AdoptEditionValidator.validate(game, in: fs)
        }
    }
    @Test(arguments: GameDefinition.all.map(\.id))
    func oppositeEditionIsRefused(id: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find(id))
            let other = try #require(GameDefinition.all.first { $0.family == game.family && $0.region != game.region })
            let fs = try ContainedFileSystem(root: temp.url)
            try seed(other, fs: fs)
            #expect(throws: LauncherError.gameEditionMismatch) { try AdoptEditionValidator.validate(game, in: fs) }
        }
    }
    @Test(arguments: ["channel=14", "cps=bilibili", "cps=BILIBILI", "cps=bilibili_PC", "game_biz=hkrpg_bilibili",
        "uapc={\"hkrpg_bilibili\":{\"uapc\":\"\"}}"])
    func bilibiliIsNotSupported(marker: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find("starrail-cn"))
            let fs = try ContainedFileSystem(root: temp.url)
            try seed(game, fs: fs, additional: marker)
            #expect(throws: LauncherError.gameDistributionUnsupported) { try AdoptEditionValidator.validate(game, in: fs) }
        }
    }
    @Test(arguments: [
        "launcher_id=11\ngame_id=8\nsub_channel=0",
        "uapc={\"hyp\":{\"uapc\":\"hkrpg_cn\"}}",
        "uapc={\"not_hkrpg_cn\":{\"uapc\":\"\"}}"
    ])
    func unrecognizedMetadataDoesNotClaimAnotherEdition(metadata: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            let game = try #require(GameDefinition.find("starrail"))
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try fs.writeAtomically(Data(metadata.utf8), to: SafeRelativePath("config.ini"))
            try AdoptEditionValidator.validate(game, in: fs)
        }
    }
    @Test(arguments: ["genshin", "genshin-cn"])
    func distinctExecutableCanIdentifyEditionWithoutConfig(id: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find(id))
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try AdoptEditionValidator.validate(game, in: fs)
        }
    }
    @Test(arguments: ["starrail", "starrail-cn", "zzz", "zzz-cn"],
        ["", "[General]\ngame_version=4.6.0\nchannel=1\nsub_channel=0", "[General]\nsub_channel=14"])
    func sharedExecutableWithoutEditionEvidenceAcceptsSelectedEdition(id: String, config: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find(id))
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try fs.writeAtomically(Data("Sophon file inventory".utf8), to: SafeRelativePath("pkg_version"))
            if !config.isEmpty { try fs.writeAtomically(Data(config.utf8), to: SafeRelativePath("config.ini")) }
            try AdoptEditionValidator.validate(game, in: fs)
        }
    }
    @Test(arguments: ["global-starrail", "global-zzz", "cn-starrail", "bilibili-starrail"])
    func realisticLauncherConfigurations(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ini", subdirectory: "Adopt"))
        try await BlockingIO.run {
            let fixture = try ContainedFileSystem(root: url.deletingLastPathComponent())
            let data = try fixture.readFile(at: SafeRelativePath(url.lastPathComponent), maxBytes: 4096)
            let selected = name == "global-zzz" ? "zzz" : name == "global-starrail" ? "starrail" : "starrail-cn"
            let game = try #require(GameDefinition.find(selected))
            let other = try #require(GameDefinition.all.first { $0.family == game.family && $0.region != game.region })
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try fs.writeAtomically(data, to: SafeRelativePath("config.ini"))
            if name == "bilibili-starrail" {
                #expect(throws: LauncherError.gameDistributionUnsupported) { try AdoptEditionValidator.validate(game, in: fs) }
            } else {
                try AdoptEditionValidator.validate(game, in: fs)
                #expect(throws: LauncherError.gameEditionMismatch) { try AdoptEditionValidator.validate(other, in: fs) }
            }
        }
    }
    @Test(arguments: [
        "uapc={\"hkrpg_cn\":{\"uapc\":\"\"},\"hkrpg_global\":{\"uapc\":\"\"}}",
        "game_biz=hkrpg_cn\nuapc={\"hkrpg_global\":{\"uapc\":\"\"}}",
        "uapc={\"hkrpg_cn\":{\"uapc\":\"\"}}\nlauncher_id=VYTpXlbWo8",
        "game_id=4ziysqXOQ8"
    ])
    func conflictingRecognizedEvidenceIsRefused(metadata: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            let game = try #require(GameDefinition.find("starrail-cn"))
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try fs.writeAtomically(Data(metadata.utf8), to: SafeRelativePath("config.ini"))
            #expect(throws: LauncherError.gameEditionMismatch) { try AdoptEditionValidator.validate(game, in: fs) }
        }
    }
    @Test func conflictingMetadataCannotOverrideTheWrongEdition() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find("starrail-cn"))
            let fs = try ContainedFileSystem(root: temp.url)
            try seed(game, fs: fs, additional: "game_biz=hkrpg_global\ngame_biz=hkrpg_cn")
            #expect(throws: LauncherError.gameEditionMismatch) { try AdoptEditionValidator.validate(game, in: fs) }
        }
    }
    @Test(arguments: ["starrail-cn", "starrail"])
    func gameVersionMetadataProvidesEditionEvidence(id: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), game = try #require(GameDefinition.find(id))
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            let data = try JSONSerialization.data(withJSONObject: ["game_version": ["game_biz": "hkrpg_cn", "version": "4.6.0"]])
            try fs.writeAtomically(data, to: SafeRelativePath("game_version"))
            if game.region == .mainlandChina { try AdoptEditionValidator.validate(game, in: fs) }
            else { #expect(throws: LauncherError.gameEditionMismatch) { try AdoptEditionValidator.validate(game, in: fs) } }
        }
    }
    @Test func symlinkedConfigIsNeverRead() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), outside = try TempDir(), game = try #require(GameDefinition.find("starrail-cn"))
            let fs = try ContainedFileSystem(root: temp.url), other = try ContainedFileSystem(root: outside.url)
            let bytes = Data("[General]\ngame_biz=hkrpg_cn\n".utf8)
            try other.writeAtomically(bytes, to: SafeRelativePath("private.ini"))
            try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
            try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("config.ini"),
                withDestinationURL: outside.url.appendingPathComponent("private.ini"))
            #expect(throws: LauncherError.self) { try AdoptEditionValidator.validate(game, in: fs) }
            #expect(try other.readFile(at: SafeRelativePath("private.ini"), maxBytes: 100) == bytes)
        }
    }
    private func seed(_ game: GameDefinition, fs: ContainedFileSystem, additional: String = "") throws {
        try fs.writeAtomically(Data("exe".utf8), to: SafeRelativePath(game.executableName))
        let config = "[General]\ngame_biz=\(game.biz)\ngame_id=\(game.gameID)\nlauncher_id=\(game.region.launcherID)\nchannel=1\ngame_version=7.1.0\n\(additional)"
        try fs.writeAtomically(Data(config.utf8), to: SafeRelativePath("config.ini"))
    }
}
