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

@Suite(.serialized, .timeLimit(.minutes(1))) struct GameMoverTests {
    @Test(arguments: [MoveSyncBoundary.sourceParent, .destinationParent], [MoveDurabilityTrigger.rollbackRename, .forwardRename])
    func retriedSameVolumeRollbackSyncsBothParentsBeforeRetiringJournal(boundary: MoveSyncBoundary, trigger: MoveDurabilityTrigger) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveDurabilityOps(fixture: f, trigger: trigger, boundary: boundary)
        let store = GameRecordStore(directory: f.paths.games, fileOps: ops)
        let mover = GameMover(paths: f.paths, store: store, disk: MoveDisk(), fileOps: ops,
            checkpoint: { if trigger == .rollbackRename && $0 == .published { throw LauncherError.cancelled } })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(ops.didTrigger)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        #expect(!FileManager.default.fileExists(atPath: f.final.path))
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) != nil)
        await #expect(throws: (any Error).self) { try await mover.recover(f.game.id) }
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) != nil)
        ops.allowSyncs()
        try await mover.recover(f.game.id)
        let events = ops.events
        let retired = try #require(events.firstIndex(of: "retire"))
        #expect(try #require(events.firstIndex(of: "sync:sourceParent")) < retired)
        #expect(try #require(events.firstIndex(of: "sync:destinationParent")) < retired)
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
    }

    @Test(arguments: [MoveDurabilityTrigger.stagingRemoved, .sourceRemoved])
    func missingCleanupTreeStillRequiresParentSyncBeforeJournalRetirement(trigger: MoveDurabilityTrigger) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let rollback = trigger == .stagingRemoved
        let boundary: MoveSyncBoundary = rollback ? .destinationParent : .sourceParent
        let ops = MoveDurabilityOps(fixture: f, trigger: trigger, boundary: boundary)
        let store = GameRecordStore(directory: f.paths.games, fileOps: ops)
        let mover = GameMover(paths: f.paths, store: store, disk: MoveDisk(), fileOps: ops,
            sameVolume: { _, _ in false }, checkpoint: { if rollback && $0 == .verified { throw LauncherError.cancelled } })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(ops.didTrigger)
        #expect(!FileManager.default.fileExists(atPath: rollback ? f.staging.path : f.source.path))
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) != nil)
        await #expect(throws: (any Error).self) { try await mover.recover(f.game.id) }
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) != nil)
        ops.allowSyncs()
        try await mover.recover(f.game.id)
        let events = ops.events, retired = try #require(events.firstIndex(of: "retire"))
        #expect(try #require(events.firstIndex(of: "sync:sourceParent")) < retired)
        #expect(try #require(events.firstIndex(of: "sync:destinationParent")) < retired)
        #expect(try await f.store.load(f.game.id)?.installPath == (rollback ? f.source : f.final))
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
    }

    @Test func retryOfUncertainJournalRemovalSyncsEvenWhenJournalIsAbsent() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveDurabilityOps(fixture: f, trigger: .journalRemoved, boundary: .recordParent)
        let store = GameRecordStore(directory: f.paths.games, fileOps: ops)
        let mover = GameMover(paths: f.paths, store: store, disk: MoveDisk(), fileOps: ops)
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(ops.didTrigger)
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
        await #expect(throws: (any Error).self) { try await mover.recover(f.game.id) }
        ops.allowSyncs()
        try await mover.recover(f.game.id)
        #expect(ops.events.contains("sync:recordParent"))
        #expect(try await f.store.load(f.game.id)?.installPath == f.final)
    }

    @Test func uncertainRecordSwitchIsDurableBeforeOldCopyRemoval() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveDurabilityOps(fixture: f, trigger: .recordRenamed, boundary: nil)
        let store = GameRecordStore(directory: f.paths.games, fileOps: ops)
        let mover = GameMover(paths: f.paths, store: store, disk: MoveDisk(), fileOps: ops, sameVolume: { _, _ in false })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        let events = ops.events
        let removed = try #require(events.firstIndex(of: "removeSource"))
        #expect(try #require(events.firstIndex(of: "sync:recordParent")) < removed)
        #expect(try await f.store.load(f.game.id)?.installPath == f.final)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test(arguments: [false, true])
    func ejectDuringCopyRollsBackAfterReconnectAndAllowsFreshMove(sourceEjected: Bool) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let original = try #require(await f.store.load(f.game.id))
        try Data("second file".utf8).write(to: f.source.appendingPathComponent("second.bin"))
        let probe = MoveDriveProbe(), ejected = sourceEjected ? f.source : f.final
        let mover = GameMover(paths: f.paths, store: f.store, disk: MoveDisk(), locationProbe: probe,
            sameVolume: { _, _ in false })
        await #expect(throws: LauncherError.installVolumeUnavailable) {
            try await mover.move(f.game, to: f.destination) { event in
                if case .progress(_, _, let copied, _) = event, copied > 0 {
                    probe.unavailable.withLock { $0 = ejected }
                }
            }
        }
        #expect(try await f.store.load(f.game.id) == original)
        #expect(FileManager.default.fileExists(atPath: f.staging.path))
        probe.unavailable.withLock { $0 = nil }
        let cdn = MockCDN(), fetcher = ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: ContinuousSleeper())
        let library = GameLibrary(paths: f.paths, api: DeliveryAPI(http: cdn),
            runner: OperationRunner(store: f.store, fetcher: fetcher, disk: MoveDisk(), log: nil),
            store: f.store, disk: MoveDisk(), log: nil, locationProbe: probe)
        #expect(await library.recoverPendingMoves() == [f.game.id])
        #expect(try await f.store.load(f.game.id) == original)
        #expect(try await library.locationStatus(f.game) == .installed(tag: "1.0"))
        #expect(try await f.store.loadPlan(for: f.game.id) == nil)
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
        #expect(!FileManager.default.fileExists(atPath: f.final.path))
        #expect(try Data(contentsOf: f.source.appendingPathComponent("second.bin")) == Data("second file".utf8))
        try await f.mover(crossVolume: true).move(f.game, to: f.destination)
        #expect(try await f.store.load(f.game.id)?.installPath == f.final)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(cdn.requestLog.isEmpty)
    }

    @Test func libraryMoveStreamPreservesPhaseOrder() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let cdn = MockCDN(), fetcher = ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: ContinuousSleeper())
        let library = GameLibrary(paths: f.paths, api: DeliveryAPI(http: cdn),
            runner: OperationRunner(store: f.store, fetcher: fetcher, disk: MoveDisk(), log: nil),
            store: f.store, disk: MoveDisk(), log: nil)
        var phases: [OperationPhase] = []
        for try await event in await library.move(f.game, to: f.destination) {
            if case .phase(let phase) = event { phases.append(phase) }
        }
        #expect(phases == [.verifying, .committing, .completed])
        #expect(cdn.requestLog.isEmpty)
    }

    @Test func deferredRecoveryRetriesAfterVolumesBecomeAvailable() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let probe = MoveLocationProbe()
        let mover = GameMover(paths: f.paths, store: f.store, disk: MoveDisk(), locationProbe: probe,
            sameVolume: { _, _ in false }, checkpoint: { if $0 == .verified { probe.available.withLock { $0 = false } } })
        await #expect(throws: LauncherError.installVolumeUnavailable) { try await mover.move(f.game, to: f.destination) }
        let cdn = MockCDN(), fetcher = ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: ContinuousSleeper())
        let library = GameLibrary(paths: f.paths, api: DeliveryAPI(http: cdn),
            runner: OperationRunner(store: f.store, fetcher: fetcher, disk: MoveDisk(), log: nil),
            store: f.store, disk: MoveDisk(), log: nil, locationProbe: probe)
        await library.start() // Startup occurs while destination is still absent.
        probe.available.withLock { $0 = true }
        #expect(await library.recoverPendingMoves() == [f.game.id])
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
        try LaunchMutationBarrier.requireNoMove(paths: f.paths, game: f.game.id)
    }

    @Test func missingDestinationVolumeRetainsJournalUntilRemount() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let probe = MoveLocationProbe()
        let mover = GameMover(paths: f.paths, store: f.store, disk: MoveDisk(), locationProbe: probe,
            sameVolume: { _, _ in false }, checkpoint: { point in
                if point == .verified { probe.available.withLock { $0 = false } }
            })
        await #expect(throws: LauncherError.installVolumeUnavailable) { try await mover.move(f.game, to: f.destination) }
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) != nil)
        probe.available.withLock { $0 = true }
        try await f.mover(crossVolume: true).recover(f.game.id)
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
    }

    @Test func refusedSpaceAndExistingSessionNeverStartCopy() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let mover = GameMover(paths: f.paths, store: f.store, disk: EmptyMoveDisk(), sameVolume: { _, _ in false })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
        let fs = try ContainedFileSystem(root: f.paths.root)
        let lock = try InstallLock(fs: fs, path: SafeRelativePath("Games/\(f.game.id)/.session.lock"))
        await #expect(throws: (any Error).self) { try await f.mover(crossVolume: false).move(f.game, to: f.destination) }
        withExtendedLifetime(lock) {}
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
    }

    @Test(arguments: [false, true]) func readonlyDirectoriesArePreservedOrRemovedOnlyWhenOwned(cancel: Bool) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let directory = f.source.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: directory.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let mover = f.mover(crossVolume: true, checkpoint: { if cancel && $0 == .verified { throw LauncherError.cancelled } })
        if cancel {
            await #expect(throws: LauncherError.cancelled) { try await mover.move(f.game, to: f.destination) }
            #expect(!FileManager.default.fileExists(atPath: f.staging.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect(attributes[.posixPermissions] as? Int == 0o555)
            // Restore only the test source so TempDir can retire the fixture.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        } else {
            try await mover.move(f.game, to: f.destination)
            #expect(!FileManager.default.fileExists(atPath: f.source.path))
            let target = f.final.appendingPathComponent("readonly")
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            #expect(attributes[.posixPermissions] as? Int == 0o555)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
    }

    @Test func readonlyFilesRetainPermissionsAfterCopy() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.source.appendingPathComponent("game.bin").path)
        try await f.mover(crossVolume: true).move(f.game, to: f.destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.final.appendingPathComponent("game.bin").path)
        #expect(attributes[.posixPermissions] as? Int == 0o444)
    }

    @Test func copiedContentMismatchRollsBackWithoutChangingSource() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let mover = GameMover(paths: f.paths, store: f.store, disk: MoveDisk(), fileOps: CorruptMoveCopy(),
            sameVolume: { _, _ in false })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(try Data(contentsOf: f.source.appendingPathComponent("game.bin")) == Data("game bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.final.path))
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
    }

    @Test func sameVolumePerformsExactlyOneExclusiveFolderRename() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveRenameObserver()
        try await GameMover(paths: f.paths, store: f.store, disk: EmptyMoveDisk(), fileOps: ops).move(f.game, to: f.destination)
        #expect(ops.renames.withLock { $0 } == [true])
        #expect(try await f.store.load(f.game.id)?.installPath == f.final)
    }

    @Test func interruptedStagingIdentityWriteRemovesOnlyTheEmptyClaim() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveStagingJournalFault()
        let mover = GameMover(paths: f.paths, store: GameRecordStore(directory: f.paths.games, fileOps: ops),
            disk: MoveDisk(), sameVolume: { _, _ in false })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
    }

    @Test func uncertainRecordWriteUsesDurableAuthorityBeforeCleanup() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let ops = MoveRecordFault()
        let mover = GameMover(paths: f.paths, store: GameRecordStore(directory: f.paths.games, fileOps: ops), disk: MoveDisk(),
            sameVolume: { _, _ in false }, checkpoint: { if $0 == .published { ops.armed.withLock { $0 = true } } })
        await #expect(throws: (any Error).self) { try await mover.move(f.game, to: f.destination) }
        #expect(try await f.store.load(f.game.id)?.installPath == f.final)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: f.final.appendingPathComponent("game.bin")) == Data("game bytes".utf8))
    }

    @Test(arguments: [false, true]) func predownloadRemainsLoadableAndResumable(crossVolume: Bool) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let source = try ContainedFileSystem(root: f.source), cache = try PreDownloadStore(fs: source)
        let plan = try cachePlan(fs: source), object = try #require(plan.containers.values.first).object
        var saved = try cache.replace(plan)
        try source.writeAtomically(Data("cache".utf8), to: cache.part(object))
        saved.verified = [object.id]
        try cache.save(saved)
        try await f.mover(crossVolume: crossVolume).move(f.game, to: f.destination)
        let target = try ContainedFileSystem(root: f.final), movedCache = try PreDownloadStore(fs: target)
        let state = try #require(try movedCache.load())
        #expect(state.plan.installation == (try target.rootIdentity()))
        #expect(state.verified == saved.verified && !state.completed)
        #expect(state.plan.containers == saved.plan.containers)
        #expect(try target.readFile(at: movedCache.part(object), maxBytes: 10) == Data("cache".utf8))
        // Resume uses the same saved descriptor and retains verified parts.
        let resumed = try movedCache.replace(state.plan)
        #expect(resumed.verified == state.verified)
        let cdn = MockCDN(), fetcher = ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: ContinuousSleeper())
        let library = GameLibrary(paths: f.paths, api: DeliveryAPI(http: cdn),
            runner: OperationRunner(store: f.store, fetcher: fetcher, disk: MoveDisk(), log: nil),
            store: f.store, disk: MoveDisk(), log: nil)
        var completed = false
        for try await event in await library.resumePreDownload(f.game) {
            if event == .phase(.completed) { completed = true }
        }
        #expect(completed)
        #expect(cdn.requestLog.isEmpty)
        #expect(try movedCache.load()?.completed == true)
    }

    @Test func preservesFileAndDirectoryAttributesAndCopiesHardlinksIndependently() async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let file = f.source.appendingPathComponent("game.bin"), directory = f.source.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: file, to: f.source.appendingPathComponent("hard.bin"))
        try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("relative").path, withDestinationPath: "game.bin")
        let date = Date(timeIntervalSince1970: 1234567890)
        for item in [file, directory, f.source] {
            try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o751], ofItemAtPath: item.path)
            #expect(setxattr(item.path, "user.move-test", "value", 5, 0, 0) == 0)
        }
        try await f.mover(crossVolume: true).move(f.game, to: f.destination)
        for item in [f.final.appendingPathComponent("game.bin"), f.final.appendingPathComponent("data"), f.final] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            #expect(attributes[.posixPermissions] as? Int == 0o751)
            #expect(attributes[.modificationDate] as? Date == date)
            var value = [UInt8](repeating: 0, count: 5)
            #expect(getxattr(item.path, "user.move-test", &value, 5, 0, 0) == 5)
            #expect(value == Array("value".utf8))
        }
        let fs = try ContainedFileSystem(root: f.final)
        #expect(try fs.regularFileIdentity(at: SafeRelativePath("game.bin")) != fs.regularFileIdentity(at: SafeRelativePath("hard.bin")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.final.appendingPathComponent("relative").path) == "game.bin")
    }

    @Test(arguments: [false, true], GameMoveCheckpoint.allCases)
    func processDeathRecoversOneAuthoritativeCopy(crossVolume: Bool, point: GameMoveCheckpoint) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let harness = Bundle(for: MoveBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        let result = try await SystemProcessRunner().run(harness,
            arguments: ["move-game", temp.url.path, point.rawValue, crossVolume ? "cross" : "same"],
            environment: [:], currentDirectory: nil, timeout: .seconds(20), timeoutWait: { try await Task.sleep(for: $0) })
        #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
        let cdn = MockCDN(), fetcher = ChunkFetcher(http: cdn, retry: RetryPolicy(), sleeper: ContinuousSleeper())
        let library = GameLibrary(paths: f.paths, api: DeliveryAPI(http: cdn),
            runner: OperationRunner(store: f.store, fetcher: fetcher, disk: MoveDisk(), log: nil),
            store: f.store, disk: MoveDisk(), log: nil)
        await library.start()
        #expect(cdn.requestLog.isEmpty)
        let switched = [.switched, .cleaned].contains(point)
        #expect(try await f.store.load(f.game.id)?.installPath == (switched ? f.final : f.source))
        #expect(FileManager.default.fileExists(atPath: f.source.path) != switched)
        #expect(FileManager.default.fileExists(atPath: f.final.path) == switched)
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
    }

    @Test(arguments: [false, true]) func movesWithoutChangingOwnershipOrBuild(crossVolume: Bool) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let original = try #require(await f.store.load(f.game.id))
        try await f.mover(crossVolume: crossVolume).move(f.game, to: f.destination)
        let result = try #require(await f.store.load(f.game.id))
        #expect(result.installPath == f.final)
        #expect(result.ownership == original.ownership && result.installed == original.installed)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: f.final.appendingPathComponent("game.bin")) == Data("game bytes".utf8))
        #expect(crossVolume ? result.installIdentity != original.installIdentity : result.installIdentity == original.installIdentity)
        #expect(try await f.store.readState("move-journal.json", for: f.game.id, maxBytes: 65536) == nil)
    }

    @Test(arguments: ["exists", "nested", "escape", "chain", "recovery", "notice", "plan", "launch"])
    func refusesUnsafeOrBusyMoves(reason: String) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        var destination = f.destination
        switch reason {
        case "exists": try FileManager.default.createDirectory(at: f.final, withIntermediateDirectories: true)
        case "nested": destination = f.source
        case "escape": try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("bad").path, withDestinationPath: "../outside")
        case "chain":
            try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("root").path, withDestinationPath: ".")
            try FileManager.default.createSymbolicLink(atPath: f.source.appendingPathComponent("bad").path, withDestinationPath: "root/..")
        case "recovery": try FileManager.default.createDirectory(at: f.source.deletingLastPathComponent().appendingPathComponent(".macgacha-recovery/\(f.game.id)"), withIntermediateDirectories: true)
        case "notice":
            let fs = try ContainedFileSystem(root: f.paths.root)
            try fs.writeAtomically(Data("[{}]".utf8), to: SafeRelativePath("RecoveryNotices/\(f.game.id).json"))
        case "plan": try await f.store.writeState(Data("{}".utf8), named: "pending-plan.json", for: f.game.id)
        default: try await f.store.writeState(Data("{}".utf8), named: "launch-session.json", for: f.game.id)
        }
        let target = destination
        await #expect(throws: (any Error).self) { try await f.mover(crossVolume: true).move(f.game, to: target) }
        #expect(try await f.store.load(f.game.id)?.installPath == f.source)
        #expect(try Data(contentsOf: f.source.appendingPathComponent("game.bin")) == Data("game bytes".utf8))
    }

    @Test(arguments: [GameMoveCheckpoint.planned, .copying, .verified, .published, .switched, .cleaned])
    func cancellationBeforeSwitchRollsBackAndAfterSwitchFinishes(point: GameMoveCheckpoint) async throws {
        let temp = try TempDir(), f = try MoveFixture(root: temp.url)
        try await f.save()
        let entered = TestEvent(), release = TestEvent()
        let mover = f.mover(crossVolume: true, checkpoint: { checkpoint in
            if checkpoint == point { entered.signal(); try await release.wait() }
        })
        let task = Task { try await mover.move(f.game, to: f.destination) }
        try await entered.wait(); task.cancel(); release.signal()
        _ = try? await task.value
        let switched = [.switched, .cleaned].contains(point)
        #expect(try await f.store.load(f.game.id)?.installPath == (switched ? f.final : f.source))
        #expect(FileManager.default.fileExists(atPath: f.source.path) != switched)
        #expect(FileManager.default.fileExists(atPath: f.final.path) == switched)
        #expect(!FileManager.default.fileExists(atPath: f.staging.path))
    }
}

private struct MoveFixture: Sendable {
    let root: URL, source: URL, destination: URL, paths: AppPaths, store: GameRecordStore
    let game = GameDefinition.all[0]
    var final: URL { destination.appendingPathComponent(game.defaultInstallDirectoryName) }
    var staging: URL { destination.appendingPathComponent(".macgacha-moving-\(game.id)") }
    init(root: URL) throws {
        self.root = root; paths = AppPaths(root: root.appendingPathComponent("app"))
        source = root.appendingPathComponent("old/Game"); destination = root.appendingPathComponent("new")
        store = GameRecordStore(directory: paths.games)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("game bytes".utf8).write(to: source.appendingPathComponent("game.bin"))
    }
    func save() async throws {
        let identity = try ContainedFileSystem(root: source).rootIdentity()
        try await store.save(GameRecord(installPath: source, ownership: .adopted, executable: SafeRelativePath("game.bin"),
            installed: InstalledBuild(tag: "1.0", buildID: "build", categories: [], voices: []), installIdentity: identity), for: game.id)
    }
    func mover(crossVolume: Bool, checkpoint: @escaping @Sendable (GameMoveCheckpoint) async throws -> Void = { _ in }) -> GameMover {
        GameMover(paths: paths, store: store, disk: MoveDisk(), sameVolume: { _, _ in !crossVolume }, checkpoint: checkpoint)
    }
}
private struct MoveDisk: DiskSpaceProbe { func availableBytes(at url: URL) throws -> Int64 { .max } }

private final class MoveBundleToken: NSObject {}

private final class MoveLocationProbe: GameLocationProbing {
    let available = Mutex(true)
    func requireAvailable(at root: URL) throws {
        if !available.withLock({ $0 }) { throw LauncherError.installVolumeUnavailable }
    }
}
private struct EmptyMoveDisk: DiskSpaceProbe { func availableBytes(at url: URL) throws -> Int64 { 0 } }
private final class MoveRecordFault: FileOps {
    let armed = Mutex(false)
    let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: destination, in: dst, exclusive: exclusive)
        if destination == "record.json", armed.withLock({ value in let result = value; value = false; return result }) {
            throw LauncherError.io("Injected uncertain record write")
        }
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private final class MoveStagingJournalFault: FileOps {
    let writes = Mutex(0)
    let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        if destination == "move-journal.json", writes.withLock({ $0 += 1; return $0 }) == 3 {
            throw LauncherError.io("Injected staging identity write failure")
        }
        try base.rename(from: source, in: src, to: destination, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private final class CorruptMoveCopy: FileOps {
    let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(fd, F_GETPATH, &path) == 0 {
            let text = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if text.contains(".macgacha-moving-"), text.hasSuffix("/game.bin") {
                var byte: UInt8 = 0x42
                #expect(pwrite(fd, &byte, 1, 0) == 1)
            }
        }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: destination, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}
private final class MoveRenameObserver: FileOps {
    let base = SystemFileOps()
    let renames = Mutex<[Bool]>([])
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        if source == "Game" { renames.withLock { $0.append(exclusive) } }
        try base.rename(from: source, in: src, to: destination, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private final class MoveDriveProbe: GameLocationProbing {
    let unavailable = Mutex<URL?>(nil)
    func requireAvailable(at root: URL) throws {
        if unavailable.withLock({ $0?.standardizedFileURL.path == root.standardizedFileURL.path }) {
            throw LauncherError.installVolumeUnavailable
        }
    }
}

enum MoveSyncBoundary: String, Sendable { case sourceParent, destinationParent, recordParent }
enum MoveDurabilityTrigger: Sendable { case rollbackRename, forwardRename, stagingRemoved, sourceRemoved, journalRemoved, recordRenamed }
private final class MoveDurabilityOps: FileOps {
    private struct State {
        var triggered = false
        var failing = true
        var events: [String] = []
    }
    private let state = Mutex(State())
    private let trigger: MoveDurabilityTrigger
    private let boundary: MoveSyncBoundary?
    private let directories: [String: MoveSyncBoundary]
    private let gameName: String
    private let base = SystemFileOps()

    init(fixture: MoveFixture, trigger: MoveDurabilityTrigger, boundary: MoveSyncBoundary?) {
        self.trigger = trigger; self.boundary = boundary
        gameName = fixture.game.defaultInstallDirectoryName
        directories = [
            fixture.source.deletingLastPathComponent().resolvingSymlinksInPath().path: .sourceParent,
            fixture.destination.resolvingSymlinksInPath().path: .destinationParent,
            fixture.paths.games.appendingPathComponent(fixture.game.id).resolvingSymlinksInPath().path: .recordParent
        ]
    }
    var didTrigger: Bool { state.withLock { $0.triggered } }
    var events: [String] { state.withLock { $0.events } }
    func allowSyncs() { state.withLock { $0.failing = false; $0.events = [] } }
    private func directoryKind(_ fd: Int32) throws -> MoveSyncBoundary? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { throw LauncherError.io("Missing move test descriptor") }
        let path = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return directories[URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
    }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        let kind = try directoryKind(fd)
        let fail = state.withLock { state in
            guard state.triggered else { return false }
            if let kind { state.events.append("sync:" + kind.rawValue) }
            return state.failing && kind != nil && kind == boundary
        }
        if fail { throw LauncherError.io("Injected move directory synchronization failure") }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: destination, in: dst, exclusive: exclusive)
        if trigger == .forwardRename && source == "Game" && destination == gameName {
            state.withLock { $0.triggered = true }
        }
        if trigger == .rollbackRename && source == gameName && destination == "Game" {
            state.withLock { $0.triggered = true }
        }
        if trigger == .recordRenamed && destination == "record.json" {
            state.withLock { $0.triggered = true }
            throw LauncherError.io("Injected failure after record rename")
        }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        let kind = try directoryKind(directory)
        try base.unlink(name, in: directory, isDirectory: isDirectory)
        state.withLock { state in
            if trigger == .stagingRemoved && name.hasPrefix(".macgacha-moving-") && isDirectory { state.triggered = true }
            if name == "Game", isDirectory, kind == .sourceParent {
                if trigger == .sourceRemoved { state.triggered = true }
                if state.triggered { state.events.append("removeSource") }
            }
            if name == "move-journal.json" {
                if trigger == .journalRemoved { state.triggered = true }
                if state.triggered { state.events.append("retire") }
            }
        }
    }
}
