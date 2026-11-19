// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite struct SandboxPublicationTests {
    @Test(arguments: SandboxPublishPoint.allCases)
    func interruptedPublicationRollsBackBeforeSwapAndFinishesAfter(point: SandboxPublishPoint) async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url.appendingPathComponent("app"))
        let root = temp.url.appendingPathComponent("game"), fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("BeyondAssets"))
        let file = try SafeRelativePath("BeyondAssets/a"), list = try SafeRelativePath("beyond_pkg_version")
        try fs.writeAtomically(Data("old".utf8), to: file)
        try fs.writeAtomically(Data("old-list".utf8), to: list)
        try fs.writeAtomically(Data("other=x\nwpf_version=1\n".utf8), to: SafeRelativePath("config.ini"))
        let old = try SandboxInstallation(version: "1", listPath: list)
        let record = GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("Game.exe"),
            installed: InstalledBuild(tag: "7.2", buildID: "test", categories: [], voices: []), installIdentity: try fs.rootIdentity(), sandbox: old)
        let store = GameRecordStore(directory: paths.games)
        try await store.save(record, for: "hk4e_global")
        let stage = try SafeRelativePath(".macgacha-staging/sandbox-test")
        try fs.createDirectory(at: stage)
        try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath(stage.description + "/new/BeyondAssets/a"))
        try fs.writeAtomically(Data("new-list".utf8), to: SafeRelativePath(stage.description + "/new/beyond_pkg_version"))
        let publisher = SandboxPublisher(store: store, hooks: SandboxPublishHooks { reached in
            if reached == point { throw LauncherError.io("simulated process death") }
        })
        await #expect(throws: LauncherError.self) {
            try await publisher.publish(game: "hk4e_global", record: record, stage: stage,
                installation: SandboxInstallation(version: "2", listPath: list))
        }
        try await SandboxPublisher(store: store).recover(game: "hk4e_global")
        try await SandboxPublisher(store: store).recover(game: "hk4e_global")
        let forward = point == .swapped || point == .recordSaved || point == .cleaned || point == .beforeCleanupRemoval
        #expect(try fs.readFile(at: file, maxBytes: 100) == Data((forward ? "new" : "old").utf8))
        #expect(try fs.readFile(at: list, maxBytes: 100) == Data((forward ? "new-list" : "old-list").utf8))
        #expect(try await store.load("hk4e_global")?.sandbox?.version == (forward ? "2" : "1"))
        #expect(try await store.readState("sandbox-journal.json", for: "hk4e_global", maxBytes: 65536) == nil)
        #expect(try fs.itemType(at: stage) == nil)
    }
    @Test(arguments: ["tree", "list", "both"])
    func rollbackPreservesDamagedRecordedInstallation(missing: String) async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("game")
        let fs = try ContainedFileSystem(root: root), store = GameRecordStore(directory: temp.url.appendingPathComponent("records"))
        let list = try SafeRelativePath("beyond_pkg_version"), stage = try SafeRelativePath(".macgacha-staging/sandbox-damaged")
        try fs.createDirectory(at: stage)
        if missing == "list" { try fs.writeAtomically(Data("old".utf8), to: SafeRelativePath("BeyondAssets/a")) }
        if missing == "tree" { try fs.writeAtomically(Data("old-list".utf8), to: list) }
        try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath(stage.description + "/new/BeyondAssets/a"))
        try fs.writeAtomically(Data("new-list".utf8), to: SafeRelativePath(stage.description + "/new/beyond_pkg_version"))
        let record = GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("Game.exe"),
            installIdentity: try fs.rootIdentity(), sandbox: try SandboxInstallation(version: "1", listPath: list))
        try await store.save(record, for: "hk4e_global")
        let publisher = SandboxPublisher(store: store, hooks: SandboxPublishHooks { point in
            if point == .treePublished { throw LauncherError.io("simulated crash") }
        })
        await #expect(throws: LauncherError.self) {
            try await publisher.publish(game: "hk4e_global", record: record, stage: stage,
                installation: SandboxInstallation(version: "2", listPath: list))
        }
        try await SandboxPublisher(store: store).recover(game: "hk4e_global")
        #expect(try await store.load("hk4e_global")?.sandbox?.version == "1")
        #expect(try fs.itemType(at: SandboxFiles.assets) == (missing == "list" ? .directory : nil))
        #expect(try fs.itemType(at: list) == (missing == "tree" ? .regularFile : nil))
        #expect(try await store.readState("sandbox-journal.json", for: "hk4e_global", maxBytes: 65536) == nil)
    }

    @Test(arguments: [false, true])
    func invalidConfigRefusesPublicationAndRemovalBeforePlanning(remove: Bool) async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("game")
        let fs = try ContainedFileSystem(root: root), store = GameRecordStore(directory: temp.url.appendingPathComponent("records"))
        let list = SandboxFiles.defaultList, editor = try SafeRelativePath("BeyondAssets/a")
        let config = try SafeRelativePath("config.ini"), stage = try SafeRelativePath(".macgacha-staging/sandbox-invalid-config")
        try fs.writeAtomically(Data("old".utf8), to: editor)
        try fs.writeAtomically(Data("old-list".utf8), to: list)
        try fs.writeAtomically(Data([0xff]), to: config)
        try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath(stage.description + "/new/BeyondAssets/a"))
        try fs.writeAtomically(Data("new-list".utf8), to: SafeRelativePath(stage.description + "/new/beyond_pkg_version"))
        let record = GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("Game.exe"),
            installIdentity: try fs.rootIdentity(), sandbox: try SandboxInstallation(version: "1", listPath: list))
        try await store.save(record, for: "hk4e_global")
        let desired = remove ? nil : try SandboxInstallation(version: "2", listPath: list)
        await #expect(throws: LauncherError.self) {
            try await SandboxPublisher(store: store).publish(game: "hk4e_global", record: record, stage: stage, installation: desired)
        }
        #expect(try await store.readState(SandboxPublisher.journalName, for: "hk4e_global", maxBytes: 65536) == nil)
        #expect(try fs.readFile(at: editor, maxBytes: 32) == Data("old".utf8))
        #expect(try fs.readFile(at: list, maxBytes: 32) == Data("old-list".utf8))
        #expect(try await store.load("hk4e_global") == record)
    }

    @Test func swappedJournalFinishesWhenConfigBecameUnwritable() async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("game")
        let fs = try ContainedFileSystem(root: root), store = GameRecordStore(directory: temp.url.appendingPathComponent("records"))
        let list = SandboxFiles.defaultList, config = try SafeRelativePath("config.ini")
        let stage = try SafeRelativePath(".macgacha-staging/sandbox-config-after-swap")
        try fs.writeAtomically(Data("user=value\n".utf8), to: config)
        try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath(stage.description + "/new/BeyondAssets/a"))
        try fs.writeAtomically(Data("new-list".utf8), to: SafeRelativePath(stage.description + "/new/beyond_pkg_version"))
        let record = GameRecord(installPath: root, ownership: .created,
            executable: try SafeRelativePath("Game.exe"), installIdentity: try fs.rootIdentity())
        try await store.save(record, for: "hk4e_global")
        let publisher = SandboxPublisher(store: store, hooks: SandboxPublishHooks { point in
            if point == .swapped {
                try fs.writeAtomically(Data([0xff]), to: config)
                throw LauncherError.io("simulated process death")
            }
        })
        await #expect(throws: LauncherError.self) {
            try await publisher.publish(game: "hk4e_global", record: record, stage: stage,
                installation: SandboxInstallation(version: "2", listPath: list))
        }
        #expect(try await SandboxPublisher(store: store).recover(game: "hk4e_global"))
        #expect(try await store.load("hk4e_global")?.sandbox?.version == "2")
        #expect(try await store.readState(SandboxPublisher.journalName, for: "hk4e_global", maxBytes: 65536) == nil)
        #expect(try fs.readFile(at: config, maxBytes: 32) == Data([0xff]))
    }

    @Test func exchangedCleanupStageIsPreserved() async throws {
        let temp = try TempDir(), root = temp.url.appendingPathComponent("game")
        let fs = try ContainedFileSystem(root: root), store = GameRecordStore(directory: temp.url.appendingPathComponent("records"))
        let list = try SafeRelativePath("beyond_pkg_version"), stage = try SafeRelativePath(".macgacha-staging/sandbox-exchange")
        try fs.createDirectory(at: stage)
        try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath(stage.description + "/new/BeyondAssets/a"))
        try fs.writeAtomically(Data("new-list".utf8), to: SafeRelativePath(stage.description + "/new/beyond_pkg_version"))
        let record = GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("Game.exe"), installIdentity: try fs.rootIdentity())
        try await store.save(record, for: "hk4e_global")
        let publisher = SandboxPublisher(store: store, hooks: SandboxPublishHooks { point in
            if point == .beforeCleanupRemoval {
                let original = try #require(try fs.pinDirectoryIfPresent(at: stage))
                try fs.moveDirectory(at: stage, to: SafeRelativePath(".macgacha-staging/preserved"), in: fs, matching: original.rootIdentity())
                try fs.writeAtomically(Data("keep".utf8), to: SafeRelativePath(stage.description + "/foreign"))
            }
        })
        await #expect(throws: LauncherError.self) {
            try await publisher.publish(game: "hk4e_global", record: record, stage: stage,
                installation: SandboxInstallation(version: "2", listPath: list))
        }
        #expect(try fs.readFile(at: SafeRelativePath(stage.description + "/foreign"), maxBytes: 10) == Data("keep".utf8))
        #expect(try await store.readState("sandbox-journal.json", for: "hk4e_global", maxBytes: 65536) != nil)
    }

}
