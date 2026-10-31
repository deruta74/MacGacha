// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Synchronization
import Testing
@testable import LauncherCore
import DownloadEngine
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct LaunchManagerTests {
    @Test(arguments: [StarRailFrameRateOutcome.missing, .unreadable, .applied, .unchanged])
    func missingStarRailValueLaunchesAndPostsNote(outcome: StarRailFrameRateOutcome) async throws {
        let f = try await ManagerFixture.make()
        f.preparation.report(PreparationOutcome(starRailFrameRate: outcome))
        try await BlockingIO.run {
            var settings = LaunchSettings.defaults(for: "starrail"); settings.unlockFPS = true
            try LaunchSettingsStore(paths: f.paths).save(settings, for: "starrail")
        }
        let manager = f.manager(), events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        #expect(f.spawner.calls.count == 1)
        let notes: [LaunchNote] = await events.values.compactMap { if case .note(let note) = $0 { note } else { nil } }
        #expect(notes == (outcome == .missing || outcome == .unreadable ? [.starRailSettingsMissing] : []))
        #expect(try await f.journal() != nil)
        try await f.end(manager); await consumer.value
    }
    @Test func resolvesDisplayOrderAgainBeforeSpawn() async throws {
        let f = try await ManagerFixture.make()
        let main = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000001", name: "Main", isMain: true)
        let second = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000002", name: "Private screen name", isMain: false)
        let probe = ManagerDisplayProbe([[main, second], [
            ConnectedDisplay(id: second.id, name: second.name, isMain: true),
            ConnectedDisplay(id: main.id, name: main.name, isMain: false)]])
        try await BlockingIO.run {
            var settings = LaunchSettings.defaults(for: "starrail")
            settings.display = DisplayChoice(id: second.id, name: second.name)
            try LaunchSettingsStore(paths: f.paths).save(settings, for: "starrail")
        }
        let manager = f.manager(displayProbe: probe), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        #expect(probe.calls == 2)
        #expect(f.spawner.calls.first?.arguments == [WinePath.windowsPath(for: f.paths.runtimes.appendingPathComponent("jadeite/jadeite.exe")),
            WinePath.windowsPath(for: f.installRoot.appendingPathComponent("StarRail.exe")), "--", "-monitor", "1"])
        try await f.end(manager); await consumer.value
    }

    @Test func reattachmentNeverQueriesDisplayOrder() async throws {
        let f = try await ManagerFixture.make(), probe = ManagerDisplayProbe([])
        _ = try await f.saveSnapshot(state: .running, processes: [f.gameProcess.identity])
        let manager = f.manager(displayProbe: probe)
        _ = await manager.reattachAll()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(probe.calls == 0)
        try await f.end(manager); await f.waitForRestore(manager)
        #expect(probe.calls == 0)
    }

    @Test func happyPathStagesInOrder() async throws {
        let f = try await ManagerFixture.make()
        let manager = f.manager()
        let events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        await manager.markReady(game: "starrail")
        await events.waitForReady()
        try await f.end(manager)
        await consumer.value
        let result = await events.values
        let stages: [LaunchStage] = result.compactMap { if case .stage(let stage) = $0 { stage } else { nil } }
        #expect(Array(stages.prefix(6)) == [.preflight, .lock, .snapshot, .prepare, .proxy, .spawn])
        #expect(result.contains { if case .ended(normal: true) = $0 { true } else { false } })
        #expect(result.contains { if case .restored(.clean) = $0 { true } else { false } })
        #expect(f.proxy.stops == 1)
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }
    @Test func freshLaunchPersistsOnlySpawnedGroupAndScopesEveryScan() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(try await f.journal()?.processGroupIDs == [f.spawner.identity.pid])
        #expect(try await f.journal()?.processes.contains(f.spawner.identity) == true)
        #expect(try await f.journal()?.bootSessionUUID == ManagerFixture.bootSessionUUID)
        #expect(try await f.journal()?.sessionStartTime == ManagerFixture.sessionStartTime)
        let scans = f.inspector.values.scopes
        #expect(!scans.isEmpty)
        #expect(scans.allSatisfy { $0.bootSessionUUID == ManagerFixture.bootSessionUUID && $0.sessionStartTime == ManagerFixture.sessionStartTime })
        #expect(scans.allSatisfy { $0.identities.contains(f.spawner.identity) })
        #expect(scans.allSatisfy { $0.executableRoots == [f.paths.runtimes, f.installRoot]
            && $0.processGroupIDs == [f.spawner.identity.pid] })
        #expect(f.gameProcess.identity.pid != f.spawner.identity.pid)
        try await f.end(manager); await consumer.value
    }

    @Test func partialHideAndFailedRecoveryReadsNeverEraseDurableEntries() async throws {
        let f = try await ManagerFixture.make(initialGame: false), reads = ManagerReadFailures()
        let manager = f.manager(hideHooks: LaunchFileHooks(at: .afterHideRename) {
            reads.arm(4)
        }, beforeJournalRead: { try reads.read() })
        let events = ManagerEvents(), consumer = await f.consume(manager, events: events)
        await consumer.value
        let snapshot = try #require(try await f.journal())
        #expect(snapshot.hides.count == 1)
        #expect(f.spawner.calls.isEmpty)
        try await f.assertHidden(); try await f.assertLocksHeld()
        try await manager.recoverIfNeeded(game: "starrail")
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func reattachRecognizesRewrittenImageWithUnixWineLoader() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .running, processes: [])
        let game = InspectedProcess(identity: ProcessIdentity(pid: 23450, startTime: 200),
            executablePath: "/runtime/lib/wine/x86_64-unix/wine", arguments: [#"C:\Games\StarRail.exe"#])
        f.inspector.update { $0.processes = [game]; $0.alive = [game.identity] }
        let sessions = await manager.reattachAll()
        #expect(sessions["starrail"] != nil)
        try await f.assertHidden()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }

    @Test func reattachedWrapperRetainsSpawningGraceUntilGameAppears() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .spawning, processes: [f.spawner.identity])
        f.inspector.update { $0.alive = [f.spawner.identity] }
        _ = await manager.reattachAll()
        for second in 1...40 {
            await f.clock.waitForSleep(second, duration: .seconds(1))
            #expect(await manager.liveSession(for: "starrail")?.state == .spawning)
            try await f.assertHidden()
            if second == 40 { f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] } }
            f.clock.advance(by: .seconds(1))
        }
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }

    @Test(arguments: ["steam.exe", "jadeite.exe", "absent", "pending"])
    func unrecordedSpawningHelpersRetainStartupGrace(helper: String) async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .spawning, processes: [])
        if helper == "pending" {
            try await BlockingIO.run {
                let journal = LaunchJournal(paths: f.paths)
                var snapshot = try #require(try journal.read(game: "starrail"))
                snapshot.state = .recoveryPending; snapshot.startupPending = true
                try journal.write(snapshot)
            }
        } else if helper != "absent" {
            f.inspector.update { $0.processes = [InspectedProcess(identity: f.spawner.identity,
                executablePath: "/runtime/lib/wine/x86_64-unix/wine", arguments: ["C:\\windows\\system32\\\(helper)"])] }
        }
        _ = await manager.reattachStartup()
        await f.clock.waitForSleep(1, duration: .seconds(1))
        f.clock.advance(by: .seconds(59))
        await f.clock.waitForSleep(2, duration: .seconds(1))
        try await f.assertHidden(); try await f.assertLocksHeld()
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
        f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] }
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }

    @Test(arguments: ["journal", "lock", "pin"])
    func startupRetainsUnresolvedOwnershipAndRetries(fault: String) async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        _ = try await f.saveSnapshot(state: .running, processes: [])
        let unreadable = Mutex(fault == "journal")
        let manager = f.manager(beforeJournalRead: {
            if unreadable.withLock({ $0 }) { throw LauncherError.io("injected journal read failure") }
        })
        var exclusion: InstallLock? = try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.paths.root)
            switch fault {
            case "lock": return try InstallLock(fs: fs, path: SafeRelativePath("Games/starrail/.session.lock"))
            case "pin": return try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-a.lock"))
            default: return nil
            }
        }
        let first = await manager.reattachStartup()
        #expect(first.unresolved.contains("starrail")); #expect(first.sessions.isEmpty)
        try await f.assertHidden()
        await #expect(throws: LauncherError.self) { _ = try await manager.sessionObservation(for: "starrail") }
        unreadable.withLock { $0 = false }
        withExtendedLifetime(exclusion) {}; exclusion = nil
        let retried = await manager.reattachStartup()
        #expect(retried.unresolved.isEmpty); #expect(retried.sessions.isEmpty)
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func reattachIncompleteScanWithoutWrittenIdentityNeverAuthorizesRestore() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .spawning, processes: [])
        f.inspector.update { $0.failure = true }
        let snapshots = await manager.reattachAll()
        #expect(snapshots["starrail"]?.state == .recoveryPending)
        #expect(try await f.journal()?.startupPending == true)
        await f.clock.waitForSleep(1, duration: .seconds(1))
        try await f.assertHidden(); try await f.assertLocksHeld()
        #expect(try await f.journal()?.hides.count == 1)
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(2, duration: .seconds(1))
        try await f.assertHidden()
        f.inspector.update { $0.failure = false; $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] }
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func crashBeforeIdentityWriteWithUnreadableArgumentsAndPathRetainsRecovery() async throws {
        let f = try await ManagerFixture.make(initialGame: false)
        let kernel = ManagerUnclassifiableKernel(prefix: f.prefix.path)
        let manager = f.manager(inspector: SystemProcessInspector(kernel: kernel))
        let snapshot = try await f.saveSnapshot(state: .spawning, processes: [])
        #expect(snapshot.processGroupIDs == nil)
        let sessions = await manager.reattachAll()
        #expect(sessions["starrail"]?.state == .recoveryPending)
        await f.clock.waitForSleep(1, duration: .seconds(1))
        #expect(kernel.failedArguments > 0 && kernel.failedPaths > 0)
        try await f.assertHidden(); try await f.assertLocksHeld()
        #expect(try await f.journal()?.hides.count == 1)
        kernel.set(.readable)
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        kernel.set(.gone)
        f.clock.advance(by: .seconds(3))
        await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func guardCannotRestoreWatcherStartedByIncompleteReattach() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .spawning, processes: [])
        f.inspector.update { $0.failuresRemaining = 1 }
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
        for second in 1...40 {
            await f.clock.waitForSleep(second, duration: .seconds(1))
            await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
            try await f.assertHidden(); try await f.assertLocksHeld()
            if second == 40 { f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] } }
            f.clock.advance(by: .seconds(1))
        }
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }

    @Test(arguments: [false, true]) func recoveryOwnerExcludesConcurrentGuard(reattaching: Bool) async throws {
        let f = try await ManagerFixture.make(), gate = ManagerRecoveryReadGate()
        let manager = f.manager(beforeRecoveryRead: { try await gate.read() })
        _ = try await f.saveSnapshot(state: .running, processes: [f.gameProcess.identity])
        let first = Task {
            if reattaching { _ = await manager.reattachAll() }
            else { await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") } }
        }
        try await gate.entered.wait()
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
        #expect(gate.calls == 1)
        gate.released.signal()
        await first.value
        await f.clock.waitForSleep(1, duration: .seconds(3))
        try await f.assertHidden()
        try await f.end(manager); await f.waitForRestore(manager)
    }

    @Test func delayedWineserverDoesNotEndSpawning() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        for second in 1...40 {
            await f.clock.waitForSleep(second, duration: .seconds(1))
            if second == 40 { f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] } }
            f.clock.advance(by: .seconds(1))
        }
        await events.waitForRunning()
        #expect(try await f.journal()?.state == .running)
        #expect(f.proxy.stops == 0)
        try await f.end(manager); await consumer.value
        try await f.assertOriginalRestored()
    }

    @Test func noGameProcessFor60sIsStartupFailure() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        for second in 1...60 {
            await f.clock.waitForSleep(second, duration: .seconds(1))
            f.clock.advance(by: .seconds(1))
        }
        await consumer.value
        let result = await events.values
        #expect(result.contains { if case .failed(let failure) = $0 { failure.stage == .watch } else { false } })
        #expect(result.contains { if case .restored(.clean) = $0 { true } else { false } })
        try await f.assertOriginalRestored()
        #expect(f.proxy.stops == 1)
    }

    @Test func selfRestartGapKeepsSession() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await f.clock.waitForSleep(1, duration: .seconds(3))
        f.inspector.update { $0.processes = [f.serverProcess]; $0.alive = [f.serverProcess.identity] }
        f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        #expect(try await f.journal()?.state == .running)
        #expect(f.proxy.stops == 0)
        let replacement = InspectedProcess(identity: ProcessIdentity(pid: 23458, startTime: 300), executablePath: "/wine/StarRail.exe", arguments: [])
        f.inspector.update { $0.processes = [replacement, f.serverProcess]; $0.alive = [replacement.identity, f.serverProcess.identity] }
        f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(3, duration: .seconds(3))
        #expect(try await f.journal()?.state == .running)
        f.inspector.update { $0.processes = []; $0.alive = [] }; f.clock.advance(by: .seconds(3))
        await consumer.value
    }

    @Test func lingeringHelperKeepsSessionUntilWineserverExits() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await f.clock.waitForSleep(1, duration: .seconds(3))
        f.inspector.update { $0.processes = [f.serverProcess]; $0.alive = [f.serverProcess.identity] }
        for cycle in 1...3 {
            f.clock.advance(by: .seconds(3))
            await f.clock.waitForSleep(cycle + 1, duration: .seconds(3))
            #expect(try await f.journal()?.state == .running)
            #expect(f.proxy.stops == 0)
        }
        f.inspector.update { $0.processes = []; $0.alive = [] }; f.clock.advance(by: .seconds(3))
        await consumer.value
        #expect(f.proxy.stops == 1)
    }

    @Test func exitBeforeReadyIsStartupFailure() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); try await f.end(manager); await consumer.value
        let result = await events.values
        #expect(result.contains { if case .ended(normal: false) = $0 { true } else { false } })
        #expect(result.contains { if case .failed(let failure) = $0 { failure.stage == .watch } else { false } })
        #expect(!result.contains { if case .ready = $0 { true } else { false } })
    }

    @Test func exitAfterReadyIsNormal() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await manager.markReady(game: "starrail"); await events.waitForReady()
        try await f.end(manager); await consumer.value
        let result = await events.values
        #expect(result.contains { if case .ended(normal: true) = $0 { true } else { false } })
        #expect(!result.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func crashBetweenSpawnAndRunningReattaches() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager()
        let snapshot = try await f.saveSnapshot(state: .spawning, processes: [])
        let sessions = await manager.reattachAll()
        #expect(sessions["starrail"]?.sessionID == snapshot.sessionID)
        #expect(f.proxy.starts == 0)
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(f.inspector.values.scopes.allSatisfy { $0.processGroupIDs.isEmpty
            && $0.executableRoots == [f.paths.runtimes, f.installRoot] })
        try await f.end(manager)
        await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
    }

    @Test func reattachUsesSnapshotNotSettings() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager()
        _ = try await f.saveSnapshot(state: .spawning, processes: [f.gameProcess.identity], backend: .dxmt, processGroupIDs: [54321])
        try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).save(.defaults(for: "starrail"), for: "starrail") }
        let sessions = await manager.reattachAll()
        #expect(sessions["starrail"]?.settings.backend == .dxmt)
        #expect(sessions["starrail"]?.bundleID == "bundle-a")
        #expect(f.inspector.values.prefixes.allSatisfy { $0 == f.prefix.path })
        await f.clock.waitForSleep(1, duration: .seconds(3))
        #expect(sessions["starrail"]?.processGroupIDs == [54321])
        #expect(f.inspector.values.scopes.allSatisfy { $0.identities.contains(f.gameProcess.identity) && $0.bootSessionUUID == ManagerFixture.bootSessionUUID && $0.sessionStartTime == ManagerFixture.sessionStartTime })
        #expect(f.inspector.values.scopes.count >= 2)
        #expect(f.inspector.values.scopes.allSatisfy { $0.executableRoots == [f.paths.runtimes, f.installRoot]
            && $0.processGroupIDs == [54321] })
        try await f.end(manager); await f.waitForRestore(manager)
    }

    @Test func inspectorFailureRetainsProxyAndAutomaticallyRetriesUntilConfirmedEnd() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); await f.clock.waitForSleep(1, duration: .seconds(3))
        f.inspector.update { $0.failure = true }; f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(1, duration: .seconds(1))
        #expect(try await f.journal()?.state == .recoveryPending)
        try await f.assertHidden()
        try await f.assertLocksHeld()
        #expect(f.proxy.stops == 0)
        let uncertain = await events.values
        #expect(!uncertain.contains { if case .failed = $0 { true } else { false } })
        // A second incomplete scan still cannot end a live session.
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(2, duration: .seconds(1))
        #expect(f.proxy.stops == 0)
        f.inspector.update { $0.failure = false; $0.processes = []; $0.alive = [] }
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(3, duration: .seconds(3))
        f.clock.advance(by: .seconds(3))
        await consumer.value
        #expect(f.proxy.stops == 1)
        try await f.assertOriginalRestored()
    }

    @Test func unverifiedBuildFlagged() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        f.spawner.fail()
        let consumer = await f.consume(manager, events: events, build: "unverified-test-build")
        await consumer.value
        let result = await events.values
        let failure = try #require(result.compactMap { if case .failed(let value) = $0 { value } else { nil } }.first)
        #expect(failure.stage == .spawn)
        #expect(failure.unverifiedBuild)
        let log = try #require(failure.logURL)
        await manager.flushLogs()
        let text = try await BlockingIO.run { String(decoding: try Data(contentsOf: log), as: UTF8.self) }
        #expect(text.contains("unverified build"))
        try await f.assertOriginalRestored()
        #expect(f.proxy.stops == 1)
    }

    @Test func secondGameLaunchRefused() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        let other = GameDefinition.all.first { $0.id == "zzz" }!
        var failure: LaunchFailure?
        for await event in await manager.launch(game: other, installRoot: f.installRoot, gameBuild: "test") {
            if case .failed(let value) = event { failure = value }
        }
        #expect(failure?.stage == .lock)
        #expect(failure?.message.contains("Star Rail is running") == true)
        #expect(f.spawner.calls.count == 1)
        try await f.end(manager); await consumer.value
    }

    @Test func cancellingConsumerKeepsSupervisionAndHiddenFileOwnership() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        consumer.cancel(); await consumer.value
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.assertHidden(); try await f.assertLocksHeld()
        #expect(f.proxy.stops == 0)
        try await f.end(manager); await f.waitForRestore(manager)
        try await f.assertOriginalRestored()
        #expect(f.proxy.stops == 1)
    }

    @Test(arguments: [false, true]) func failureRestoresBeforeReportingAndStopsProxy(preparationFails: Bool) async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        if preparationFails { f.preparation.fail() } else { f.spawner.fail() }
        let consumer = await f.consume(manager, events: events); await consumer.value
        let result = await events.values
        let restored = try #require(result.firstIndex { if case .restored(.clean) = $0 { true } else { false } })
        let failed = try #require(result.firstIndex { if case .failed = $0 { true } else { false } })
        #expect(restored < failed)
        #expect(f.proxy.stops == (preparationFails ? 0 : 1))
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func logsOffStillKeepsRecoveryMetadataAndUsesDiscardSpawn() async throws {
        let f = try await ManagerFixture.make(logsEnabled: false), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        #expect(f.spawner.calls.count == 1)
        #expect(f.spawner.calls.first?.outputDiscarded == true)
        #expect(try await f.journal()?.state == .running)
        try await f.assertHidden()
        let logURL = await manager.liveSession(for: "starrail")?.sessionLogURL
        #expect(logURL == nil)
        let logFiles = try await BlockingIO.run { try LaunchLogFiles.latestSessionLogURLs(in: f.paths.logs) }
        #expect(logFiles.isEmpty)
        try await f.end(manager); await consumer.value
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
    }

    @Test func guardRefusesLiveAndRestoresPendingBeforeOperation() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let guardHook = LaunchManagerOperationGuard(manager: manager)
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        await #expect(throws: LauncherError.self) { try await guardHook.willOperate(on: "starrail") }
        try await guardHook.willOperate(on: "zzz")
        await f.clock.waitForSleep(1, duration: .seconds(3)); f.inspector.update { $0.failure = true }; f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(1, duration: .seconds(1))
        await #expect(throws: LauncherError.self) { try await guardHook.willOperate(on: "starrail") }
        f.inspector.update { $0.failure = false; $0.processes = []; $0.alive = [] }
        f.clock.advance(by: .seconds(1))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        f.clock.advance(by: .seconds(3)); await consumer.value
        try await guardHook.willOperate(on: "starrail")
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func missingInstallVolumeKeepsJournalLockAndPinsUntilRestore() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        let detached = f.temp.url.appendingPathComponent("detached-game")
        try await BlockingIO.run { try FileManager.default.moveItem(at: f.installRoot, to: detached) }
        try await f.end(manager); await consumer.value
        #expect(try await f.journal()?.state == .recoveryPending)
        try await f.assertLocksHeld()
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
        let stillMissing = try await BlockingIO.run { !FileManager.default.fileExists(atPath: f.installRoot.path) }
        #expect(stillMissing)
        try await BlockingIO.run { try FileManager.default.moveItem(at: detached, to: f.installRoot) }
        try await manager.recoverIfNeeded(game: "starrail")
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func journalSnapshotFailureDoesNotHideOrSpawn() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        f.journalOps.arm()
        let consumer = await f.consume(manager, events: events); await consumer.value
        let result = await events.values
        #expect(result.contains { if case .failed(let value) = $0 { value.stage == .snapshot } else { false } })
        #expect(f.spawner.calls.isEmpty)
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func failedPostSpawnJournalWriteKeepsLiveProcessSupervised() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        f.spawner.afterSpawn { [ops = f.journalOps] in ops.arm() }
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await f.assertHidden(); try await f.assertLocksHeld()
        let beforeEnd = await events.values
        #expect(!beforeEnd.contains { if case .failed = $0 { true } else { false } })
        #expect(try await f.journal()?.processGroupIDs == [f.spawner.identity.pid])
        #expect(try await f.journal()?.processes.contains(f.spawner.identity) == true)
        #expect(f.inspector.values.scopes.allSatisfy { $0.processGroupIDs == [f.spawner.identity.pid] })
        #expect(f.proxy.stops == 0)
        try await f.end(manager); await consumer.value
        let result = await events.values
        let restored = try #require(result.firstIndex { if case .restored(.clean) = $0 { true } else { false } })
        let failed = try #require(result.firstIndex { if case .failed(let value) = $0 { value.stage == .spawn } else { false } })
        #expect(restored < failed)
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func failedPostSpawnJournalWriteDuringDelayedStartupKeepsGuardBusy() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager(), events = ManagerEvents()
        let guardHook = LaunchManagerOperationGuard(manager: manager)
        f.spawner.afterSpawn { [ops = f.journalOps] in ops.arm() }
        let consumer = await f.consume(manager, events: events)
        await f.clock.waitForSleep(1, duration: .seconds(1))
        #expect(await manager.liveSession(for: "starrail")?.state == .recoveryPending)
        await #expect(throws: LauncherError.self) { try await guardHook.willOperate(on: "starrail") }
        try await f.assertHidden(); try await f.assertLocksHeld()
        #expect(try await f.journal() != nil)
        let duringStartup = await events.values
        #expect(!duringStartup.contains { if case .failed = $0 { true } else { false } })
        #expect(!duringStartup.contains { if case .restored(.clean) = $0 { true } else { false } })
        for second in 1...40 {
            await f.clock.waitForSleep(second, duration: .seconds(1))
            if second == 40 { f.inspector.update { $0.processes = [f.gameProcess]; $0.alive = [f.gameProcess.identity] } }
            f.clock.advance(by: .seconds(1))
        }
        await events.waitForRunning()
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        try await f.end(manager); await consumer.value
        let result = await events.values
        let restored = try #require(result.firstIndex { if case .restored(.clean) = $0 { true } else { false } })
        let failed = try #require(result.firstIndex { if case .failed(let value) = $0 { value.stage == .spawn } else { false } })
        #expect(restored < failed)
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func resolvedConflictReleasesOwnershipAndPreservesRecoveryNoticeAndCopy() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events); await events.waitForRunning()
        let updated = Data("new user game bytes".utf8)
        try await BlockingIO.run { try ContainedFileSystem(root: f.installRoot).writeAtomically(updated, to: f.hiddenPath) }
        try await f.end(manager); await consumer.value
        await manager.waitForSupervision(game: "starrail")
        #expect(try await f.journal() == nil)
        #expect(await manager.liveSession(for: "starrail") == nil)
        let outcomes: [RestoreOutcome] = await events.values.compactMap { if case .restored(let outcome) = $0 { outcome } else { nil } }
        let recoveryURLs = try #require(outcomes.compactMap { if case .conflict(let urls) = $0 { urls } else { nil } }.first)
        #expect(!recoveryURLs.isEmpty)
        try await BlockingIO.run {
            let original = try ContainedFileSystem(root: f.installRoot).readFile(at: f.hiddenPath, maxBytes: 100)
            #expect(original == updated)
            let recovered = try Data(contentsOf: #require(recoveryURLs.first))
            #expect(recovered == f.original)
        }
        let guardHook = LaunchManagerOperationGuard(manager: manager)
        try await guardHook.willOperate(on: "starrail")
        try await guardHook.willOperate(on: "zzz")
        try await BlockingIO.run {
            let lock = try SessionLock.acquire(paths: f.paths, game: "starrail")
            let fs = try ContainedFileSystem(root: f.paths.root)
            for component in f.runtime.selected.componentIDs {
                let pin = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\(component).lock"))
                withExtendedLifetime(pin) {}
            }
            withExtendedLifetime(lock) {}
        }
        let afterRetry = try await BlockingIO.run { try ContainedFileSystem(root: f.installRoot).readFile(at: f.hiddenPath, maxBytes: 100) }
        #expect(afterRetry == updated)
    }

    @Test(arguments: [false, true]) func startupResolvedConflictNoticeSurvivesRestartUntilAcknowledged(external: Bool) async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        let snapshot = try await f.saveSnapshot(state: .running, processes: [])
        let updated = Data("updated original".utf8)
        try await BlockingIO.run {
            try ContainedFileSystem(root: f.installRoot).writeAtomically(updated, to: f.hiddenPath)
            if external {
                let parentURL = f.installRoot.deletingLastPathComponent(), parent = try ContainedFileSystem(root: parentURL)
                let relative = try SafeRelativePath(".macgacha-recovery/starrail/\(snapshot.sessionID)")
                try parent.createDirectoryDurably(at: relative)
                let root = relative.resolved(against: parentURL)
                var current = snapshot
                current.recoveryLocation = LaunchRecoveryLocation(root: root, parentIdentity: try parent.rootIdentity(),
                    identity: try ContainedFileSystem(root: root).rootIdentity())
                try LaunchJournal(paths: f.paths).write(current)
            }
        }
        #expect(await manager.reattachAll().isEmpty)
        #expect(try await f.journal() == nil)
        let notices = try await manager.pendingRecoveryNotices()
        let notice = try #require(notices.first)
        #expect(notices.count == 1)
        #expect(notice.id == snapshot.sessionID)
        #expect(notice.game == "starrail")
        #expect(!notice.movedTo.isEmpty)
        let restarted = f.manager()
        #expect(try await restarted.pendingRecoveryNotices() == notices)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.installRoot)
            #expect(try fs.readFile(at: f.hiddenPath, maxBytes: 100) == updated)
            let recovery = try #require(notice.movedTo.first)
            let root = notice.recoveryRoot ?? f.paths.root
            #expect((notice.recoveryRoot != nil) == external)
            let relative = try SafeRelativePath(String(recovery.path.dropFirst(root.path.count + 1)))
            #expect(try ContainedFileSystem(root: root).readFile(at: relative, maxBytes: 100) == f.original)
        }
        try await restarted.acknowledgeRecoveryNotice(id: notice.id)
        #expect(try await f.manager().pendingRecoveryNotices().isEmpty)
    }

    @Test(arguments: [false, true]) func failedRecoveryNoticePersistenceKeepsResolvedJournalForRetry(corruptList: Bool) async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        let snapshot = try await f.saveSnapshot(state: .running, processes: [])
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.installRoot)
            try fs.writeAtomically(Data("updated".utf8), to: f.hiddenPath)
            let app = try ContainedFileSystem(root: f.paths.root)
            if corruptList {
                try app.createDirectoryDurably(at: SafeRelativePath("RecoveryNotices"))
                try app.writeAtomically(Data("not JSON".utf8), to: SafeRelativePath("RecoveryNotices/starrail.json"))
            } else {
                try app.writeAtomically(Data("not a directory".utf8), to: SafeRelativePath("RecoveryNotices"))
            }
        }
        _ = await manager.reattachAll()
        #expect(try await f.journal()?.sessionID == snapshot.sessionID)
        #expect(await manager.liveSession(for: "starrail")?.state == .recoveryPending)
        try await f.assertLocksHeld()
        try await BlockingIO.run {
            try ContainedFileSystem(root: f.paths.root).removeFile(at:
                SafeRelativePath(corruptList ? "RecoveryNotices/starrail.json" : "RecoveryNotices"))
        }
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(try await f.journal() == nil)
        #expect(try await manager.pendingRecoveryNotices().map(\.id) == [snapshot.sessionID])
    }

    @Test func noticeCannotBeAcknowledgedBeforeResolvedJournalDeletion() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        let snapshot = try await f.saveSnapshot(state: .running, processes: [])
        try await BlockingIO.run {
            try ContainedFileSystem(root: f.installRoot).writeAtomically(Data("updated".utf8), to: f.hiddenPath)
        }
        f.journalOps.armDelete()
        _ = await manager.reattachAll()
        #expect(try await f.journal()?.sessionID == snapshot.sessionID)
        let notices = try await manager.pendingRecoveryNotices()
        #expect(notices.map(\.id) == [snapshot.sessionID])
        await #expect(throws: LauncherError.self) { try await manager.acknowledgeRecoveryNotice(id: snapshot.sessionID) }
        #expect(try await manager.pendingRecoveryNotices() == notices)
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(try await manager.pendingRecoveryNotices() == notices)
        #expect(try await f.journal() == nil)
        try await manager.acknowledgeRecoveryNotice(id: snapshot.sessionID)
        #expect(try await f.manager().pendingRecoveryNotices().isEmpty)
    }

    @Test func observationDoesNotFinalizeAnUnattachedJournal() async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        _ = try await f.saveSnapshot(state: .running, processes: [])
        await #expect(throws: LauncherError.self) { try await manager.sessionObservation(for: "starrail") }
        _ = await manager.reattachAll()
        #expect(try await manager.sessionObservation(for: "starrail") == nil)
    }

    @Test(arguments: [false, true]) func journalDeletionSyncFailureRetriesResolvedFinalization(conflict: Bool) async throws {
        let f = try await ManagerFixture.make(initialGame: false), manager = f.manager()
        let snapshot = try await f.saveSnapshot(state: .running, processes: [])
        if conflict {
            try await BlockingIO.run {
                try ContainedFileSystem(root: f.installRoot).writeAtomically(Data("updated".utf8), to: f.hiddenPath)
            }
        }
        f.journalOps.armDeletionSync()
        _ = await manager.reattachAll()
        // The fault is after unlink, rather than the existing pre-unlink seam.
        #expect(try await f.journal() == nil)
        #expect(f.journalOps.deletionSyncFailures == 1)
        #expect(try await manager.sessionObservation(for: "starrail")?.hasEnded == true)
        #expect(await manager.liveSession(for: "starrail")?.state == .recoveryPending)
        try await f.assertLocksHeld()
        if conflict {
            #expect(try await manager.pendingRecoveryNotices().map(\.id) == [snapshot.sessionID])
            await #expect(throws: LauncherError.self) { try await manager.acknowledgeRecoveryNotice(id: snapshot.sessionID) }
            await #expect(throws: LauncherError.self) { try await f.manager().acknowledgeRecoveryNotice(id: snapshot.sessionID) }
        }
        // Completion is already verified: an unrelated uncertain process scan
        // must not prevent this pure durability retry.
        f.inspector.update { $0.failure = true }
        // A still-failing barrier must be retried despite the now-absent journal.
        await #expect(throws: LauncherError.self) { try await manager.recoverIfNeeded(game: "starrail") }
        #expect(f.journalOps.deletionSyncFailures == 2)
        try await f.assertLocksHeld()
        f.journalOps.allowDeletionSync()
        try await manager.recoverIfNeeded(game: "starrail")
        #expect(f.journalOps.deletionSyncSuccesses >= 1)
        #expect(await manager.liveSession(for: "starrail") == nil)
        try await BlockingIO.run {
            let lock = try SessionLock.acquire(paths: f.paths, game: "starrail")
            let fs = try ContainedFileSystem(root: f.paths.root)
            for component in f.runtime.selected.componentIDs {
                let pin = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\(component).lock"))
                withExtendedLifetime(pin) {}
            }
            withExtendedLifetime(lock) {}
            if conflict {
                let notices = try RecoveryNoticeStore(paths: f.paths).load()
                let recovery = try #require(notices.first?.movedTo.first)
                #expect(try ContainedFileSystem(root: recovery.deletingLastPathComponent()).readFile(at: SafeRelativePath(recovery.lastPathComponent), maxBytes: 1024) == f.original)
            }
        }
        if conflict {
            try await manager.acknowledgeRecoveryNotice(id: snapshot.sessionID)
            #expect(try await manager.pendingRecoveryNotices().isEmpty)
        } else { try await f.assertOriginalRestored() }
    }

    @Test func reattachUsesSnapshotExecutableAndExactOwnedLog() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager()
        let logs = try await BlockingIO.run {
            let old = try SessionLog.create(paths: f.paths, game: "starrail", header: [:],
                now: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: 1024, ticker: ManagerNoopLogTicker())
            let newer = try SessionLog.create(paths: f.paths, game: "starrail", header: [:],
                now: Date(timeIntervalSince1970: 1_700_000_100), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: 1024, ticker: ManagerNoopLogTicker())
            old.finish(); newer.finish()
            let fs = try ContainedFileSystem(root: f.paths.logs)
            for log in [old, newer] {
                let file = try fs.openForWriting(at: SafeRelativePath(log.url.lastPathComponent), truncate: false)
                try file.seekToEnd(); try file.write(contentsOf: Data(repeating: 120, count: 8192)); try file.close()
            }
            return (old: old, newer: newer)
        }
        defer { withExtendedLifetime(logs) {} }
        let customExecutable = try SafeRelativePath("CustomStarRail.exe")
        let custom = InspectedProcess(identity: ProcessIdentity(pid: 24444, startTime: 200), executablePath: "/wine/CustomStarRail.exe", arguments: [])
        f.inspector.update { $0.processes = [custom]; $0.alive = [custom.identity] }
        _ = try await f.saveSnapshot(state: .spawning, processes: [], backend: .dxmt,
            sessionLogURL: logs.old.url, gameExecutable: customExecutable)
        try await BlockingIO.run { try LaunchSettingsStore(paths: f.paths).save(.defaults(for: "starrail"), for: "starrail") }
        let sessions = await manager.reattachAll()
        #expect(sessions["starrail"]?.gameExecutable == customExecutable)
        #expect(sessions["starrail"]?.sessionLogURL == logs.old.url)
        let sizes = try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.paths.logs)
            return (try fs.size(at: SafeRelativePath(logs.old.url.lastPathComponent)), try fs.size(at: SafeRelativePath(logs.newer.url.lastPathComponent)))
        }
        #expect(sizes.0 == 1024)
        #expect((sizes.1 ?? 0) > 1024)
        await f.clock.waitForSleep(1, duration: .seconds(3)); f.clock.advance(by: .seconds(3))
        await f.clock.waitForSleep(2, duration: .seconds(3))
        #expect(await manager.liveSession(for: "starrail")?.state == .running)
        #expect(f.proxy.starts == 0)
        f.inspector.update { $0.processes = []; $0.alive = [] }; f.clock.advance(by: .seconds(3))
        await manager.waitForSupervision(game: "starrail")
        try await f.assertOriginalRestored()
        #expect(try await f.journal() == nil)
    }

    @Test func otherGameOperationDoesNotInterruptLaunchJournal() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let otherLease = try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: f.paths.root)
            try fs.createDirectory(at: SafeRelativePath("Games/zzz"))
            return try GameOperationLease.acquire(fs: ContainedFileSystem(root: f.paths.games))
        }
        defer { withExtendedLifetime(otherLease) {} }
        let consumer = await f.consume(manager, events: events)
        await events.wait { if case .running = $0 { true } else if case .failed = $0 { true } else { false } }
        let initial = await events.values
        try #require(initial.contains { if case .running = $0 { true } else { false } },
            "Another game's operation lease must not block launch snapshot or preparation")
        try await f.assertHidden()
        #expect(try await f.journal()?.state == .running)
        await manager.markReady(game: "starrail"); await events.waitForReady()
        await f.clock.waitForSleep(1, duration: .seconds(3))
        let replacement = InspectedProcess(identity: ProcessIdentity(pid: 24555, startTime: 400), executablePath: "/wine/StarRail.exe", arguments: [])
        f.inspector.update { $0.processes = [replacement]; $0.alive = [replacement.identity] }
        f.clock.advance(by: .seconds(3)); await f.clock.waitForSleep(2, duration: .seconds(3))
        #expect(try await f.journal()?.processes.contains(replacement.identity) == true)
        try await f.end(manager); await consumer.value
        let result = await events.values
        #expect(result.contains { if case .restored(.clean) = $0 { true } else { false } })
        #expect(!result.contains { if case .failed = $0 { true } else { false } })
        #expect(try await f.journal() == nil)
        try await f.assertOriginalRestored()
        try await BlockingIO.run { () -> Void in
            #expect(throws: LauncherError.self) { try GameOperationLease.acquire(fs: ContainedFileSystem(root: f.paths.games)) }
        }
    }

}

/// Both failed lookups are real inspector inputs, rather than an injected scan error.
private final class ManagerUnclassifiableKernel: ProcessKernel, Sendable {
    enum Mode { case unreadable, readable, gone }
    private struct State { var mode = Mode.unreadable; var failedArguments = 0; var failedPaths = 0 }
    private let state = Mutex(State())
    private let prefix: String
    init(prefix: String) { self.prefix = prefix }
    var failedArguments: Int { state.withLock { $0.failedArguments } }
    var failedPaths: Int { state.withLock { $0.failedPaths } }
    func set(_ mode: Mode) { state.withLock { $0.mode = mode } }
    func bootSessionUUID() throws -> String { ManagerFixture.bootSessionUUID }
    func process(pid: Int32) -> kinfo_proc? { processes().first { $0.kp_proc.p_pid == pid } }
    func processes() -> [kinfo_proc] {
        guard state.withLock({ $0.mode != .gone }) else { return [] }
        var info = kinfo_proc()
        info.kp_proc.p_pid = 23456; info.kp_proc.p_stat = Int8(SRUN)
        info.kp_eproc.e_ucred.cr_uid = geteuid(); info.kp_eproc.e_pgid = 23456
        info.kp_proc.p_un.__p_starttime.tv_sec = 2
        return [info]
    }
    func executablePath(pid: Int32) throws -> String? {
        try state.withLock { state in
            switch state.mode {
            case .unreadable:
                state.failedPaths += 1
                throw ProcessInspectionError.incompleteScan
            case .readable: return "/runtime/StarRail.exe"
            case .gone: return nil
            }
        }
    }
    func arguments(pid: Int32) -> Data? {
        guard state.withLock({ state in
            if state.mode == .unreadable { state.failedArguments += 1; return false }
            return state.mode == .readable
        }) else { return nil }
        var argc: Int32 = 1
        var bytes = withUnsafeBytes(of: &argc) { Data($0) }
        bytes.append(contentsOf: "/runtime/StarRail.exe\0\0StarRail.exe\0WINEPREFIX=\(prefix)\0\0".utf8)
        return bytes
    }
}
