// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Darwin
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import GameLibrary
import Sophon
import Launch
@testable import MacGacha

@Suite(.serialized) @MainActor
struct AppModelGamesTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["snapshot", "cacheInfo"], [false, true])
    func remountDuringEjectFinalizationRestoresAvailableState(read: String, notifiedEject: Bool) async throws {
        let gate = GameReadGate(), source = TestVolumeEventSource(), fake = FakeGameServices()
        defer { gate.release(); fake.finish() }
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/Game")
        let volume = URL(fileURLWithPath: "/Volumes/Games SSD")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        if read == "snapshot" { fake.gateNextRecordRead(gate) }
        else { fake.gateNextCacheInfoRead(gate) }
        fake.setStatus(.locationUnavailable(path), for: "genshin")
        if notifiedEject { source.send(.unmounted(volume)) }
        else { fake.fail(.installVolumeUnavailable) }
        await gate.waitUntilEntered()
        fake.setStatus(.paused(.update), for: "genshin")
        source.send(.mounted(volume))
        if !notifiedEject {
            // This refresh completes before the consumer. A preserved revision
            // alone cannot prevent the older final snapshot from overwriting it.
            await model.volumeEventTask?.value
            #expect(model.games["genshin"]?.status == .paused(.update))
        }
        gate.release()
        await operation.value; await model.volumeEventTask?.value
        #expect(model.games["genshin"]?.status == .paused(.update))
        #expect(model.gameLocationURL(for: "genshin") == path)
        #expect(model.unavailableVolumeName(for: "genshin") == nil)
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(fake.calls.count == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["snapshot", "cacheInfo"])
    func lateEjectDuringFinalizationRetainsReservationUntilDrain(read: String) async throws {
        let milestones = AsyncStream<Bool>.makeStream()
        let snapshot = GameReadGate()
        let drain = GameReadGate(onEntry: { milestones.continuation.yield(true) })
        let source = TestVolumeEventSource(), fake = FakeGameServices(idleDrain: drain)
        defer { snapshot.release(); drain.release(); fake.finish() }
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/Game")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        if read == "snapshot" { fake.gateNextRecordRead(snapshot) }
        else { fake.gateNextCacheInfoRead(snapshot) }
        model.pauseGame("genshin")
        await snapshot.waitUntilEntered()
        let finished = Task { await operation.value; milestones.continuation.yield(false) }
        defer { finished.cancel() }
        fake.setStatus(.locationUnavailable(path), for: "genshin")
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Games SSD")))
        snapshot.release()
        var events = milestones.stream.makeAsyncIterator()
        #expect(await events.next() == true)
        #expect(model.gameOperation != nil)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
        drain.release()
        await operation.value; await model.volumeEventTask?.value
        #expect(model.gameOperation == nil)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
    }

    @Test(.timeLimit(.minutes(1))) func completedUpdateRejectsEarlierVolumeSnapshot() async throws {
        let read = GameReadGate(), source = TestVolumeEventSource()
        let fake = FakeGameServices(locationRead: read)
        defer { read.release(); fake.finish() }
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/Game")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        let target = InstalledBuild(tag: "2.0", buildID: "updated", categories: [], voices: ["en-us"])
        var pending = try #require(try await fake.record("genshin"))
        pending.pending = PendingOperation(kind: .update, planID: try SafeIdentifier("gated-update"),
            planDigest: try Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)), target: target)
        fake.setRecord(pending, for: "genshin")
        model.setGameRecord("genshin", pending)
        source.send(.mounted(URL(fileURLWithPath: "/Volumes/Games SSD")))
        await read.waitUntilEntered()
        var completed = pending; completed.pending = nil; completed.installed = target
        fake.setRecord(completed, for: "genshin")
        fake.setStatus(.installed(tag: "2.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.finish()
        await operation.value
        #expect(model.gameRecord("genshin") == completed)
        #expect(model.games["genshin"]?.status == .installed(tag: "2.0"))
        read.release(); await model.volumeEventTask?.value
        #expect(model.gameRecord("genshin") == completed)
        #expect(model.games["genshin"]?.status == .installed(tag: "2.0"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["/Volumes/Games SSD/Image", "/Volumes/Games SSD/Game 2",
        "/System/Volumes/Data/Volumes/Games SSD/Image"])
    func nestedOrSiblingMountDoesNotCancelTransfer(mount: String) async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        defer { fake.finish() }
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/Game")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        source.send(.unmounted(URL(fileURLWithPath: mount)))
        await model.volumeEventTask?.value
        #expect(!operation.isCancelled)
        #expect(model.gameLocationPauseReason(for: "genshin") == nil)
        #expect(!fake.locationReads.contains("genshin"))
        fake.setStatus(.installed(tag: "2.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.finish(); await operation.value
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nestedMountEjectMatchesContainedGameAcrossDataAlias(aliasInstall: Bool) async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        defer { fake.finish() }
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: aliasInstall ? "/System/Volumes/Data/Volumes/Games SSD/Image/Game" : "/Volumes/Games SSD/Image/Game")
        let mount = URL(fileURLWithPath: aliasInstall ? "/Volumes/Games SSD/Image" : "/System/Volumes/Data/Volumes/Games SSD/Image")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        fake.setStatus(.locationUnavailable(path), for: "genshin")
        source.send(.unmounted(mount))
        #expect(operation.isCancelled)
        await operation.value; await model.volumeEventTask?.value
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
    }

    @Test func destinationOnlyRemountRetriesMoveRecoveryAndRefreshesSource() async throws {
        let gate = GameReadGate(), source = TestVolumeEventSource(), fake = FakeGameServices(moveRecoveryRead: gate)
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        await model.start()
        fake.recoveryResult = ["genshin"]
        source.send(.mounted(URL(fileURLWithPath: "/Volumes/Destination")))
        await gate.waitUntilEntered()
        #expect(model.isBusyForUpdates)
        #expect(model.languageRestartBlocker != nil)
        #expect(!model.canMoveGame("genshin"))
        gate.release()
        await model.volumeEventTask?.value
        #expect(!model.isBusyForUpdates)
        #expect(fake.moveRecoveryCount == 1)
        #expect(fake.locationReads.contains("genshin"))
        #expect(model.gameRecord("genshin")?.installPath == gameLocation)
    }

    @Test func ejectingMoveDestinationCancelsItsOperation() async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        await model.start()
        model.moveGame("genshin", to: URL(fileURLWithPath: "/Volumes/Destination"))
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Destination")))
        #expect(task.isCancelled)
        await task.value; await model.volumeEventTask?.value
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(model.gameOperation == nil)
    }

    @Test func moveUsesGameReservationAndRefusesLanguageRestart() async throws {
        let (model, fake, _) = try gameFixture()
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        await model.start()
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
        #expect(model.canMoveGame("genshin"))
        model.moveGame("genshin", to: URL(fileURLWithPath: "/tmp/move-model-test"))
        let task = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        #expect(model.isBusyForUpdates)
        #expect(model.gameOperation?.isMoving == true)
        #expect(model.languageRestartBlocker == .unresumableOperation("genshin"))
        #expect(!model.canMoveGame("genshin"))
        fake.emit(.phase(.staging))
        for await phase in Observations({ model.gameMovePhase(for: "genshin") }) {
            if phase == .copying { break }
        }
        fake.emit(.progress(downloaded: 0, totalNetwork: 0, staged: 5, totalStaged: 10))
        for await state in Observations({ model.games["genshin"] }) {
            if case .working(_, let fraction, _, _, _) = state?.activity, fraction == 0.5 { break }
        }
        for (phase, expected) in [(OperationPhase.verifying, GameMovePhase.verifying), (.committing, .finishing)] {
            fake.emit(.phase(phase))
            for await current in Observations({ model.gameMovePhase(for: "genshin") }) {
                if current == expected { break }
            }
        }
        fake.emit(.phase(.completed)); fake.finish()
        await task.value
        #expect(model.gameOperation == nil)
        #expect(model.gameMovePhase(for: "genshin") == nil)
        #expect(fake.calls.contains { $0.action == "move" })
    }

    @Test(arguments: [GameStatus.paused(.update), .uninstallPaused, .notInstalled, .locationUnavailable(gameLocation)])
    func moveMenuRejectsUnavailableOrPausedGames(status: GameStatus) async throws {
        let (model, fake, _) = try gameFixture()
        fake.setStatus(status, for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.setGameState("genshin", GameState(status: status))
        #expect(!model.canMoveGame("genshin"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["install", "adopt"])
    func unrelatedEjectDoesNotCancelFreshOperationBeforeRecordPublication(action: String) async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        if action == "install" { model.installGame("genshin", voices: [], at: gameLocation, approved: true) }
        else { model.adoptGame("genshin", folder: gameLocation, voices: []) }
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        #expect(model.gameRecord("genshin") == nil)
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Unrelated USB")))
        await model.volumeEventTask?.value
        #expect(!operation.isCancelled)
        #expect(model.gameLocationPauseReason(for: "genshin") == nil)
        fake.emit(.phase(.completed)); fake.finish()
        await operation.value
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["install", "adopt"])
    func matchingEjectCancelsFreshExternalOperationBeforeRecordPublication(action: String) async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/New Game")
        fake.setLocation(path, for: "genshin")
        if action == "install" { model.installGame("genshin", voices: [], at: path, approved: true) }
        else { model.adoptGame("genshin", folder: path, voices: []) }
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        #expect(model.gameRecord("genshin") == nil)
        fake.setStatus(.locationUnavailable(path), for: "genshin")
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Games SSD")))
        #expect(operation.isCancelled)
        await operation.value; await model.volumeEventTask?.value
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
    }

    @Test func playRechecksUnavailableLocationBeforeCallingLaunchService() async throws {
        let launches = LocationLaunchSpy()
        let (model, fake, _) = try gameFixture(launches: launches)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
        fake.setStatus(.locationUnavailable(gameLocation), for: "genshin")
        model.play("genshin")
        await model.launchTasks["genshin"]?.value
        #expect(launches.count == 0)
        #expect(model.games["genshin"]?.status == .locationUnavailable(gameLocation))
        #expect(model.launchState(for: "genshin") == nil)
        #expect(model.launchSlotOwner == nil)
        #expect(!model.liveLaunchGames.contains("genshin"))
    }

    @Test func workspaceSourceDeliversInjectedMountAndUnmountNotifications() async throws {
        let center = NotificationCenter(), source = WorkspaceVolumeEventSource(center: center)
        let events = AsyncStream<VolumeEvent>.makeStream()
        let observation = source.observe { events.continuation.yield($0) }
        var iterator = events.stream.makeAsyncIterator()
        let drive = URL(fileURLWithPath: "/Volumes/Games SSD")
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: drive])
        guard case .unmounted(let removed) = await iterator.next() else { Issue.record("Missing unmount event"); return }
        #expect(removed == drive)
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        guard case .mounted(let mounted) = await iterator.next() else { Issue.record("Missing mount event"); return }
        #expect(mounted == nil)
        withExtendedLifetime(observation) {}
    }

    @Test func volumeEventsRefreshBothRegionsWithoutRefreshingOtherDrives() async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let drive = URL(fileURLWithPath: "/Volumes/Games SSD")
        for id in ["genshin", "genshin-cn", "zzz"] {
            let path = URL(fileURLWithPath: id == "zzz" ? "/Volumes/Other/Game" : "/Volumes/Games SSD/\(id)")
            fake.setLocation(path, for: id)
            fake.setStatus(.installed(tag: "1.0"), for: id)
            model.setGameRecord(id, try await fake.record(id))
            model.setGameState(id, GameState(status: .installed(tag: "1.0")))
        }
        for id in ["genshin", "genshin-cn"] {
            fake.setStatus(.locationUnavailable(try #require(model.gameRecord(id)).installPath), for: id)
        }
        source.send(.unmounted(drive))
        await model.volumeEventTask?.value
        #expect(Set(fake.locationReads) == ["genshin", "genshin-cn"])
        #expect(model.unavailableVolumeName(for: "genshin-cn") == "Games SSD")
        #expect(model.gameLocationHint(for: "genshin")?.contains("Games SSD") == true)
        #expect(model.gameLocationURL(for: "genshin") == nil)
        #expect(model.games["zzz"]?.status == .installed(tag: "1.0"))
        fake.setStatus(.paused(.update), for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin-cn")
        source.send(.mounted(drive))
        await model.volumeEventTask?.value
        #expect(model.games["genshin"]?.status == .paused(.update))
        #expect(model.games["genshin-cn"]?.status == .installed(tag: "1.0"))
        #expect(model.unavailableVolumeName(for: "genshin") == nil)
        #expect(model.gameLocationURL(for: "genshin") == model.gameRecord("genshin")?.installPath)
        #expect(fake.statusCount == 0)
    }

    @Test func unknownVolumeEventRechecksAllKnownLocations() async throws {
        let source = TestVolumeEventSource(), fake = FakeGameServices()
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        for id in ["genshin", "zzz-cn"] {
            fake.setStatus(.installed(tag: "1.0"), for: id)
            model.setGameRecord(id, try await fake.record(id))
        }
        source.send(.mounted(nil))
        await model.volumeEventTask?.value
        #expect(Set(fake.locationReads) == ["genshin", "zzz-cn"])
    }

    @Test(arguments: ["update", "verify", "uninstall", "resume", "voices"])
    func unavailableLocationIsRecheckedBeforeOperation(action: String) async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
        fake.setStatus(.locationUnavailable(gameLocation), for: "genshin")
        switch action {
        case "update": model.updateGame("genshin")
        case "verify": model.verifyGame("genshin")
        case "resume": model.resumeGame("genshin")
        case "voices": model.setVoices("genshin", ["en-us"])
        default: await model.uninstallGame("genshin")
        }
        await model.gameTask?.value
        #expect(fake.calls.isEmpty)
        #expect(model.games["genshin"]?.status == .locationUnavailable(gameLocation))
        #expect(!model.isGameOperationRunning)
    }

    @Test(.timeLimit(.minutes(1))) func ejectCancelsOnlyAffectedOperationAndKeepsPauseReasonAfterReconnect() async throws {
        let drain = GameReadGate()
        defer { drain.release() }
        let source = TestVolumeEventSource(), fake = FakeGameServices(idleDrain: drain)
        let (model, _, _) = try gameFixture(fake: fake, volumeEvents: source)
        let path = URL(fileURLWithPath: "/Volumes/Games SSD/Game")
        fake.setLocation(path, for: "genshin")
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.setGameRecord("genshin", try await fake.record("genshin"))
        model.updateGame("genshin")
        let operation = try #require(model.gameTask)
        var opened = fake.opened.stream.makeAsyncIterator(); _ = await opened.next()
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Other")))
        await model.volumeEventTask?.value
        #expect(!operation.isCancelled)
        fake.setStatus(.locationUnavailable(path), for: "genshin")
        source.send(.unmounted(URL(fileURLWithPath: "/Volumes/Games SSD")))
        await drain.waitUntilEntered()
        #expect(model.gameOperation != nil)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
        drain.release()
        await operation.value; await model.volumeEventTask?.value
        #expect(operation.isCancelled)
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(model.games["genshin"]?.status == .locationUnavailable(path))
        fake.setStatus(.paused(.update), for: "genshin")
        source.send(.mounted(URL(fileURLWithPath: "/Volumes/Games SSD")))
        await model.volumeEventTask?.value
        #expect(model.games["genshin"]?.status == .paused(.update))
        #expect(model.gameLocationPauseReason(for: "genshin") == .installVolumeUnavailable)
        #expect(fake.calls.count == 1)
    }

    @Test func verifyByteProgressReachesGameTimingAndPauseClearsIt() async throws {
        let (model, fake, clock) = try gameFixture(); defer { fake.finish() }
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        model.verifyGame("genshin")
        let worker = try #require(model.gameTask)
        for await _ in fake.opened.stream { break }
        fake.emit(.phase(.verifying))
        fake.emit(.progress(downloaded: 0, totalNetwork: 0, staged: 0, totalStaged: 2000))
        try await timingEventually { model.games["genshin"]?.timing?.hasFraction == true }
        #expect(model.games["genshin"]?.timing?.remaining == nil)
        clock.advance(.seconds(10))
        fake.emit(.progress(downloaded: 0, totalNetwork: 0, staged: 1000, totalStaged: 2000))
        try await timingEventually { model.games["genshin"]?.timing?.remaining != nil }
        let state = try #require(model.games["genshin"])
        #expect(state.activity == .working(.verifying, fraction: 0.5, bytesPerSecond: nil))
        #expect(state.timing?.remaining == .seconds(10))
        fake.finish(); await worker.value
        #expect(model.games["genshin"]?.timing == nil)
    }

    @Test func editionRegistryAndInstallFoldersAreEditionSpecific() throws {
        #expect(LauncherGame.all.map(\.id) == GameDefinition.all.map(\.id))
        #expect(LauncherGame.all.count == 6)
        let style = try #require(LauncherGame.all.first)
        for definition in GameDefinition.inRegion(.mainlandChina) {
            let game = LauncherGame(id: definition.id, name: "Unrelated interface name", tint: style.tint, deepTint: style.deepTint)
            #expect(game.defaultInstallDirectoryName == definition.defaultInstallDirectoryName)
        }
        for game in LauncherGame.all { #expect(game.defaultInstallDirectoryName == GameDefinition.find(game.id)?.defaultInstallDirectoryName) }
        let localizedGlobal = LauncherGame(id: "genshin", name: "原神", tint: style.tint, deepTint: style.deepTint)
        #expect(localizedGlobal.defaultInstallDirectoryName == "Genshin Impact")
    }

    @Test(arguments: GameDefinition.all.map(\.id))
    func liveGameServicesSelectEditionEndpoints(id: String) async throws {
        let game = try #require(GameDefinition.find(id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CN2-Services-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let http = GameFailingHTTP(error: .transport("injected metadata failure"))
        let services = LiveGameServices(paths: AppPaths(root: root.appendingPathComponent("app")), http: http)
        await #expect(throws: LauncherError.transport("delivery request failed")) {
            _ = try await services.estimate(id, voices: ["zh-cn"], at: root.appendingPathComponent("install"))
        }
        let request = try #require(http.requests.first)
        #expect(request.host == game.region.hypAPIHost)
        #expect(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "launcher_id" }?.value == game.region.launcherID)
    }

    @Test func adoptionErrorsHaveSpecificSafeMessages() {
        let messages = [LauncherError.gameEditionMismatch.userMessage, LauncherError.gameEditionUnknown.userMessage,
            LauncherError.gameDistributionUnsupported.userMessage]
        #expect(Set(messages).count == 3)
        #expect(messages.allSatisfy { !$0.isEmpty && !$0.contains("/Users/") })
    }

    @Test func cachedUpdateKeepsProgressAcrossBatchPhases() async throws {
        let (model, fake, clock) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging))
        fake.emit(.progress(downloaded: 100, totalNetwork: 100, staged: 100, totalStaged: 900))
        let expected = GameActivity.working(.staging, fraction: 0.2, bytesPerSecond: nil)
        try await gamesEventually { model.games["genshin"]?.activity == expected }
        // Exercise each synchronous presentation transition so a later progress
        // event cannot hide a transient spinner or loss of fraction.
        let phaseStarted = model.games["genshin"]?.timing?.phaseStarted
        for phase in [OperationPhase.committing, .checkingSpace, .staging] {
            clock.advance(.seconds(1))
            model.setGameOperationPhase("genshin", phase: phase)
            #expect(model.games["genshin"]?.activity == .working(phase, fraction: 0.2, bytesPerSecond: nil))
            #expect(model.games["genshin"]?.timing?.phaseStarted == phaseStarted)
        }
        fake.emit(.phase(.committing))
        fake.emit(.phase(.checkingSpace))
        fake.emit(.phase(.staging))
        clock.advance(.seconds(1))
        fake.emit(.progress(downloaded: 100, totalNetwork: 100, staged: 200, totalStaged: 900))
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.staging, fraction: 0.3, bytesPerSecond: nil)
        }
        #expect(model.games["genshin"]?.timing?.phaseStarted != clock.time)
    }

    @Test func installEmitsWorkingThenInstalled() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        #expect(model.games["genshin"]?.activity == .resolving)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging))
        fake.emit(.progress(downloaded: 25, totalNetwork: 100, staged: 0, totalStaged: 100))
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.staging, fraction: 0.125, bytesPerSecond: nil, downloaded: 25, total: 100)
        }
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
        #expect(model.installedVoices("genshin") == ["en-us"])
        #expect(model.lastError == nil)
        #expect(fake.calls.first == GameCall(action: "install", id: "genshin", approved: false, voices: ["en-us"]))
    }

    @Test func pauseCancelsAndShowsPaused() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging)); model.pauseGame("genshin")
        try await gamesEventually { model.games["genshin"] == GameState(status: .paused(.install)) }
        #expect(model.lastError == nil)
        #expect(fake.terminated > 0)
    }

    @Test(arguments: [true, false]) func approvalPairSurfacesAndApproveResumes(throwsAfterApproval: Bool) async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.needsBatchApproval(required: 200, available: 100))
        if throwsAfterApproval { fake.fail(.insufficientSpace(required: 200, available: 100)) } else { fake.finish() }
        try await gamesEventually {
            model.games["genshin"] == GameState(status: .paused(.install), activity: .needsApproval(required: 200, available: 100),
                spaceShortage: GameSpaceShortage(required: 200, available: 100))
        }
        #expect(model.lastError == nil)
        model.approveBatches("genshin")
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.action == "resume" && fake.calls.last?.approved == true)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin"); fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
    }

    @Test func approvalWaitsForStreamDrainAndSnapshotBeforeBecomingActionable() async throws {
        let terminal = GameReadGate(), snapshot = GameReadGate()
        let fake = FakeGameServices(approvalTerminalRead: terminal, snapshotRead: snapshot)
        let (model, _, _) = try gameFixture(fake: fake)
        defer { terminal.release(); snapshot.release(); fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: false)

        try await gamesEventually { terminal.entered }
        #expect(model.games["genshin"]?.activity == .resolving)
        model.approveBatches("genshin")
        #expect(model.lastError == nil && fake.calls.count == 1)

        terminal.release()
        try await gamesEventually { snapshot.entered }
        #expect(model.games["genshin"]?.activity == .resolving)
        model.approveBatches("genshin")
        #expect(model.lastError == nil && fake.calls.count == 1)

        snapshot.release()
        try await gamesEventually {
            model.games["genshin"] == GameState(status: .paused(.install), activity: .needsApproval(required: 200, available: 100),
                spaceShortage: GameSpaceShortage(required: 200, available: 100))
        }
        model.approveBatches("genshin")
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.action == "resume" && fake.calls.last?.approved == true)
        #expect(model.lastError == nil)
        fake.setStatus(.installed(tag: "1.0"), for: "genshin")
        fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { model.games["genshin"] == GameState(status: .installed(tag: "1.0")) }
    }

    @Test func failureShowsMessageAndKeepsPaused() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.fail(.transport("https://cdn.hoyoverse.com/file?password=secret"))
        try await gamesEventually { model.games["genshin"] == GameState(status: .paused(.install)) && model.lastError != nil }
        #expect(model.lastError == LauncherError.transport("").userMessage)
        #expect(model.lastError?.contains("secret") == false)
    }

    @Test func onlyOneGameOperationAtATime() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        model.installGame("starrail", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        #expect(fake.calls.first?.id == "genshin")
        #expect(model.lastError == LauncherError.busy("").userMessage)
        #expect(model.games["starrail"]?.activity == nil)
        model.pauseGame("genshin")
        try await gamesEventually { model.games["genshin"]?.activity == nil }
        model.installGame("starrail", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 2 }
        #expect(fake.calls.last?.id == "starrail")
    }

    @Test func refreshMapsStatuses() async throws {
        let (model, fake, _) = try gameFixture()
        fake.setStatus(.updateAvailable(from: "1", to: "2"), for: "genshin")
        fake.setStatus(.paused(.repair), for: "starrail")
        fake.setStatus(.locationUnavailable(gameLocation), for: "zzz")
        await model.refreshGames()
        #expect(model.games["genshin"] == GameState(status: .updateAvailable(from: "1", to: "2")))
        #expect(model.games["starrail"] == GameState(status: .paused(.repair)))
        #expect(model.games["zzz"] == GameState(status: .locationUnavailable(gameLocation)))
        #expect(fake.startCount == 1)
        #expect(model.installedVoices("genshin") == ["en-us"])
        #expect(model.installedVoices("missing").isEmpty)
    }

    @Test func startAndActivationRefreshAreThrottledForTenMinutes() async throws {
        let (model, fake, clock) = try gameFixture()
        await model.start()
        #expect(fake.startCount == 1 && fake.statusCount == 3)
        await model.start(); await model.refreshGames()
        #expect(fake.startCount == 1 && fake.statusCount == 3)
        clock.advance(.seconds(599)); await model.refreshGames(); #expect(fake.statusCount == 3)
        clock.advance(.seconds(1))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await gamesEventually { fake.statusCount == 6 }
    }

    @Test func progressKeepsPhaseThrottlesAndUsesFiveSecondSpeed() async throws {
        let (model, fake, clock) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.verifying)); fake.progress(0)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0, bytesPerSecond: nil) }
        clock.advance(.milliseconds(100)); fake.progress(100)
        // A later phase event acts as a barrier after the throttled progress.
        fake.emit(.phase(.verifying))
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: nil, bytesPerSecond: nil) }
        clock.advance(.milliseconds(3900)); fake.progress(400)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.4, bytesPerSecond: 100) }
        clock.advance(.seconds(2)); fake.progress(600)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.6, bytesPerSecond: 100) }
        clock.advance(.seconds(4)); fake.progress(700)
        try await gamesEventually { model.games["genshin"]?.activity == .working(.verifying, fraction: 0.7, bytesPerSecond: 40) }
    }

    @Test func operationEntryPointsUseTheirCoreOperations() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        let actions: [(String, () -> Void)] = [
            ("adopt", { model.adoptGame("genshin", folder: gameLocation, voices: ["en-us"]) }),
            ("update", { model.updateGame("genshin") }), ("resume", { model.resumeGame("genshin") }),
            ("verify", { model.verifyGame("genshin") }), ("voices", { model.setVoices("genshin", ["ja-jp"]) }),
        ]
        for (index, item) in actions.enumerated() {
            item.1(); try await gamesEventually { fake.calls.count == index + 1 }
            #expect(fake.calls.last?.action == item.0)
            if item.0 == "update" || item.0 == "resume" { #expect(fake.calls.last?.approved == false) }
            fake.setStatus(.installed(tag: "1.0"), for: "genshin"); fake.emit(.phase(.completed)); fake.finish()
            try await gamesEventually { model.games["genshin"]?.activity == nil }
        }
        await model.uninstallGame("genshin")
        #expect(fake.calls.last?.action == "uninstall")
        #expect(model.games["genshin"] == GameState(status: .notInstalled))
    }

    @Test func estimateForwardsSelectionAndThrowsWithoutAlerting() async throws {
        let (model, fake, _) = try gameFixture()
        let estimate = try await model.estimate("genshin", voices: ["ja-jp"], at: gameLocation)
        #expect(estimate == GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150))
        #expect(model.games["genshin"]?.activity == nil)
        #expect(fake.estimateCalls.last == GameCall(action: "estimate", id: "genshin", voices: ["ja-jp"]))
        fake.estimateError = .unsafePath("/other-user/private?password=secret")
        await #expect(throws: LauncherError.unsafePath("/other-user/private?password=secret")) {
            _ = try await model.estimate("genshin", voices: [], at: gameLocation)
        }
        #expect(model.lastError == nil)
    }

    @Test func overlappingEstimatesAreIndependentAndDoNotReserveGame() async throws {
        let english = GameReadGate(), japanese = GameReadGate()
        let fake = FakeGameServices(estimateReads: [["en-us"]: english, ["ja-jp"]: japanese])
        let (model, _, _) = try gameFixture(fake: fake)
        defer { english.release(); japanese.release() }
        let first = Task { try await model.estimate("genshin", voices: ["en-us"], at: gameLocation) }
        let second = Task { try await model.estimate("genshin", voices: ["ja-jp"], at: gameLocation) }
        defer { first.cancel(); second.cancel() }
        try await gamesEventually { english.entered && japanese.entered }
        #expect(!model.isGameOperationRunning)
        #expect(model.games["genshin"]?.activity == nil && model.lastError == nil)
        japanese.release()
        let secondValue = try await second.value
        #expect(secondValue == GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150))
        english.release()
        let firstValue = try await first.value
        #expect(firstValue == secondValue)
        #expect(fake.startCount == 1)
    }

    @Test func estimateReturnsDuringAnotherGamesOperation() async throws {
        let (model, fake, _) = try gameFixture(); defer { fake.finish() }
        model.installGame("starrail", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        let value = try await model.estimate("genshin", voices: ["en-us"], at: gameLocation)
        #expect(value == GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150))
        #expect(model.isGameOperationRunning && model.lastError == nil)
        #expect(model.games["starrail"]?.activity == .resolving)
        #expect(model.games["genshin"]?.activity == nil)
    }

    @Test func gameOperationRunningIsObservableUntilReservationReleased() async throws {
        let snapshot = GameReadGate(), fake = FakeGameServices(snapshotRead: snapshot)
        let (model, _, _) = try gameFixture(fake: fake)
        defer { snapshot.release(); fake.finish() }
        let started = Mutex(false), finished = Mutex(false)
        withObservationTracking { #expect(!model.isGameOperationRunning) }
            onChange: { started.withLock { $0 = true } }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        #expect(model.isGameOperationRunning && started.withLock { $0 })
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.completed)); fake.finish()
        try await gamesEventually { snapshot.entered }
        withObservationTracking { #expect(model.isGameOperationRunning) }
            onChange: { finished.withLock { $0 = true } }
        snapshot.release()
        try await gamesEventually { !model.isGameOperationRunning }
        #expect(finished.withLock { $0 })
    }

    @Test func progressBytesAreKnownOnlyWhileDownloadingInStaging() async throws {
        let (model, fake, clock) = try gameFixture(); defer { fake.finish() }
        model.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging)); fake.progress(250)
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.staging, fraction: 0.125, bytesPerSecond: nil, downloaded: 250, total: 1000)
        }
        clock.advance(.seconds(1))
        fake.emit(.progress(downloaded: 0, totalNetwork: 0, staged: 500, totalStaged: 1000))
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.staging, fraction: 0.5, bytesPerSecond: nil, downloaded: nil, total: nil)
        }
        clock.advance(.seconds(1))
        fake.emit(.phase(.verifying)); fake.progress(750)
        try await gamesEventually {
            model.games["genshin"]?.activity == .working(.verifying, fraction: 0.75, bytesPerSecond: nil, downloaded: nil, total: nil)
        }
    }

    @Test func droppingModelCancelsActiveGameStream() async throws {
        let fake = FakeGameServices()
        let root = URL(fileURLWithPath: "/tmp/macgacha-game-lifetime-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var model: AppModel? = AppModel(paths: AppPaths(root: root), manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(),
            defaults: nil, gameServices: fake)
        weak let reference = model
        model?.installGame("genshin", voices: [], at: gameLocation, approved: true)
        try await gamesEventually { fake.calls.count == 1 }
        model = nil
        try await gamesEventually { reference == nil && fake.terminated > 0 }
    }

    @Test func progressObservesCounterResetInsideThrottleWindow() {
        var progress = GameProgress()
        let start = ContinuousClock.now
        _ = progress.update(at: start, downloaded: 100, network: 100, staged: 0, totalStaged: 0)
        #expect(progress.update(at: start.advanced(by: .milliseconds(100)), downloaded: 0, network: 1000, staged: 0, totalStaged: 0) == nil)
        let next = progress.update(at: start.advanced(by: .milliseconds(300)), downloaded: 200, network: 1000, staged: 0, totalStaged: 0)
        #expect(next?.fraction == 0.2 && next?.speed == nil)
        let steady = progress.update(at: start.advanced(by: .milliseconds(600)), downloaded: 500, network: 1000, staged: 0, totalStaged: 0)
        #expect(steady?.speed == 1000)
    }

    @Test func progressBoundaryAndCounterResetsAreSafe() {
        var progress = GameProgress()
        let start = ContinuousClock.now
        #expect(progress.update(at: start, downloaded: 0, network: 100, staged: 0, totalStaged: 0)?.fraction == 0)
        #expect(progress.update(at: start.advanced(by: .milliseconds(249)), downloaded: 50, network: 100, staged: 0, totalStaged: 0) == nil)
        let accepted = progress.update(at: start.advanced(by: .milliseconds(250)), downloaded: 50, network: 100, staged: 0, totalStaged: 0)
        #expect(accepted?.fraction == 0.5 && accepted?.speed == 200)
        let reset = progress.update(at: start.advanced(by: .seconds(1)), downloaded: 10, network: 100, staged: 0, totalStaged: 0)
        #expect(reset?.fraction == 0.1 && reset?.speed == nil)
        let local = progress.update(at: start.advanced(by: .seconds(2)), downloaded: 0, network: 0, staged: 20, totalStaged: 10)
        #expect(local?.fraction == 1 && local?.speed == nil)
        _ = progress.update(at: start.advanced(by: .seconds(3)), downloaded: 0, network: Int64.max, staged: 0, totalStaged: 0)
        let huge = progress.update(at: start.advanced(by: .milliseconds(3250)), downloaded: Int64.max, network: Int64.max, staged: 0, totalStaged: 0)
        #expect(huge?.speed == Int64.max && huge?.fraction == 1)
    }

    @Test(arguments: [LauncherError.transport("https://cdn.hoyoverse.com/private?password=planted-secret"),
        .io("https://cdn.hoyoverse.com/private?password=planted-secret")])
    func liveServicesLogSafeFieldsWithInjectedHTTP(error: LauncherError) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaGameServices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("AppSupport")), http = GameFailingHTTP(error: error)
        let live = LiveGameServices(paths: paths, http: http)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await live.start()
        #expect(await live.status("genshin") == .notInstalled)
        #expect(http.requests.isEmpty)
        // DeliveryAPI normalizes foreign transport errors before they reach the adapter.
        await #expect(throws: LauncherError.transport("delivery request failed")) { _ = try await live.estimate("genshin", voices: ["en-us"], at: root.appendingPathComponent("Game")) }
        #expect(!http.requests.isEmpty && http.requests.allSatisfy(DeliveryHostPolicy.allows))
        let log = try String(contentsOf: paths.logs.appendingPathComponent("macgacha.log"), encoding: .utf8)
        #expect(log.contains("Game operation failed") && log.contains("genshin"))
        for forbidden in ["planted-secret", "/private", "password=", "https://"] { #expect(!log.contains(forbidden)) }
    }

    @Test func partsApprovalShowsHeldSpaceWithoutLosingApproval() async throws {
        let probe = GamePurgeableProbe(bytes: 300)
        let (model, fake, _) = try gameFixture(purgeable: probe); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.needsBatchApproval(required: 200, available: 100))
        fake.fail(.insufficientSpace(required: 200, available: 100))
        try await gamesEventually { !model.isGameOperationRunning }
        try await gamesEventually { model.games["genshin"]?.spaceShortage?.heldByMacOS == 200 }
        #expect(probe.calls == 1)
        let state = try #require(model.games["genshin"])
        #expect(PrimaryAction.resolve(state, runtimesReady: false) == .continueInParts)
        #expect(model.lastError == nil)
    }

    @Test(arguments: [EDQUOT, ENOSPC]) func allocationFailureDoesNotDiagnoseSpaceHeldByMacOS(code: Int32) async throws {
        // Exercise the real FileOps normalization: both errors lose their errno
        // and reach the app with an unmeasured (1, 0) placeholder.
        let failure = try await BlockingIO.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let fs = try ContainedFileSystem(root: root, fileOps: GameAllocationFailureOps(code: code))
            do { try fs.writeAtomically(Data("partial output".utf8), to: SafeRelativePath("output")) }
            catch { return try #require(error as? LauncherError) }
            throw LauncherError.io("Expected an allocation failure")
        }
        #expect(failure == .insufficientSpace(required: 1, available: 0))
        let probe = GamePurgeableProbe(bytes: 300)
        let (model, fake, _) = try gameFixture(purgeable: probe); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        let worker = try #require(model.gameTask)
        try await gamesEventually { fake.calls.count == 1 }
        fake.fail(failure)
        await worker.value // Includes any advisory query and its main-actor publication.
        #expect(!model.isGameOperationRunning)
        #expect(model.games["genshin"]?.status == .paused(.install))
        let shortage = try #require(model.games["genshin"]?.spaceShortage)
        #expect(shortage.heldByMacOS == nil)
        #expect(probe.calls == 0)
        #expect(model.lastError == failure.userMessage)
    }

    @Test func insufficientSpaceQueriesPurgeableOnlyAfterPause() async throws {
        let probe = GamePurgeableProbe(bytes: 300)
        let (model, fake, _) = try gameFixture(purgeable: probe); defer { fake.finish() }
        model.installGame("genshin", voices: ["en-us"], at: gameLocation, approved: false)
        try await gamesEventually { fake.calls.count == 1 }
        fake.emit(.phase(.staging))
        for _ in 0..<10 { fake.progress(1) }
        #expect(probe.calls == 0)
        fake.fail(.insufficientSpace(required: 200, available: 80))
        try await gamesEventually { model.games["genshin"]?.spaceShortage?.heldByMacOS == 220 }
        #expect(!model.isGameOperationRunning)
        #expect(probe.calls == 1)
        #expect(model.games["genshin"]?.status == .paused(.install))
        await model.refreshGames()
        #expect(probe.calls == 1)
        model.resumeGame("genshin")
        #expect(model.games["genshin"]?.spaceShortage == nil)
        try await gamesEventually { fake.calls.count == 2 }
        fake.fail(.cancelled)
        try await gamesEventually { !model.isGameOperationRunning }
        #expect(probe.calls == 1)
    }

    @Test func hostedModelAndPreviewUseInertGameServices() async {
        let model = AppModel.forCurrentProcess()
        #expect(model.games.isEmpty)
        await model.start()
        #expect(model.games.isEmpty)
        let preview = AppModel.preview()
        #expect(Set(preview.games.keys) == Set(GameDefinition.all.map(\.id)))
        #expect(preview.gameArt.isEmpty)
    }
}

private let gameLocation = URL(fileURLWithPath: "/inert/Games/Genshin")
@MainActor private func gameFixture(fake: FakeGameServices = FakeGameServices(), purgeable: any PurgeableSpaceProbe = GamePurgeableProbe(bytes: nil), volumeEvents: any VolumeEventSource = TestVolumeEventSource(), launches: any LaunchServices = PreviewLaunchServices()) throws -> (AppModel, FakeGameServices, GameTestClock) {
    let clock = GameTestClock()
    let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/AppSupport")),
        manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
        gameServices: fake, volumeEvents: volumeEvents, purgeable: purgeable, launchServices: launches, now: { clock.time })
    return (model, fake, clock)
}
@MainActor private func gamesEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("Game model condition did not become true"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private final class GameTestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var time: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ amount: Duration) { instant.withLock { $0 = $0.advanced(by: amount) } }
}
private struct GameCall: Sendable, Equatable {
    let action: String, id: String
    var approved: Bool? = nil
    var voices: Set<String> = []
}
private final class FakeGameServices: GameServices, Sendable {
    let opened = AsyncStream<Void>.makeStream()
    private let approvalTerminalRead: GameReadGate?
    private let snapshotRead: GameReadGate?
    private let idleDrain: GameReadGate?
    private let locationRead: GameReadGate?
    private let moveRecoveryRead: GameReadGate?
    private let estimateReads: [Set<String>: GameReadGate]
    init(approvalTerminalRead: GameReadGate? = nil, snapshotRead: GameReadGate? = nil, idleDrain: GameReadGate? = nil, locationRead: GameReadGate? = nil, moveRecoveryRead: GameReadGate? = nil, estimateReads: [Set<String>: GameReadGate] = [:]) {
        self.approvalTerminalRead = approvalTerminalRead; self.snapshotRead = snapshotRead
        self.estimateReads = estimateReads; self.idleDrain = idleDrain; self.locationRead = locationRead; self.moveRecoveryRead = moveRecoveryRead
    }
    private struct State: Sendable {
        var statuses: [String: GameStatus] = [:]
        var records: [String: GameRecord] = [:]
        var nextRecordRead: GameReadGate?
        var nextCacheInfoRead: GameReadGate?
        var locations: [String: URL] = [:]
        var locationReads: [String] = []
        var calls: [GameCall] = []
        var continuation: AsyncThrowingStream<OperationEvent, any Error>.Continuation?
        var active: String?
        var starts = 0, statusReads = 0, terminations = 0
        var recoveredMoves: [String] = []
        var moveRecoveries = 0
        var estimates: [GameCall] = []
        var estimateError: LauncherError?
    }
    private let state = Mutex(State())
    var estimateError: LauncherError? {
        get { state.withLock { $0.estimateError } }
        set { state.withLock { $0.estimateError = newValue } }
    }
    var recoveryResult: [String] {
        get { state.withLock { $0.recoveredMoves } }
        set { state.withLock { $0.recoveredMoves = newValue } }
    }
    var moveRecoveryCount: Int { state.withLock { $0.moveRecoveries } }
    func recoverPendingMoves() async -> [String] {
        await moveRecoveryRead?.wait()
        return state.withLock { $0.moveRecoveries += 1; return $0.recoveredMoves }
    }
    var locationReads: [String] { state.withLock { $0.locationReads } }
    func setLocation(_ path: URL, for id: String) { state.withLock { $0.locations[id] = path } }
    func locationStatus(_ id: String) async throws -> GameStatus {
        let captured = state.withLock { $0.locationReads.append(id); return $0.statuses[id] ?? .notInstalled }
        await locationRead?.wait()
        return captured
    }
    func gateNextRecordRead(_ gate: GameReadGate) { state.withLock { $0.nextRecordRead = gate } }
    func gateNextCacheInfoRead(_ gate: GameReadGate) { state.withLock { $0.nextCacheInfoRead = gate } }
    func setRecord(_ record: GameRecord, for id: String) { state.withLock { $0.records[id] = record } }
    func preDownloadInfo(_ id: String, refresh: Bool) async throws -> PreDownloadInfo {
        let gate = state.withLock { let value = $0.nextCacheInfoRead; $0.nextCacheInfoRead = nil; return value }
        await gate?.wait()
        return .unavailable
    }
    func requireGameLocationAvailable(_ id: String) async throws {
        if case .locationUnavailable = state.withLock({ $0.statuses[id] }) { throw LauncherError.installVolumeUnavailable }
    }
    var estimateCalls: [GameCall] { state.withLock { $0.estimates } }
    var calls: [GameCall] { state.withLock { $0.calls } }
    var startCount: Int { state.withLock { $0.starts } }
    var statusCount: Int { state.withLock { $0.statusReads } }
    var terminated: Int { state.withLock { $0.terminations } }
    func start() async { state.withLock { $0.starts += 1 }
    }
    func waitUntilIdle(_ id: String) async throws { await idleDrain?.wait() }
    func checkForUpdate(_ id: String) async throws -> GameStatus { await status(id) }
    func status(_ id: String) async -> GameStatus { state.withLock { $0.statusReads += 1; return $0.statuses[id] ?? .notInstalled } }
    func record(_ id: String) async throws -> GameRecord? {
        let gate = state.withLock { let value = $0.nextRecordRead; $0.nextRecordRead = nil; return value }
        await gate?.wait()
        await snapshotRead?.wait()
        if let record = state.withLock({ $0.records[id] }) { return record }
        let status = state.withLock { $0.statuses[id] ?? .notInstalled }
        if status == .notInstalled || status == .unknown { return nil }
        let build = InstalledBuild(tag: "1.0", buildID: "fixture", categories: [], voices: ["en-us"])
        return GameRecord(installPath: state.withLock { $0.locations[id] } ?? gameLocation, ownership: .created, executable: try SafeRelativePath("Game.exe"), installed: build,
            installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
    }
    func setStatus(_ status: GameStatus, for id: String) { state.withLock { $0.statuses[id] = status } }
    func estimate(_ id: String, voices: Set<String>, at location: URL) async throws -> GameEstimate {
        let error = state.withLock { $0.estimates.append(GameCall(action: "estimate", id: id, voices: voices)); return $0.estimateError }
        await estimateReads[voices]?.wait()
        if let error { throw error }
        return GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 150)
    }
    func install(_ id: String, voices: Set<String>, at location: URL, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "install", id: id, approved: approved, voices: voices), kind: .install)
    }
    func adopt(_ id: String, folder: URL, voices: Set<String>) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "adopt", id: id, voices: voices), kind: .adopt)
    }
    func update(_ id: String, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "update", id: id, approved: approved), kind: .update)
    }
    func resume(_ id: String, approved: Bool) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "resume", id: id, approved: approved), kind: .install)
    }
    func verify(_ id: String, mode: Verifier.Mode) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "verify", id: id), kind: .repair)
    }
    func setVoices(_ id: String, _ voices: Set<String>) async -> AsyncThrowingStream<OperationEvent, any Error> {
        open(GameCall(action: "voices", id: id, voices: voices), kind: .voices)
    }
    func move(_ id: String, to folder: URL) async -> GameEventStream {
        open(GameCall(action: "move", id: id), kind: .repair)
    }
    func uninstall(_ id: String) async throws {
        state.withLock { $0.calls.append(GameCall(action: "uninstall", id: id)); $0.statuses[id] = .notInstalled }
    }
    private func open(_ call: GameCall, kind: PendingOperation.Kind) -> AsyncThrowingStream<OperationEvent, any Error> {
        let pair = AsyncThrowingStream<OperationEvent, any Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.terminations += 1 } }
        state.withLock { $0.calls.append(call); $0.active = call.id; $0.statuses[call.id] = .paused(kind); $0.continuation = pair.continuation }
        opened.continuation.yield(())
        if call.action == "install", let approvalTerminalRead {
            let source = SuspendedApprovalEvents(terminal: approvalTerminalRead)
            return GameEventStream(unfolding: { try await source.next() })
        }
        return pair.stream
    }
    func emit(_ event: OperationEvent) { state.withLock { $0.continuation }?.yield(event) }
    func progress(_ count: Int64) { emit(.progress(downloaded: count, totalNetwork: 1000, staged: 0, totalStaged: 1000)) }
    func fail(_ error: LauncherError) { state.withLock { $0.continuation }?.finish(throwing: error) }
    func finish() { let continuation = state.withLock { let c = $0.continuation; $0.continuation = nil; return c }; continuation?.finish() }
}

@MainActor private func timingEventually(_ condition: @escaping @MainActor () -> Bool) async throws {
    while !condition() {
        let events = AsyncStream<Void> { continuation in
            withObservationTracking { _ = condition() } onChange: { continuation.yield(()); continuation.finish() }
        }
        for await _ in events { break }
        try Task.checkCancellation()
    }
}

private final class GameReadGate: Sendable {
    private let onEntry: @Sendable () -> Void
    init(onEntry: @escaping @Sendable () -> Void = {}) { self.onEntry = onEntry }
    private let enteredEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func waitUntilEntered() async { var iterator = enteredEvents.stream.makeAsyncIterator(); _ = await iterator.next() }
    private struct State {
        var entered = false, released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var entered: Bool { state.withLock { $0.entered } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let released = state.withLock {
                $0.entered = true
                onEntry()
                enteredEvents.continuation.yield(())
                if $0.released { return true }
                $0.continuation = continuation
                return false
            }
            if released { continuation.resume() }
        }
    }
    func release() {
        let continuation = state.withLock {
            $0.released = true
            let continuation = $0.continuation; $0.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private actor SuspendedApprovalEvents {
    let terminal: GameReadGate
    private var sentApproval = false
    init(terminal: GameReadGate) { self.terminal = terminal }
    func next() async throws -> OperationEvent? {
        if !sentApproval {
            sentApproval = true
            return .needsBatchApproval(required: 200, available: 100)
        }
        await terminal.wait()
        throw LauncherError.insufficientSpace(required: 200, available: 100)
    }
}

private final class GameFailingHTTP: HTTPClient, Sendable {
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) {
        throw LauncherError.io("Unexpected POST")
    }

    let error: LauncherError
    private let urls = Mutex<[URL]>([])
    init(error: LauncherError) { self.error = error }
    var requests: [URL] { urls.withLock { $0 } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        urls.withLock { $0.append(url) }
        throw error
    }
}

private final class GamePurgeableProbe: PurgeableSpaceProbe, Sendable {
    private let count = Mutex(0)
    let bytes: Int64?
    init(bytes: Int64?) { self.bytes = bytes }
    var calls: Int { count.withLock { $0 } }
    func importantUsageBytes(at url: URL) -> Int64? { count.withLock { $0 += 1 }; return bytes }
}

private struct GameAllocationFailureOps: FileOps {
    let code: Int32
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination,
            in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

@MainActor private final class TestVolumeEventSource: VolumeEventSource {
    private var receive: (@MainActor @Sendable (VolumeEvent) -> Void)?
    func observe(_ receive: @escaping @MainActor @Sendable (VolumeEvent) -> Void) -> any Sendable {
        self.receive = receive
        return UUID()
    }
    func send(_ event: VolumeEvent) { receive?(event) }
}

private final class LocationLaunchSpy: LaunchServices, Sendable {
    private let launches = Mutex(0)
    var count: Int { launches.withLock { $0 } }
    func reattach() async throws -> [String: LaunchSession] { [:] }
    func launch(game: GameDefinition, record: GameRecord) async throws -> AsyncStream<LaunchEvent> {
        launches.withLock { $0 += 1 }
        return AsyncStream { $0.finish() }
    }
    func observation(_ id: String) async throws -> LaunchObservation? { nil }
    func recover(_ id: String) async throws {}
    func session(_ id: String) async -> LaunchSession? { nil }
    func gameProcessIDs(_ id: String) async -> [Int32] { [] }
    func markReady(_ id: String) async {}
    func notices() async throws -> [RecoveryNotice] { [] }
    func acknowledge(_ id: UUID) async throws {}
}
