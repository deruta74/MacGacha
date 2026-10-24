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

@Suite(.serialized, .timeLimit(.minutes(1))) struct GameLibraryTests {
    @Test(arguments: ["install", "adopt", "update", "resume", "verify", "voices", "uninstall"])
    func verifyRefusedWhileGuardThrows(operation: String) async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let blocker = LibraryOperationGuard(blocked: game.id)
        let library = f.restarted(operationGuard: blocker)
        // A held lease must not mask the guard's refusal or allow state cleanup.
        let lease = try await f.store.acquireOperationLease()
        defer { withExtendedLifetime(lease) {} }
        let before = try libraryStateFiles(at: f.paths.games)
        let installed = try libraryStateFiles(at: f.install)
        do {
            if operation == "uninstall" { try await library.uninstall(game) }
            else {
                let stream = switch operation {
                case "install": await library.install(game, voices: ["en-us"], at: f.install, approved: true)
                case "adopt": await library.adopt(game, folder: f.install, voices: ["en-us"])
                case "update": await library.update(game, approved: true)
                case "resume": await library.resume(game, approved: true)
                case "verify": await library.verify(game, mode: .full)
                default: await library.setVoices(game, ["en-us"])
                }
                _ = try await libraryCollect(stream)
            }
            Issue.record("Guarded operation proceeded")
        } catch { #expect(error as? LauncherError == .busy("guard denied operation")) }
        #expect(blocker.calls.withLock { $0 } == [game.id])
        #expect(try libraryStateFiles(at: f.paths.games) == before)
        #expect(try libraryStateFiles(at: f.install) == installed)
    }

    @Test(arguments: ["install", "adopt", "update", "resume", "verify", "voices", "uninstall"])
    func heldSessionLockBlocksEveryOperationBeforeMutation(operation: String) async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let fs = try ContainedFileSystem(root: f.paths.games)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("\(game.id)/.session.lock"))
        defer { withExtendedLifetime(lock) {} }
        let before = try libraryStateFiles(at: f.paths.games)
        let installed = try libraryStateFiles(at: f.install)
        do {
            if operation == "uninstall" { try await f.library.uninstall(game) }
            else {
                let stream = switch operation {
                case "install": await f.library.install(game, voices: ["en-us"], at: f.install, approved: true)
                case "adopt": await f.library.adopt(game, folder: f.install, voices: ["en-us"])
                case "update": await f.library.update(game, approved: true)
                case "resume": await f.library.resume(game, approved: true)
                case "verify": await f.library.verify(game, mode: .full)
                default: await f.library.setVoices(game, ["en-us"])
                }
                _ = try await libraryCollect(stream)
            }
            Issue.record("Operation ignored live session ownership")
        } catch LauncherError.busy { }
        #expect(try libraryStateFiles(at: f.paths.games) == before)
        #expect(try libraryStateFiles(at: f.install) == installed)
    }

    @Test func sessionClaimedBetweenGuardAndOperationLeaseRefusesMutation() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        let before = try libraryStateFiles(at: f.paths.games)
        let guardClaim = SessionClaimingLibraryGuard(paths: f.paths)
        let library = f.restarted(operationGuard: guardClaim)
        do {
            _ = try await libraryCollect(await library.verify(game, mode: .full))
            Issue.record("Operation crossed a session claimed after its guard check")
        } catch LauncherError.busy { }
        #expect(try libraryStateFiles(at: f.paths.games) == before)
    }

    @Test func otherGameStillInstalls() async throws {
        let f = try LibraryFixture()
        let other = GameDefinition.all.first { $0.id == "zzz" }!
        try f.advertise(1, games: [other])
        let blocker = LibraryOperationGuard(blocked: "starrail")
        let library = f.restarted(operationGuard: blocker)
        _ = try await libraryCollect(await library.install(other, voices: ["en-us"], at: f.install, approved: true))
        #expect(try await f.store.load(other.id)?.installed != nil)
        #expect(blocker.calls.withLock { $0 } == [other.id])
    }

    @Test(arguments: [false, true])
    func branchCacheWriteSurvivesAnotherStoresOperationSweep(expired: Bool) async throws {
        let gate = BranchWriteGate(), f = try LibraryFixture(fileOps: gate)
        try f.advertise(1)
        let library = f.library, location = f.install
        let estimate = Task { try await library.estimate(game, voices: ["en-us"], at: location) }
        defer { gate.release() }
        try await gate.waitUntilPaused()
        let fs = try ContainedFileSystem(root: f.paths.games)
        let files = try fs.contentsOfDirectory(at: SafeRelativePath(game.id))
        let temporary = try #require(files.first { $0.components.last!.hasPrefix(".macgacha-") })
        if expired {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                ofItemAtPath: temporary.resolved(against: f.paths.games).path)
        }
        let other = GameRecordStore(directory: f.paths.games)
        let runner = OperationRunner(store: other, fetcher: ChunkFetcher(http: f.cdn,
            retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: FixedDiskSpace(bytes: Int64.max), log: nil)
        #expect(try await runner.reconcile(game.id) == nil)
        #expect(try fs.itemType(at: temporary) == (expired ? nil : .regularFile))
        gate.release()
        #expect(try await estimate.value.download > 0)
        #expect(try fs.itemType(at: temporary) == nil)
        #expect((try await other.readState("branch.json", for: game.id, maxBytes: 2 << 20) != nil) == !expired)
        // A swept writer returns its fresh branch; a later request repairs the cache.
        #expect(try await library.estimate(game, voices: ["en-us"], at: location).download > 0)
        #expect(try await other.readState("branch.json", for: game.id, maxBytes: 2 << 20) != nil)
        #expect(try await other.load(game.id) == nil)
    }

    @Test(arguments: [false, true])
    func manifestCacheFailureDoesNotPreventEstimateOrInstall(unavailable: Bool) async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        let cacheURL = try await f.store.manifestCache(for: game.id)
        if unavailable {
            try FileManager.default.removeItem(at: cacheURL)
            try Data("not a directory".utf8).write(to: cacheURL)
        } else {
            // A directory where a cache leaf belongs prevents its atomic replacement.
            try FileManager.default.createDirectory(at: cacheURL.appendingPathComponent("v1-base.zst"), withIntermediateDirectories: false)
        }
        #expect(try await f.library.estimate(game, voices: ["en-us"], at: f.install).download > 0)
        #expect(try await f.store.load(game.id) == nil)
        try await f.installGame()
        try f.assertFiles(1)
    }

    @Test(arguments: ["branch.json", ".zst"])
    func cacheRenameFailureReturnsVerifiedDataAndCleansTemporary(suffix: String) async throws {
        let logs = try TempDir(), log = EventLog(directory: logs.url)
        let gate = BranchWriteGate(failingSuffix: suffix)
        let f = try LibraryFixture(fileOps: gate, log: log); try f.advertise(1)
        #expect(try await f.library.estimate(game, voices: ["en-us"], at: f.install).download > 0)
        let cache = try ContainedFileSystem(root: f.paths.games)
        let directory = try SafeRelativePath(suffix == "branch.json" ? game.id : "\(game.id)/manifests")
        #expect(try cache.contentsOfDirectory(at: directory).isEmpty == (suffix == ".zst"))
        let leaves = try cache.contentsOfDirectory(at: directory)
        #expect(!leaves.contains { $0.components.last!.hasPrefix(".macgacha-") })
        let destination = try SafeRelativePath(suffix == "branch.json" ? "\(game.id)/branch.json" : "\(game.id)/manifests/v1-base.zst")
        #expect(try cache.itemType(at: destination) == nil)
        let text = try String(contentsOf: logs.url.appendingPathComponent("macgacha.log"), encoding: .utf8)
        #expect(text.contains("game-library"))
        #expect(!text.contains("secret") && !text.contains("https://") && !text.contains(f.base.path))
        gate.release()
        #expect(try await f.library.estimate(game, voices: ["en-us"], at: f.install).download > 0)
        #expect(try cache.itemType(at: destination) == .regularFile)
        #expect(try await f.store.load(game.id) == nil)
    }

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
        try f.advertise(1); try await f.installGame(); try f.advertise(2, changedFiles: 4)
        disk.bytes.withLock { $0 = SpaceBudget.margin + 80 }
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
        _ = try await libraryCollect(await f.library.resume(game, approved: true)); try f.assertFiles(2, changedFiles: 4)
    }

    @Test func uninstallPausedFreshInstallBeforeFirstCommit() async throws {
        let f = try LibraryFixture(); try f.advertise(1)
        for try await event in await f.library.install(game, voices: ["en-us"], at: f.install, approved: true) {
            if case .fileVerified = event { break }
        }
        #expect(try await f.store.load(game.id)?.pending != nil)
        #expect(try f.fs.itemType(at: SafeRelativePath("Game.exe")) == nil)
        // Dropping a stream cancels workers asynchronously. Uninstall correctly
        // stays busy while they drain; reconcile is the supported drain barrier.
        let runner = OperationRunner(store: f.store, fetcher: ChunkFetcher(http: f.cdn,
            retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: f.disk, log: nil)
        _ = try await runner.reconcile(game.id)
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
        try await expectOnlyRetainedSessionLock(f)
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

    @Test(arguments: [Int64?(300), 50, nil]) func estimateSeparatesPurgeableFromUsableSpace(important: Int64?) async throws {
        let f = try LibraryFixture(disk: FixedDiskSpace(bytes: 100), purgeable: LibraryPurgeable(bytes: important))
        try f.advertise(1)
        let estimate = try await f.library.estimate(game, voices: ["en-us"], at: f.install)
        #expect(estimate.available == 100)
        #expect(estimate.purgeable == important.map { max(0, $0 - 100) })
        #expect(try await f.store.load(game.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.install.path))
    }

    @Test(arguments: [false, true]) func blockedEstimateDoesNotPreventInstallOrAdopt(adopt: Bool) async throws {
        let gate = LibraryRequestGate(pathSuffix: "getGameBranches")
        let f = try LibraryFixture(requestGate: gate); try f.advertise(1)
        let library = f.library, location = f.install
        let estimate = Task { try await library.estimate(game, voices: ["en-us"], at: location) }
        defer { estimate.cancel(); gate.release() }
        try await gate.waitUntilEntered()
        if adopt { try f.seedExisting() }
        let stream = adopt ? await library.adopt(game, folder: location, voices: ["en-us"]) :
            await library.install(game, voices: ["en-us"], at: location, approved: true)
        let events = try await libraryCollect(stream)
        #expect(events.last == .phase(.completed)); try f.assertFiles(1)
        let record = try #require(try await f.store.load(game.id))
        let managed = try await f.store.readState("managed-paths.json", for: game.id, maxBytes: 1 << 20)
        gate.release()
        #expect(try await estimate.value.download > 0)
        #expect(try await f.store.load(game.id) == record)
        #expect(try await f.store.loadPlan(for: game.id) == nil)
        #expect(try await f.store.readState("managed-paths.json", for: game.id, maxBytes: 1 << 20) == managed)
        try f.assertFiles(1)
    }

    @Test func overlappingEstimatesBothSucceedWithoutCreatingOperationState() async throws {
        let gate = LibraryRequestGate(pathSuffix: "getGameBranches")
        let f = try LibraryFixture(requestGate: gate); try f.advertise(1)
        let library = f.library, location = f.install
        let first = Task { try await library.estimate(game, voices: ["en-us"], at: location) }
        defer { first.cancel(); gate.release() }
        try await gate.waitUntilEntered()
        let second = try await library.estimate(game, voices: [], at: location)
        #expect(second.download > 0)
        gate.release()
        #expect(try await first.value.download > second.download)
        #expect(try await f.store.load(game.id) == nil)
        #expect(try await f.store.loadPlan(for: game.id) == nil)
        #expect(try await f.store.readState("managed-paths.json", for: game.id, maxBytes: 1 << 20) == nil)
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }

    @Test(arguments: [false, true]) func estimateDuringRunningInstallSucceeds(otherGame: Bool) async throws {
        let gate = LibraryRequestGate(pathSuffix: "getGameConfigs")
        let f = try LibraryFixture(requestGate: gate)
        let other = GameDefinition.all[1]
        try f.advertise(1, games: [game, other])
        let library = f.library, location = f.install
        let install = Task { try await libraryCollect(await library.install(game, voices: [], at: location, approved: true)) }
        defer { install.cancel(); gate.release() }
        try await gate.waitUntilEntered()
        let selected = otherGame ? other : game
        let estimateLocation = f.base.appendingPathComponent("Estimate")
        let estimate = try await library.estimate(selected, voices: ["en-us"], at: estimateLocation)
        #expect(estimate.download > 0)
        #expect(try await f.store.load(selected.id) == nil)
        #expect(try await f.store.loadPlan(for: selected.id) == nil)
        #expect(try await f.store.readState("managed-paths.json", for: selected.id, maxBytes: 1 << 20) == nil)
        #expect(!FileManager.default.fileExists(atPath: estimateLocation.path))
        gate.release()
        #expect(try await install.value.last == .phase(.completed))
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

    @Test func startupLeavesLiveSessionMetadataUntouched() async throws {
        let f = try LibraryFixture()
        let plan = InstallPlan(id: try SafeIdentifier("orphan"), objects: [:], files: [], deletions: [])
        try await f.store.savePlan(plan, for: game.id)
        let fs = try ContainedFileSystem(root: f.paths.games)
        var lock: InstallLock? = try InstallLock(fs: fs, path: SafeRelativePath("\(game.id)/.session.lock"))
        await f.library.start()
        #expect(try await f.store.loadPlan(for: game.id) != nil)
        withExtendedLifetime(lock) {}
        lock = nil
        await f.restarted().start()
        #expect(try await f.store.loadPlan(for: game.id) == nil)
        try await expectOnlyRetainedSessionLock(f)
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
        try await expectOnlyRetainedSessionLock(f)
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
        try await expectOnlyRetainedSessionLock(f)
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
        try f.advertise(1); try await f.installGame(); try f.advertise(2, changedFiles: 4)
        disk.bytes.withLock { $0 = SpaceBudget.margin + 80 }
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

    @Test func uninstallRetiresMetadataButPreservesSessionLock() async throws {
        let f = try LibraryFixture(); try f.advertise(1); try await f.installGame()
        try await f.library.uninstall(game)
        try await expectOnlyRetainedSessionLock(f)
    }

    @Test(arguments: ["verify", "adopt", "voices"])
    func approvalRequiredByNonInstallOperationsResumes(operation: String) async throws {
        let disk = LibraryDisk(); let f = try LibraryFixture(disk: disk); try f.advertise(1)
        let stream: AsyncThrowingStream<OperationEvent, any Error>
        if operation == "voices" {
            _ = try await libraryCollect(await f.library.install(game, voices: [], at: f.install, approved: true))
            disk.bytes.withLock { $0 = SpaceBudget.margin + 33 }
            stream = await f.library.setVoices(game, ["en-us"])
        } else {
            if operation == "verify" { try await f.installGame() } else { try f.seedExisting() }
            for (path, body) in syntheticFiles(1) { try f.fs.writeAtomically(Data(repeating: 0x42, count: body.count), to: SafeRelativePath(path)) }
            disk.bytes.withLock { $0 = SpaceBudget.margin + 185 }
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
    init(disk: any DiskSpaceProbe = FixedDiskSpace(bytes: Int64.max), purgeable: any PurgeableSpaceProbe = LibraryPurgeable(bytes: nil), metadataGate: LibraryMetadataGate? = nil, requestGate: LibraryRequestGate? = nil,
        fileOps: any FileOps = SystemFileOps(), log: EventLog? = nil) throws {
        temp = try TempDir(); base = temp.url; paths = AppPaths(root: base.appendingPathComponent("App"))
        install = base.appendingPathComponent("Install"); store = GameRecordStore(directory: paths.games, fileOps: fileOps)
        cdn = MockCDN(); self.disk = disk
        let http: any HTTPClient
        if let requestGate { http = LibraryGatedHTTP(cdn: cdn, gate: requestGate) }
        else if let metadataGate { http = LibraryDelayedHTTP(cdn: cdn, gate: metadataGate) } else { http = cdn }
        library = GameLibrary(paths: paths, api: DeliveryAPI(http: http), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: disk, log: log), store: store, disk: disk, log: log, fileOps: fileOps, purgeable: purgeable)
    }
    func restarted(http: (any HTTPClient)? = nil, runnerHooks: CrashHooks = .none, operationGuard: (any GameOperationGuard)? = nil) -> GameLibrary {
        GameLibrary(paths: paths, api: DeliveryAPI(http: http ?? cdn), runner: OperationRunner(store: store,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), disk: disk, log: nil, crashHooks: runnerHooks), store: store, disk: disk, log: nil, guard: operationGuard)
    }
    func installGame() async throws { _ = try await libraryCollect(await library.install(game, voices: ["en-us"], at: install, approved: true)) }
    func seedExisting() throws {
        for (path, body) in syntheticFiles(1) { try fs.writeAtomically(Data(body.utf8), to: SafeRelativePath(path)) }
        try fs.writeAtomically(Data("bad".utf8), to: SafeRelativePath("Game.exe"))
    }
    func assertFiles(_ version: Int, changedFiles: Int = 1) throws {
        for (path, body) in syntheticFiles(version, changedFiles: changedFiles) { #expect(try fs.readFile(at: SafeRelativePath(path), maxBytes: 100) == Data(body.utf8)) }
    }
    func advertise(_ version: Int, opaqueIDs: Bool = false, collidingID: Bool = false, buildID: String? = nil, sharedAcrossFiles: Bool = false, changedFiles: Int = 1, games: [GameDefinition] = [game]) throws {
        let groups = [("base", "game"), ("extra", "extra"), ("voice", "en-us")]
        let categories: [[String: Any]] = groups.map { id, matching in ["category_id": id, "matching_field": matching,
            "type": id == "voice" ? "CATEGORY_TYPE_AUDIO" : "CATEGORY_TYPE_RESOURCE", "scenarios": ["CATEGORY_SCENARIO_FULL"]] }
        cdn.serve("hyp/hyp-connect/api/getGameBranches", data: try jsonData(["game_branches": games.map { game in ["game": ["id": "test", "biz": game.biz],
            "main": ["package_id": "public-package", "password": "public-selector", "branch": "main", "tag": "\(version).0", "categories": categories]] }]))
        cdn.serve("hyp/hyp-connect/api/getGameConfigs", data: try jsonData(["launch_configs": games.map { game in ["game": ["id": "test", "biz": game.biz], "installation_dir": "TestGame", "exe_file_name": "Game.exe"] }]))
        var descriptors: [[String: Any]] = []
        for (id, matching) in groups {
            var manifest = ProtobufWriter()
            for (path, body) in syntheticFiles(version, sharedAcrossFiles: sharedAcrossFiles, changedFiles: changedFiles).sorted(by: { $0.key < $1.key }) {
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
private func syntheticFiles(_ version: Int, sharedAcrossFiles: Bool = false, changedFiles: Int = 1) -> [String: String] {
    var files = ["Game.exe": "commonv\(version)!!!", "shared.bin": "shared-resource", "audio/en1": "voice-1", "audio/en2": "voice-2"]
    for i in 1...17 { files[String(format: "data/%02d", i)] = i == 1 ? "edit-\(version)" : (i <= changedFiles ? "edit-\(version)-\(i)" : "file-\(i)") }
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

/// Holds the first matching MockCDN response, leaving later requests independent.
private final class LibraryRequestGate: Sendable {
    private struct State {
        var entered = false, released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    private let entered = TestEvent()
    private let pathSuffix: String
    init(pathSuffix: String) { self.pathSuffix = pathSuffix }
    func pause(_ url: URL) async {
        guard url.path.hasSuffix(pathSuffix) else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock {
                guard !$0.entered, !$0.released else { return true }
                $0.continuation = continuation; $0.entered = true
                return false
            }
            if shouldResume { continuation.resume() }
            else { entered.signal() }
        }
    }
    func waitUntilEntered() async throws { try await entered.wait() }
    func release() {
        let continuation = state.withLock {
            $0.released = true
            let continuation = $0.continuation; $0.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
private struct LibraryGatedHTTP: HTTPClient {
    let cdn: MockCDN
    let gate: LibraryRequestGate
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        let response = try await cdn.get(url, byteRangeFrom: offset)
        await gate.pause(url)
        return response
    }
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

/// Pause exactly between a completed cache temporary and its atomic rename.
private final class BranchWriteGate: FileOps {
    private let flags = Mutex((paused: false, released: false))
    private let paused = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let released = NSCondition()
    private let failingSuffix: String?
    init(failingSuffix: String? = nil) { self.failingSuffix = failingSuffix }
    func release() {
        released.lock(); defer { released.unlock() }
        flags.withLock { $0.released = true }; released.broadcast()
    }
    func waitUntilPaused() async throws { for await _ in paused.stream { return } }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if let failingSuffix {
            if destination.hasSuffix(failingSuffix), !flags.withLock({ $0.released }) {
                throw LauncherError.io("https://example.invalid/private?secret=selector")
            }
        } else if destination == "branch.json" {
            // The store's Dispatch executor models a slow synchronous cache
            // rename without starving the task that must resume this writer.
            released.lock(); defer { released.unlock() }
            flags.withLock { $0.paused = true }; paused.continuation.yield(())
            let deadline = Date().addingTimeInterval(60)
            while !flags.withLock({ $0.released }) {
                guard released.wait(until: deadline) else { throw LauncherError.io("branch write release deadline") }
            }
        }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

private struct LibraryPurgeable: PurgeableSpaceProbe {
    let bytes: Int64?
    func importantUsageBytes(at url: URL) -> Int64? { bytes }
}

private final class LibraryOperationGuard: GameOperationGuard, Sendable {
    let blocked: String
    let calls = Mutex<[String]>([])
    init(blocked: String) { self.blocked = blocked }
    func willOperate(on game: String) async throws {
        calls.withLock { $0.append(game) }
        if game == blocked { throw LauncherError.busy("guard denied operation") }
    }
}

private func libraryStateFiles(at root: URL) throws -> [String: Data] {
    let fs = try ContainedFileSystem(root: root)
    var result: [String: Data] = [:]
    func visit(_ paths: [SafeRelativePath]) throws {
        for path in paths {
            switch try fs.itemType(at: path) {
            case .directory: try visit(fs.contentsOfDirectory(at: path))
            case .regularFile: result[path.description] = try fs.readFile(at: path, maxBytes: 2 << 20)
            default: break
            }
        }
    }
    try visit(fs.contentsOfRootDirectory())
    return result
}

private actor SessionClaimingLibraryGuard: GameOperationGuard {
    let paths: AppPaths
    var lock: InstallLock?
    init(paths: AppPaths) { self.paths = paths }
    func willOperate(on game: String) async throws {
        let paths = paths
        lock = try await BlockingIO.run {
            try InstallLock(fs: ContainedFileSystem(root: paths.games), path: SafeRelativePath("\(game)/.session.lock"))
        }
    }
}

private func expectOnlyRetainedSessionLock(_ fixture: borrowing LibraryFixture) async throws {
    #expect(try await fixture.store.gameDirectories() == [game.id])
    let fs = try ContainedFileSystem(root: fixture.paths.games)
    let retained = try SafeRelativePath("\(game.id)/.session.lock")
    #expect(try fs.contentsOfDirectory(at: SafeRelativePath(game.id)) == [retained])
    #expect(try fs.itemType(at: retained) == .regularFile)
}
