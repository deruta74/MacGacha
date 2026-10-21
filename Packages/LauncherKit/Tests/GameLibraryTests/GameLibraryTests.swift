// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite(.serialized) struct GameLibraryTests {
    @Test func freshInstallThenInstalledStatus() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        #expect(await f.library.status(game) == .notInstalled)
        let events = try await libraryCollect(await f.library.install(game, voices: ["en-us"], at: f.install, approved: true))
        #expect(events.last == .phase(.completed))
        #expect(await f.library.status(game) == .installed(tag: "1.0"))
        try f.assertFiles(1)
        let pending = try await f.store.loadPlan(for: game.id)
        #expect(pending == nil)
    }

    @Test func updateReusesLocalChunks() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        try f.advertise(2); let before = f.cdn.requestLog.count
        #expect(await f.library.status(game) == .updateAvailable(from: "1.0", to: "2.0"))
        _ = try await libraryCollect(await f.library.update(game, approved: true))
        let downloads = f.cdn.requestLog.dropFirst(before).filter { $0.path.hasPrefix("chunks/") }
        #expect(downloads.count == 2)
        #expect(await f.library.status(game) == .installed(tag: "2.0"))
        try f.assertFiles(2)
    }

    @Test func verifyRepairsCorruptedFile() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        try f.fs.writeAtomically(Data("bad".utf8), to: SafeRelativePath("Game.exe"))
        _ = try await libraryCollect(await f.library.verify(game, mode: .full))
        try f.assertFiles(1)
    }

    @Test func adoptExistingFolderRepairsDifferences() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        let events = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        #expect(events.last == .phase(.completed)); try f.assertFiles(1)
        #expect(try await f.store.load(game.id)?.ownership == .adopted)
    }

    @Test func adoptKeepsForeignFiles() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        try f.fs.writeAtomically(Data("mine".utf8), to: SafeRelativePath("foreign.txt"))
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign.txt"), maxBytes: 100) == Data("mine".utf8))
    }

    @Test func addAndRemoveVoice() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        _ = try await libraryCollect(await f.library.install(game, voices: [], at: f.install, approved: true))
        #expect(try f.fs.itemType(at: SafeRelativePath("audio/en1")) == nil)
        _ = try await libraryCollect(await f.library.setVoices(game, ["en-us"]))
        #expect(try f.fs.itemType(at: SafeRelativePath("audio/en1")) == .regularFile)
        _ = try await libraryCollect(await f.library.setVoices(game, []))
        #expect(try f.fs.itemType(at: SafeRelativePath("audio/en1")) == nil)
        #expect(try f.fs.readFile(at: SafeRelativePath("shared.bin"), maxBytes: 100) == Data("shared-resource".utf8))
        #expect(try await f.store.load(game.id)?.installed?.voices == [])
    }

    @Test func pausedUpdateBlocksOtherOperations() async throws {
        let disk = LibraryDisk(); let f = try LibraryFixture(disk: disk)
        try f.advertise(1); try await f.installGame(); try f.advertise(2)
        disk.bytes.withLock { $0 = SpaceBudget.margin + 48 }
        try await pauseAfterBatch(await f.library.update(game, approved: true), fs: f.fs, store: f.store)
        let record = try #require(try await f.store.load(game.id)); let digest = try #require(record.pending?.planDigest)
        let before = f.cdn.requestLog.count
        for stream in [await f.library.verify(game, mode: .full), await f.library.setVoices(game, []), await f.library.update(game, approved: true)] {
            await #expect(throws: LauncherError.busy("finish or uninstall the paused operation first")) { _ = try await libraryCollect(stream) }
        }
        #expect(try await f.store.load(game.id) == record)
        #expect(try await f.store.loadPlan(for: game.id)?.planDigest == digest)
        #expect(f.cdn.requestLog.count == before)
        disk.bytes.withLock { $0 = Int64.max }
        _ = try await libraryCollect(await f.library.resume(game, approved: true)); try f.assertFiles(2)
    }

    @Test func uninstallPausedFreshInstallBeforeFirstCommit() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        for try await event in await f.library.install(game, voices: ["en-us"], at: f.install, approved: true) {
            if case .fileVerified = event { break }
        }
        #expect(try await f.store.load(game.id)?.pending != nil)
        #expect(try f.fs.itemType(at: SafeRelativePath("Game.exe")) == nil)
        try await f.library.uninstall(game)
        #expect(!FileManager.default.fileExists(atPath: f.install.path))
        #expect(try await f.store.load(game.id) == nil)
    }

    @Test func uninstallAdoptedKeepsForeignFiles() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        try f.fs.writeAtomically(Data("mine".utf8), to: SafeRelativePath("foreign/note"))
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        try await f.library.uninstall(game)
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign/note"), maxBytes: 100) == Data("mine".utf8))
        #expect(try f.fs.itemType(at: SafeRelativePath("Game.exe")) == nil)
        #expect(try f.fs.itemType(at: SafeRelativePath("data")) == nil)
        #expect(try await f.store.load(game.id) == nil)
    }

    @Test func uninstallRefusesForeignFolder() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        try FileManager.default.removeItem(at: f.install)
        try f.fs.writeAtomically(Data("foreign".utf8), to: SafeRelativePath("foreign"))
        await #expect(throws: LauncherError.io("install folder was replaced")) { try await f.library.uninstall(game) }
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("foreign".utf8))
    }

    @Test(arguments: [CrashPoint.afterGameFolderRemoved, .afterUninstallPlanDeleted, .afterUninstallManifestCacheDeleted, .afterUninstallBranchDeleted, .afterUninstallManagedPathsDeleted, .afterUninstallCleanupDeleted, .beforeGameRecordDeleted, .afterUninstallRecordDeleted], [false, true])
    func uninstallResumesAfterCrash(point: CrashPoint, adopted: Bool) async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        if adopted {
            try f.seedExisting()
            try f.fs.writeAtomically(Data("mine".utf8), to: SafeRelativePath("foreign"))
            _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        } else { try await f.installGame() }
        try await f.store.writeState(Data("{}".utf8), named: "uninstall-cleaned.json", for: game.id)
        try await f.store.savePlan(InstallPlan(id: SafeIdentifier("retired"), objects: [:], files: []), for: game.id)
        let bundle = Bundle(for: LibraryBundleToken.self).bundleURL
        let harness = bundle.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        #expect(FileManager.default.isExecutableFile(atPath: harness.path))
        let result = try await SystemProcessRunner().run(harness, arguments: [f.base.path, f.install.path, point.rawValue, f.paths.games.path, "uninstall"], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
        let remaining = try await f.store.load(game.id)
        if point == .afterUninstallRecordDeleted { #expect(remaining == nil) }
        else { #expect(remaining?.uninstalling == true); #expect(remaining?.uninstallFilesRemoved == true) }
        #expect(FileManager.default.fileExists(atPath: f.install.path) == adopted)
        let before = f.cdn.requestLog.count
        if remaining == nil { await f.restarted().start() } else { try await f.restarted().uninstall(game) }
        #expect(try await f.store.load(game.id) == nil)
        #expect(try await f.store.gameDirectories().isEmpty)
        #expect(f.cdn.requestLog.count == before)
        if adopted { #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("mine".utf8)) }
    }

    @Test func installIntoAnotherGamesFolderRefused() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        let record = GameRecord(installPath: f.install, ownership: .created, executable: try SafeRelativePath("Other.exe"), installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
        try await f.store.save(record, for: "starrail")
        await #expect(throws: LauncherError.unsafePath("install location")) {
            _ = try await libraryCollect(await f.library.install(game, voices: [], at: f.install.appendingPathComponent("nested"), approved: true))
        }
        #expect(f.cdn.requestLog.isEmpty)
    }

    @Test func badManifestCacheIsRefetched() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let cache = try await f.store.manifestCache(for: game.id)
        let cacheFS = try ContainedFileSystem(root: cache)
        try cacheFS.writeAtomically(Data("bad".utf8), to: SafeRelativePath("v1-base.zst"))
        let before = f.cdn.requestLog.count
        _ = try await libraryCollect(await f.library.verify(game, mode: .full))
        let requests = f.cdn.requestLog.dropFirst(before)
        #expect(requests.filter { $0.path == "manifests/v1-base" }.count == 1)
        #expect(!requests.contains { $0.path.hasPrefix("chunks/") })
    }

    @Test func offlineStatusUsesCachedBranch() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame(); try f.advertise(2)
        #expect(await f.library.status(game) == .updateAvailable(from: "1.0", to: "2.0"))
        f.cdn.enqueueFault("hyp/hyp-connect/api/getGameBranches", .transportError)
        #expect(await f.restarted().status(game) == .updateAvailable(from: "1.0", to: "2.0"))
    }

    @Test func estimateSeparatesWholeAndMinimum() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        let estimate = try await f.library.estimate(game, voices: ["en-us"], at: f.install)
        #expect(estimate.diskWhole > estimate.diskMinimum)
        #expect(estimate.diskMinimum > SpaceBudget.margin)
        #expect(estimate.download > 0); #expect(estimate.available == Int64.max)
        #expect(!FileManager.default.fileExists(atPath: f.install.path))
        #expect(try await f.store.load(game.id) == nil)
    }

    @Test func uninstallRefusesAContainingRoot() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let nested = f.install.appendingPathComponent("OtherGame")
        try await f.store.save(GameRecord(installPath: nested, ownership: .created, executable: SafeRelativePath("Other.exe"), installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1)), for: "starrail")
        await #expect(throws: LauncherError.unsafePath("install location")) { try await f.library.uninstall(game) }
        try f.assertFiles(1)
    }

    @Test func adoptedUninstallNeverFollowsForeignSymlinks() async throws {
        let f = try LibraryFixture(); let outside = try TempDir(); try f.advertise(1); try f.seedExisting()
        let control = outside.url.appendingPathComponent("control"); let bytes = Data("outside".utf8); try bytes.write(to: control)
        let link = f.install.appendingPathComponent("foreign-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        try await f.library.uninstall(game)
        #expect(try Data(contentsOf: control) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.url.path)
    }

    @Test func adoptedUninstallRetriesAfterExecutableWasRemoved() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        var record = try #require(try await f.store.load(game.id)); record.uninstalling = true
        try await f.store.save(record, for: game.id)
        try f.fs.removeFile(at: SafeRelativePath("Game.exe"))
        try await f.restarted().uninstall(game)
        #expect(try await f.store.load(game.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.install.path))
    }

    @Test func concurrentOperationIsRefusedBeforeNetwork() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        for try await event in await f.library.verify(game, mode: .full) {
            #expect(event == .phase(.verifying))
            let before = f.cdn.requestLog.count
            await #expect(throws: LauncherError.busy("another game operation is running")) {
                _ = try await libraryCollect(await f.restarted().install(GameDefinition.all[1], voices: [],
                    at: f.base.appendingPathComponent("Other"), approved: true))
            }
            #expect(f.cdn.requestLog.count == before)
            break
        }
        #expect(try await libraryCollect(await f.library.verify(game, mode: .full)).last == .phase(.completed))
    }

    @Test func adoptCannotCompleteWithoutConfiguredExecutable() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        f.cdn.serve("hyp/hyp-connect/api/getGameConfigs", data: try jsonData(["launch_configs": [["game": ["id": "test", "biz": game.biz],
            "installation_dir": "TestGame", "exe_file_name": "Missing.exe"]]]))
        await #expect(throws: LauncherError.io("game executable missing")) {
            _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        }
        #expect(try await f.store.load(game.id)?.installed == nil)
        #expect(try await f.store.load(game.id) == nil)
        #expect(try f.fs.itemType(at: SafeRelativePath(".macgacha-staging")) == nil)
        #expect(try f.fs.itemType(at: SafeRelativePath(".macgacha-receipts")) == nil)
    }

    @Test func pausedAdoptWithoutExecutableCanStillBeUninstalled() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        try f.fs.writeAtomically(Data("mine".utf8), to: SafeRelativePath("foreign"))
        for try await event in await f.library.adopt(game, folder: f.install, voices: ["en-us"]) {
            if event == .phase(.checkingSpace) { break }
        }
        #expect(try await f.store.load(game.id)?.pending?.kind == .adopt)
        try f.fs.removeFile(at: SafeRelativePath("Game.exe"))
        try await f.library.uninstall(game)
        #expect(try await f.store.load(game.id) == nil)
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("mine".utf8))
    }

    @Test(arguments: ["release/1", String(repeating: "b", count: 256)])
    func opaqueBuildIDsProduceSafePlans(buildID: String) async throws {
        let f = try LibraryFixture(); try f.advertise(1, buildID: buildID)
        try await f.installGame()
        #expect(try await f.store.load(game.id)?.installed?.buildID == buildID)
        try f.assertFiles(1)
    }

    @Test func startupReconcilesPlanWithoutRecord() async throws {
        let f = try LibraryFixture()
        let plan = InstallPlan(id: try SafeIdentifier("orphan"), objects: [:], files: [], deletions: [])
        try await f.store.savePlan(plan, for: game.id)
        try await f.store.writeState(Data("{}".utf8), named: "branch.json", for: game.id)
        try await f.store.writeState(Data("[]".utf8), named: "managed-paths.json", for: game.id)
        try await f.store.writeState(Data("{}".utf8), named: "uninstall-cleaned.json", for: game.id)
        try ContainedFileSystem(root: await f.store.manifestCache(for: game.id)).writeAtomically(Data("cache".utf8), to: SafeRelativePath("manifest.zst"))
        await f.library.start()
        #expect(try await f.store.loadPlan(for: game.id) == nil)
        #expect(try await f.store.gameDirectories().isEmpty)
        #expect(f.cdn.requestLog.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func uninstallRefusesReplacementRoot(adopted: Bool, retry: Bool) async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        if adopted { try f.seedExisting(); _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"])) }
        else { try await f.installGame() }
        var record = try #require(try await f.store.load(game.id))
        if retry { record.uninstalling = true; try await f.store.save(record, for: game.id) }
        let old = f.base.appendingPathComponent("OldInstall")
        try FileManager.default.moveItem(at: f.install, to: old)
        try f.fs.writeAtomically(Data("unrelated".utf8), to: SafeRelativePath("Game.exe"))
        await #expect(throws: LauncherError.io("install folder was replaced")) { try await f.restarted().uninstall(game) }
        #expect(try f.fs.readFile(at: SafeRelativePath("Game.exe"), maxBytes: 100) == Data("unrelated".utf8))
        #expect(try await f.store.load(game.id) == record)
        #expect(try ContainedFileSystem(root: old).readFile(at: SafeRelativePath("Game.exe"), maxBytes: 100) == Data(syntheticFiles(1)["Game.exe"]!.utf8))
    }

    @Test func orphanReconciliationLeavesUnknownFilesUntouched() async throws {
        let f = try LibraryFixture()
        try await f.store.writeState(Data("user".utf8), named: "unexpected.json", for: game.id)
        await #expect(throws: LauncherError.journalCorrupt("unexpected game metadata")) {
            _ = try await OperationRunner(store: f.store, fetcher: ChunkFetcher(http: f.cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: f.disk, log: nil).reconcile(game.id)
        }
        #expect(try await f.store.readState("unexpected.json", for: game.id, maxBytes: 10) == Data("user".utf8))
    }

    @Test func partialRunnerUpdatePreservesAllTargetManagedPaths() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        try f.fs.writeAtomically(Data("foreign".utf8), to: SafeRelativePath("foreign"))
        let record = try #require(try await f.store.load(game.id))
        let installed = try #require(record.installed), body = Data("new executable".utf8)
        let path = try SafeRelativePath("Game.exe"), digest = md5Library(body)
        let object = ChunkObject(id: "partial", urls: [URL(string: "https://cdn.hoyoverse.com/partial")!],
            transferSize: Int64(body.count), decodedSize: Int64(body.count), decodedDigest: digest)
        let file = FileTask(path: path, size: Int64(body.count), digest: digest, extents: [
            Extent(source: .chunk(id: "partial"), fileOffset: 0, length: Int64(body.count), digest: digest),
        ])
        let plan = InstallPlan(id: try SafeIdentifier("partial-update"), objects: ["partial": object], files: [file])
        let target = InstalledBuild(tag: "new", buildID: "new", categories: installed.categories, voices: installed.voices)
        f.cdn.serve("partial", data: body)
        let runner = OperationRunner(store: f.store, fetcher: ChunkFetcher(http: f.cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: f.disk, log: nil)
        #expect(try await libraryCollect(await runner.start(game.id, record: record, plan: plan, kind: .update, target: target, approved: true,
            managedPaths: Set(try syntheticFiles(1).keys.map(SafeRelativePath.init)))).last == .phase(.completed))
        let before = f.cdn.requestLog.count
        try await f.library.uninstall(game)
        #expect(f.cdn.requestLog.count == before)
        for managed in syntheticFiles(1).keys { #expect(try f.fs.itemType(at: SafeRelativePath(managed)) == nil) }
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("foreign".utf8))
    }

    @Test(arguments: [false, true])
    func uninstallAfterDurableFileRemovalNeverReopensRoot(adopted: Bool) async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        if adopted {
            try f.seedExisting()
            try f.fs.writeAtomically(Data("original foreign".utf8), to: SafeRelativePath("old-foreign"))
            _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        } else { try await f.installGame() }
        let harness = Bundle(for: LibraryBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        let result = try await SystemProcessRunner().run(harness, arguments: [f.base.path, f.install.path,
            CrashPoint.afterGameFolderRemoved.rawValue, f.paths.games.path, "uninstall"], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 137)
        #expect(try await f.store.load(game.id)?.uninstallFilesRemoved == true)
        if adopted { try FileManager.default.moveItem(at: f.install, to: f.base.appendingPathComponent("old-root")) }
        try f.fs.writeAtomically(Data("unrelated".utf8), to: SafeRelativePath("control"))
        try await f.restarted().uninstall(game)
        #expect(try await f.store.load(game.id) == nil)
        #expect(try await f.store.gameDirectories().isEmpty)
        #expect(try f.fs.contentsOfRootDirectory() == [SafeRelativePath("control")])
        #expect(try f.fs.readFile(at: SafeRelativePath("control"), maxBytes: 100) == Data("unrelated".utf8))
    }

    @Test func recordWithoutIdentityIsCorrupt() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let record = try #require(try await f.store.load(game.id))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "installIdentity")
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try ContainedFileSystem(root: f.paths.games).writeAtomically(bytes, to: SafeRelativePath("genshin/record.json"))
        await #expect(throws: LauncherError.journalCorrupt("invalid game record")) { _ = try await f.store.load(game.id) }
        await #expect(throws: LauncherError.journalCorrupt("invalid game record")) { try await f.library.uninstall(game) }
        try f.assertFiles(1)
    }

    @Test func engineRefusesReplacementAfterPendingSave() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        let root = f.install, moved = f.base.appendingPathComponent("moved")
        let hookError = Mutex<String?>(nil)
        let hooks = CrashHooks(at: .afterGamePendingSaved, action: {
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try ContainedFileSystem(root: root).writeAtomically(Data("replacement".utf8), to: SafeRelativePath("control"))
            } catch { hookError.withLock { $0 = String(describing: error) } }
        })
        let library = f.restarted(runnerHooks: hooks)
        await #expect(throws: LauncherError.io("install folder was replaced")) {
            _ = try await libraryCollect(await library.install(game, voices: [], at: root, approved: true))
        }
        #expect(hookError.withLock { $0 } == nil)
        #expect(try await f.store.load(game.id)?.pending != nil)
        #expect(try f.fs.contentsOfRootDirectory() == [SafeRelativePath("control")])
        #expect(try f.fs.readFile(at: SafeRelativePath("control"), maxBytes: 100) == Data("replacement".utf8))
    }

    @Test func voiceDeletionRefusesAReplacementRoot() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        var replaced = false
        await #expect(throws: LauncherError.io("install folder was replaced")) {
            for try await event in await f.library.setVoices(game, []) {
                if event == .phase(.deleting), !replaced {
                    try FileManager.default.moveItem(at: f.install, to: f.base.appendingPathComponent("moved"))
                    try f.fs.writeAtomically(Data("foreign voice".utf8), to: SafeRelativePath("audio/en1"))
                    replaced = true
                }
            }
        }
        #expect(replaced)
        #expect(try f.fs.readFile(at: SafeRelativePath("audio/en1"), maxBytes: 100) == Data("foreign voice".utf8))
        #expect(try f.fs.contentsOfRootDirectory() == [SafeRelativePath("audio")])
        #expect(try await f.store.load(game.id)?.pending?.kind == .voices)
    }

    @Test func engineRefusesReplacementBetweenBatches() async throws {
        let disk = LibraryDisk(); let f = try LibraryFixture(disk: disk)
        try f.advertise(1); try await f.installGame(); try f.advertise(2)
        disk.bytes.withLock { $0 = SpaceBudget.margin + 48 }
        var replaced = false
        await #expect(throws: LauncherError.io("install folder was replaced")) {
            for try await event in await f.library.update(game, approved: true) {
                if event == .phase(.checkingSpace), !replaced, let pending = try await f.store.load(game.id)?.pending {
                    let state = try OperationJournal.replay(fs: f.fs, path: SafeRelativePath(".macgacha-staging/\(pending.planID)/journal.jsonl"))
                    if !state.committedFiles.isEmpty {
                        try FileManager.default.moveItem(at: f.install, to: f.base.appendingPathComponent("moved"))
                        try f.fs.writeAtomically(Data("replacement".utf8), to: SafeRelativePath("control"))
                        replaced = true
                    }
                }
            }
        }
        #expect(replaced)
        #expect(try await f.store.load(game.id)?.pending != nil)
        #expect(try f.fs.contentsOfRootDirectory() == [SafeRelativePath("control")])
    }

    @Test func installRechecksFolderAfterMetadataFetch() async throws {
        let gate = LibraryMetadataGate(); let f = try LibraryFixture(metadataGate: gate); try f.advertise(1)
        let library = f.library, location = f.install
        let task = Task { try await libraryCollect(await library.install(game, voices: [], at: location, approved: true)) }
        await gate.waitUntilEntered()
        try f.fs.writeAtomically(Data("arrived".utf8), to: SafeRelativePath("foreign"))
        await gate.release()
        await #expect(throws: LauncherError.io("folder is not empty — use an existing installation instead")) { _ = try await task.value }
        #expect(try await f.store.load(game.id) == nil)
        #expect(try f.fs.contentsOfRootDirectory() == [SafeRelativePath("foreign")])
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("arrived".utf8))
    }

    @Test func adoptedUninstallIsOfflineWithoutManifestCache() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try f.seedExisting()
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        try f.fs.writeAtomically(Data("foreign".utf8), to: SafeRelativePath("foreign"))
        try await f.store.deleteManifestCache(for: game.id)
        let offline = MockCDN(); try await f.restarted(http: offline).uninstall(game)
        #expect(offline.requestLog.isEmpty)
        #expect(try f.fs.itemType(at: SafeRelativePath("Game.exe")) == nil)
        #expect(try f.fs.readFile(at: SafeRelativePath("foreign"), maxBytes: 100) == Data("foreign".utf8))
    }

    @Test(arguments: ["data/01", "data"])
    func adoptedUninstallSkipsManagedSymlinks(path: String) async throws {
        let f = try LibraryFixture(); let outside = try TempDir(); try f.advertise(1); try f.seedExisting()
        _ = try await libraryCollect(await f.library.adopt(game, folder: f.install, voices: ["en-us"]))
        let control = outside.url.appendingPathComponent("01"); try Data("outside".utf8).write(to: control)
        let link = f.install.appendingPathComponent(path); try FileManager.default.removeItem(at: link)
        let target = path == "data" ? outside.url : control
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await f.library.uninstall(game)
        #expect(try Data(contentsOf: control) == Data("outside".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try await f.store.load(game.id) == nil)
    }

    @Test func estimateIncludesCrossBatchSharedParts() async throws {
        let disk = LibraryDisk(); let f = try LibraryFixture(disk: disk)
        try f.advertise(1, sharedAcrossFiles: true)
        let estimate = try await f.library.estimate(game, voices: [], at: f.install)
        #expect(estimate.diskMinimum < estimate.diskWhole)
        disk.bytes.withLock { $0 = estimate.diskMinimum - 1 }
        await #expect(throws: LauncherError.insufficientSpace(required: estimate.diskMinimum, available: estimate.diskMinimum - 1)) {
            _ = try await libraryCollect(await f.library.install(game, voices: [], at: f.install, approved: true))
        }
        let plan = try #require(try await f.store.loadPlan(for: game.id))
        let preflight = try SpaceBudget.batchedPreflight(plan: plan, state: JournalState(), fs: f.fs, available: estimate.diskMinimum)
        #expect(preflight.required == estimate.diskMinimum)
        #expect(preflight.batches.count > 1)
        let first = preflight.batches.firstIndex { $0.contains { $0.path.description == "data/01" } }
        let second = preflight.batches.firstIndex { $0.contains { $0.path.description == "data/02" } }
        #expect(first != second)
        disk.bytes.withLock { $0 = estimate.diskMinimum }
        let resumed = try await libraryCollect(await f.library.resume(game, approved: true))
        #expect(resumed.last == .phase(.completed))
        #expect(resumed.filter { $0 == .phase(.committing) }.count > 1)
        for (path, body) in syntheticFiles(1, sharedAcrossFiles: true) where !path.hasPrefix("audio/") {
            #expect(try f.fs.readFile(at: SafeRelativePath(path), maxBytes: 1000) == Data(body.utf8))
        }
    }

    @Test func uninstallRetiresGameDirectory() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        try await f.library.uninstall(game)
        #expect(!FileManager.default.fileExists(atPath: f.paths.games.appendingPathComponent(game.id).path))
        #expect(try await f.store.gameDirectories().isEmpty)
    }

    @Test(arguments: ["verify", "adopt", "voices"])
    func approvalRequiredByNonInstallOperationsResumes(operation: String) async throws {
        let disk = LibraryDisk(); let f = try LibraryFixture(disk: disk); try f.advertise(1)
        let stream: AsyncThrowingStream<OperationEvent, any Error>
        if operation == "voices" {
            _ = try await libraryCollect(await f.library.install(game, voices: [], at: f.install, approved: true))
            disk.bytes.withLock { $0 = SpaceBudget.margin + 30 }
            stream = await f.library.setVoices(game, ["en-us"])
        } else {
            if operation == "verify" { try await f.installGame() } else { try f.seedExisting() }
            for path in syntheticFiles(1).keys { try f.fs.writeAtomically(Data("bad".utf8), to: SafeRelativePath(path)) }
            disk.bytes.withLock { $0 = SpaceBudget.margin + 48 }
            stream = operation == "verify" ? await f.library.verify(game, mode: .full) : await f.library.adopt(game, folder: f.install, voices: ["en-us"])
        }
        let events = try await libraryCollect(stream)
        #expect(events.contains { if case .needsBatchApproval = $0 { true } else { false } })
        #expect(!events.contains(.phase(.completed)))
        #expect(try await f.store.load(game.id)?.pending != nil)
        #expect(try await libraryCollect(await f.library.resume(game, approved: true)).last == .phase(.completed))
        try f.assertFiles(1)
    }

    @Test(arguments: [false, true])
    func opaqueManifestIDsAreCachedWithoutPathTraversal(collidingID: Bool) async throws {
        let f = try LibraryFixture(); try f.advertise(1, opaqueIDs: true, collidingID: collidingID); try await f.installGame()
        try f.assertFiles(1)
        let cache = try ContainedFileSystem(root: await f.store.manifestCache(for: game.id))
        let paths = try cache.contentsOfRootDirectory()
        #expect(paths.count == 3)
        #expect(paths.allSatisfy { $0.components.count == 1 && $0.description.hasSuffix(".zst") })
    }
}

private let game = GameDefinition.all[0]
private final class LibraryBundleToken: NSObject {}
private final class LibraryDisk: DiskSpaceProbe, Sendable {
    let bytes = Mutex(Int64.max)
    func availableBytes(at url: URL) throws -> Int64 { bytes.withLock { $0 } }
}
private struct LibraryFixture: ~Copyable {
    let temp: TempDir
    let base: URL
    let paths: AppPaths
    let install: URL
    let store: GameRecordStore
    let cdn: MockCDN
    let library: GameLibrary
    let disk: any DiskSpaceProbe
    var fs: ContainedFileSystem { get throws { try ContainedFileSystem(root: install) } }
    init(disk: any DiskSpaceProbe = FixedDiskSpace(bytes: Int64.max), metadataGate: LibraryMetadataGate? = nil) throws {
        temp = try TempDir(); base = temp.url; paths = AppPaths(root: base.appendingPathComponent("App"))
        install = base.appendingPathComponent("Install"); store = GameRecordStore(directory: paths.games)
        cdn = MockCDN(); self.disk = disk
        let http: any HTTPClient
        if let metadataGate { http = LibraryDelayedHTTP(cdn: cdn, gate: metadataGate) } else { http = cdn }
        library = GameLibrary(paths: paths, api: DeliveryAPI(http: http), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: disk, log: nil), store: store, disk: disk, log: nil)
    }
    func restarted(http: (any HTTPClient)? = nil, runnerHooks: CrashHooks = .none) -> GameLibrary {
        GameLibrary(paths: paths, api: DeliveryAPI(http: http ?? cdn), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: disk, log: nil, crashHooks: runnerHooks), store: store, disk: disk, log: nil)
    }
    func installGame() async throws { _ = try await libraryCollect(await library.install(game, voices: ["en-us"], at: install, approved: true)) }
    func seedExisting() throws {
        for (path, body) in syntheticFiles(1) { try fs.writeAtomically(Data(body.utf8), to: SafeRelativePath(path)) }
        try fs.writeAtomically(Data("bad".utf8), to: SafeRelativePath("Game.exe"))
    }
    func assertFiles(_ version: Int) throws {
        for (path, body) in syntheticFiles(version) { #expect(try fs.readFile(at: SafeRelativePath(path), maxBytes: 100) == Data(body.utf8)) }
    }
    func advertise(_ version: Int, opaqueIDs: Bool = false, collidingID: Bool = false, buildID: String? = nil, sharedAcrossFiles: Bool = false) throws {
        let groups = [("base", "game"), ("extra", "extra"), ("voice", "en-us")]
        let categories: [[String: Any]] = groups.map { id, matching in ["category_id": id, "matching_field": matching,
            "type": id == "voice" ? "CATEGORY_TYPE_AUDIO" : "CATEGORY_TYPE_RESOURCE", "scenarios": ["CATEGORY_SCENARIO_FULL"]] }
        cdn.serve("hyp/hyp-connect/api/getGameBranches", data: try jsonData(["game_branches": [["game": ["id": "test", "biz": game.biz],
            "main": ["package_id": "public-package", "password": "public-selector", "branch": "main", "tag": "\(version).0", "categories": categories]]]]))
        cdn.serve("hyp/hyp-connect/api/getGameConfigs", data: try jsonData(["launch_configs": [["game": ["id": "test", "biz": game.biz], "installation_dir": "TestGame", "exe_file_name": "Game.exe"]]]))
        var descriptors: [[String: Any]] = []
        for (id, matching) in groups {
            var manifest = ProtobufWriter()
            for (path, body) in syntheticFiles(version, sharedAcrossFiles: sharedAcrossFiles).sorted(by: { $0.key < $1.key }) {
                let belongs = id == "base" ? (path == "Game.exe" || (path.hasPrefix("data/") && Int(path.suffix(2))! < 10)) :
                    id == "extra" ? (path == "shared.bin" || (path.hasPrefix("data/") && Int(path.suffix(2))! >= 10)) : (path.hasPrefix("audio/") || path == "shared.bin")
                if !belongs { continue }
                let pieces: [String]
                if sharedAcrossFiles && (path == "data/01" || path == "data/02") { pieces = ["common", String(body.dropFirst(6))] }
                else { pieces = path == "Game.exe" ? ["common", "v\(version)!!!"] : [body] }
                var file = ProtobufWriter(); file.string(1, path); var offset: UInt64 = 0
                for piece in pieces {
                    let decoded = Data(piece.utf8); let checksum = md5Library(decoded); let object = checksum.hex
                    let compressed = rawZstd(decoded); cdn.serve("chunks/\(object)", data: compressed)
                    var chunk = ProtobufWriter(); chunk.string(1, object); chunk.string(2, checksum.hex)
                    chunk.varint(3, offset); chunk.varint(4, UInt64(compressed.count)); chunk.varint(5, UInt64(decoded.count))
                    file.bytes(2, chunk.data); offset += UInt64(decoded.count)
                }
                file.varint(4, UInt64(body.utf8.count)); file.string(5, md5Library(Data(body.utf8)).hex); manifest.bytes(1, file.data)
            }
            let compressed = rawZstd(manifest.data)
            var manifestID = "v\(version)-\(id)" + (opaqueIDs ? "/opaque" : "")
            if collidingID, id == "base" {
                var hash = StreamingHasher(.sha256); hash.update(Data("v\(version)-voice/opaque".utf8))
                manifestID = hash.finalize().hex
            }
            cdn.serve("manifests/\(manifestID)", data: compressed)
            let descriptor: [String: Any] = ["url_prefix": "https://cdn.hoyoverse.com/manifests", "url_suffix": "", "compression": 1, "encryption": 0, "password": ""]
            var chunks = descriptor; chunks["url_prefix"] = "https://cdn.hoyoverse.com/chunks"
            descriptors.append(["category_id": id, "matching_field": matching, "manifest": ["id": manifestID, "checksum": md5Library(manifest.data).hex,
                "compressed_size": String(compressed.count), "uncompressed_size": String(manifest.data.count)],
                "manifest_download": descriptor, "chunk_download": chunks, "stats": ["compressed_size": "1000", "uncompressed_size": "1000"]])
        }
        cdn.serve("downloader/sophon_chunk/api/getBuild", data: try jsonData(["build_id": buildID ?? "build-\(version)", "tag": "\(version).0", "manifests": descriptors]))
    }
}
private func syntheticFiles(_ version: Int, sharedAcrossFiles: Bool = false) -> [String: String] {
    var files = ["Game.exe": "commonv\(version)!!!", "shared.bin": "shared-resource", "audio/en1": "voice-1", "audio/en2": "voice-2"]
    for i in 1...17 { files[String(format: "data/%02d", i)] = i == 1 ? "edit-\(version)" : "file-\(i)" }
    if sharedAcrossFiles {
        files["data/01"] = "common" + String(repeating: "A", count: 100)
        files["data/02"] = "common" + String(repeating: "B", count: 100)
    }
    return files
}
private func jsonData(_ data: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": data], options: [.sortedKeys]) }
private func md5Library(_ data: Data) -> Digest { var h = StreamingHasher(.md5); h.update(data); return h.finalize() }
/// Synthetic zstd single-segment frame: 4-byte content size and one final raw block.
private func rawZstd(_ data: Data) -> Data {
    var result = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    let size = UInt32(data.count), block = UInt32(data.count) << 3 | 1
    for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: size >> shift)) }
    for shift in stride(from: 0, to: 24, by: 8) { result.append(UInt8(truncatingIfNeeded: block >> shift)) }
    result.append(data); return result
}
private func libraryCollect(_ stream: AsyncThrowingStream<OperationEvent, any Error>) async throws -> [OperationEvent] {
    var events: [OperationEvent] = []; for try await event in stream { events.append(event) }; return events
}
private func pauseAfterBatch(_ stream: AsyncThrowingStream<OperationEvent, any Error>, fs: ContainedFileSystem, store: GameRecordStore) async throws {
    for try await event in stream where event == .phase(.checkingSpace) {
        if let pending = try await store.load(game.id)?.pending {
            let state = try OperationJournal.replay(fs: fs, path: SafeRelativePath(".macgacha-staging/\(pending.planID)/journal.jsonl"))
            if !state.committedFiles.isEmpty { return }
        }
    }
    Issue.record("No partial batch boundary")
}

private actor LibraryMetadataGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        for observer in observers { observer.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct LibraryDelayedHTTP: HTTPClient {
    let cdn: MockCDN
    let gate: LibraryMetadataGate
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if url.path.hasSuffix("getGameConfigs") { await gate.pause() }
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}
