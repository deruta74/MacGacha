// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import GameLibrary
@testable import MacGacha

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct AppModelNotificationTests {
    @Test func startupReadsAuthorizationWithoutRequestingPermission() async throws {
        let center = TestGameNotificationCenter()
        let model = try fixture(center)
        await model.refreshNotificationAuthorization()
        #expect(model.notificationsEnabled)
        #expect(model.notificationAuthorization == .notDetermined)
        #expect(center.requests == 0)
        #expect(center.delivered.isEmpty)
    }

    @Test func foregroundAndDisabledEventsNeverRequestPermission() async throws {
        let center = TestGameNotificationCenter(), activity = NotificationTestActivity()
        activity.frontmost = true
        let model = try fixture(center, activity: activity)
        model.notify(.installFinished, gameID: "genshin")
        await model.notificationTask?.value
        activity.frontmost = false
        model.notificationsEnabled = false
        model.notify(.installFinished, gameID: "genshin")
        await model.notificationTask?.value
        #expect(center.requests == 0)
        #expect(center.delivered.isEmpty)
    }

    @Test func firstBackgroundEventRequestsPermissionAndRoutesOnlyKnownEditions() async throws {
        let center = TestGameNotificationCenter(), activity = NotificationTestActivity()
        let model = try fixture(center, activity: activity)
        model.notify(.installFinished, gameID: "genshin")
        model.notify(.repairFinished, gameID: "zzz")
        await model.notificationTask?.value
        #expect(center.requests == 1)
        #expect(model.notificationAuthorization == .allowed)
        #expect(center.delivered.map(\.gameID) == ["genshin", "zzz"])
        #expect(center.delivered.allSatisfy { !$0.title.isEmpty && !$0.body.contains("/") })
        center.onResponse?("starrail-cn")
        #expect(model.region == .mainlandChina)
        #expect(model.notificationSelection?.gameID == "starrail-cn")
        #expect(activity.reveals == 1)
        center.onResponse?("../../unknown")
        #expect(activity.reveals == 1)
        model.openNotificationSettings()
        #expect(activity.settingsOpened == 1)
    }

    @Test func deniedPermissionDoesNotSendOrRepeatedlyPrompt() async throws {
        let center = TestGameNotificationCenter()
        center.grant = false
        let model = try fixture(center)
        model.notify(.operationFailed, gameID: "genshin")
        model.notify(.pausedForSpace, gameID: "genshin")
        await model.notificationTask?.value
        #expect(center.requests == 1)
        #expect(model.notificationAuthorization == .denied)
        #expect(center.delivered.isEmpty)
        center.authorization = .allowed
        await model.refreshNotificationAuthorization()
        model.notify(.updateFinished, gameID: "genshin")
        await model.notificationTask?.value
        #expect(center.delivered.count == 1)
    }

    @Test func permissionSuspensionRechecksActivityAndSwitch() async throws {
        for disable in [false, true] {
            let center = TestGameNotificationCenter(), activity = NotificationTestActivity()
            let gate = AsyncStream<Void>.makeStream()
            let entered = AsyncStream<Void>.makeStream()
            center.requestPermission = {
                entered.continuation.yield(())
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            let model = try fixture(center, activity: activity)
            model.notify(.installFinished, gameID: "genshin")
            var iterator = entered.stream.makeAsyncIterator()
            _ = await iterator.next()
            if disable { model.notificationsEnabled = false } else { activity.frontmost = true }
            gate.continuation.yield(()); gate.continuation.finish()
            await model.notificationTask?.value
            #expect(center.delivered.isEmpty)
        }
    }

    @Test func availabilityPersistsByEditionVersionAndKindAcrossModels() async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TestGameNotificationCenter()
        let model = try fixture(center, root: root)
        for _ in 0..<2 { model.notify(.updateAvailable, gameID: "genshin", version: "2.0") }
        model.notify(.preDownloadAvailable, gameID: "genshin", version: "2.0")
        model.notify(.updateAvailable, gameID: "genshin-cn", version: "2.0")
        await model.notificationTask?.value
        #expect(center.delivered.count == 3)
        let restarted = try fixture(center, root: root)
        restarted.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        restarted.notify(.preDownloadAvailable, gameID: "genshin", version: "2.0")
        restarted.notify(.updateAvailable, gameID: "genshin-cn", version: "2.0")
        offer(restarted, kind: .updateAvailable, version: "3.0")
        restarted.notify(.updateAvailable, gameID: "genshin", version: "3.0")
        await restarted.notificationTask?.value
        #expect(center.delivered.count == 4)
    }

    @Test func foregroundAvailabilityRemainsEligibleAndFailedDeliveryCanRetry() async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TestGameNotificationCenter(), activity = NotificationTestActivity()
        activity.frontmost = true
        let model = try fixture(center, activity: activity, root: root)
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        activity.frontmost = false; center.failDelivery = true
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        center.failDelivery = false
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        #expect(center.delivered.count == 1)
    }

    @Test func durableAvailabilityDoesNotPromptAgainAfterAuthorizationReset() async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = TestGameNotificationCenter(), model = try fixture(first, root: root)
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        let reset = TestGameNotificationCenter(), restarted = try fixture(reset, root: root)
        restarted.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await restarted.notificationTask?.value
        #expect(reset.requests == 0)
        #expect(reset.delivered.isEmpty)
    }

    @Test(arguments: ["corrupt", "symlink", "directory", "oversized"])
    func invalidHistoryCannotAuthorizeRepeatedAvailability(kind: String) async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try ContainedFileSystem(root: root)
        let path = try SafeRelativePath("notification-history.json")
        switch kind {
        case "symlink":
            try fs.writeAtomically(Data("[]".utf8), to: SafeRelativePath("target.json"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("notification-history.json"), withDestinationURL: root.appendingPathComponent("target.json"))
        case "directory": try fs.createDirectory(at: path)
        case "oversized": try fs.writeAtomically(Data(repeating: 32, count: 1_048_577), to: path)
        default: try fs.writeAtomically(Data("broken".utf8), to: path)
        }
        let center = TestGameNotificationCenter(), model = try fixture(center, root: root)
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        #expect(center.delivered.isEmpty)
        #expect(center.requests == 0)
        // Ordinary completion is independent of availability metadata.
        model.notify(.installFinished, gameID: "genshin")
        await model.notificationTask?.value
        #expect(center.delivered.map(\.kind) == [.installFinished])
    }

    @Test func switchSurvivesRestartBeforeAvailabilityIsConsidered() async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-preference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TestGameNotificationCenter(), model = try fixture(center, root: root)
        model.notificationsEnabled = false
        try await model.flushLaunchSettings()
        let restarted = try fixture(center, root: root)
        await restarted.reattachOnStart()
        #expect(!restarted.notificationsEnabled)
        restarted.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        await restarted.notificationTask?.value
        #expect(center.requests == 0)
        #expect(center.delivered.isEmpty)
    }

    @Test(arguments: [false, true]) func dependencySetupWaitsForSuccessfulCatalogActivation(fails: Bool) async throws {
        let center = TestGameNotificationCenter()
        let manifest = try RuntimeManifest(components: [])
        let snapshot = try await RuntimeCatalogService(baseline: manifest).snapshot()
        let access = NotificationCatalogAccess(snapshot, fails: fails)
        let model = AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/notification-activation")),
            manifest: manifest, services: PreviewRuntimeServices(), catalogAccess: access, defaults: nil,
            notifications: center, notificationIsFrontmost: { false })
        model.catalogActivationTargets["genshin"] = snapshot
        model.runtimeCatalogMutationID = "setup"
        model.finishCatalogSetup("genshin", succeeded: true)
        let worker = try #require(model.catalogMutationTask)
        var entered = access.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        #expect(center.delivered.isEmpty)
        access.release.continuation.yield(()); access.release.continuation.finish()
        await worker.value; await model.notificationTask?.value
        #expect(center.delivered.map(\.kind) == (fails ? [] : [.dependencySetupFinished]))
    }

    @Test(arguments: [GameNotificationKind.updateAvailable, .preDownloadAvailable],
        ["completed", "newerOffer", "began", "withdrawn", "otherEdition", "installedRecord", "operation"])
    func authorizationWaitRejectsObsoleteAvailability(kind: GameNotificationKind, change: String) async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-obsolete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TestGameNotificationCenter(), model = try fixture(center, root: root)
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        center.requestPermission = {
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator(); _ = await iterator.next()
        }
        offer(model, kind: kind)
        model.notify(kind, gameID: "genshin", version: "2.0")
        var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        if change == "installedRecord" {
            model.setGameRecord("genshin", GameRecord(installPath: root.appendingPathComponent("Game"),
                ownership: .created, executable: try SafeRelativePath("Game.exe"),
                installed: InstalledBuild(tag: "3.0", buildID: "completed", categories: [], voices: []),
                installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1)))
        } else if change == "operation" {
            model.gameOperation = GameOperationToken(id: "genshin", generation: UUID())
        } else if kind == .updateAvailable {
            switch change {
            case "completed": model.setGameState("genshin", GameState(status: .installed(tag: "2.0")))
            case "newerOffer": offer(model, kind: kind, version: "3.0")
            case "began": model.setGameState("genshin", GameState(status: .updateAvailable(from: "1.0", to: "2.0"), activity: .resolving))
            case "otherEdition":
                model.setGameState("genshin", GameState(status: .notInstalled))
                offer(model, kind: kind, gameID: "genshin-cn")
            default: model.setGameState("genshin", GameState(status: .installed(tag: "1.0")))
            }
        } else {
            switch change {
            case "completed": model.preDownloads["genshin"] = PreDownloadOverlay(info: .init(state: .ready, version: "2.0"))
            case "newerOffer": offer(model, kind: kind, version: "3.0")
            case "began": model.preDownloads["genshin"]?.state = .downloading(PreDownloadProgress())
            case "otherEdition":
                model.preDownloads["genshin"] = PreDownloadOverlay()
                offer(model, kind: kind, gameID: "genshin-cn")
            default: model.preDownloads["genshin"] = PreDownloadOverlay()
            }
        }
        release.continuation.yield(()); release.continuation.finish()
        await model.notificationTask?.value
        #expect(center.delivered.isEmpty)
        // An obsolete event must not consume the same version's future eligibility.
        model.setGameRecord("genshin", nil); model.gameOperation = nil
        offer(model, kind: kind)
        model.notify(kind, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        #expect(center.delivered.map(\.kind) == [kind])
    }

    @Test(arguments: [GameNotificationKind.updateAvailable, .preDownloadAvailable])
    func queuedAvailabilityRechecksAfterPreviousDelivery(kind: GameNotificationKind) async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-queued-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TestGameNotificationCenter(), model = try fixture(center, root: root)
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        center.beforeDelivery = { _ in
            entered.continuation.yield(())
            var iterator = release.stream.makeAsyncIterator(); _ = await iterator.next()
        }
        model.notify(.installFinished, gameID: "zzz")
        var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        offer(model, kind: kind)
        model.notify(kind, gameID: "genshin", version: "2.0")
        model.setGameState("genshin", GameState(status: .notInstalled))
        model.preDownloads["genshin"] = PreDownloadOverlay()
        release.continuation.yield(()); release.continuation.finish()
        await model.notificationTask?.value
        #expect(center.delivered.map(\.kind) == [.installFinished])
    }

    @Test(arguments: [GameNotificationKind.updateAvailable, .preDownloadAvailable],
        [SuspendedNotificationHistory.Point.read, .claim])
    func historyWaitRevalidatesAvailabilityAndReleasesObsoleteClaims(kind: GameNotificationKind, point: SuspendedNotificationHistory.Point) async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-history-wait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SuspendedNotificationHistory(paths: AppPaths(root: root), point: point)
        let center = TestGameNotificationCenter()
        center.authorization = .allowed
        let model = try fixture(center, root: root, history: history)
        offer(model, kind: kind)
        model.notify(kind, gameID: "genshin", version: "2.0")
        var entered = history.entered.stream.makeAsyncIterator(); _ = await entered.next()
        offer(model, kind: kind, version: "3.0")
        history.releaseGate.continuation.yield(()); history.releaseGate.continuation.finish()
        await model.notificationTask?.value
        #expect(center.delivered.isEmpty)
        let receipt = GameNotificationHistory.Marker(gameID: "genshin", version: "2.0", kind: kind)
        #expect(try await !history.contains(receipt))
        offer(model, kind: kind)
        model.notify(kind, gameID: "genshin", version: "2.0")
        await model.notificationTask?.value
        #expect(center.delivered.map(\.kind) == [kind])
    }

    @Test func regionSwitchDoesNotInvalidateAnUnchangedEditionOffer() async throws {
        let root = URL(fileURLWithPath: "/tmp/macgacha-notification-region-wait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SuspendedNotificationHistory(paths: AppPaths(root: root), point: .claim)
        let center = TestGameNotificationCenter()
        center.authorization = .allowed
        let model = try fixture(center, root: root, history: history)
        model.notify(.updateAvailable, gameID: "genshin", version: "2.0")
        var entered = history.entered.stream.makeAsyncIterator(); _ = await entered.next()
        model.region = .mainlandChina
        history.releaseGate.continuation.yield(()); history.releaseGate.continuation.finish()
        await model.notificationTask?.value
        #expect(center.delivered.map(\.gameID) == ["genshin"])
        #expect(model.region == .mainlandChina)
    }

    private func offer(_ model: AppModel, kind: GameNotificationKind, gameID: String = "genshin", version: String = "2.0") {
        if kind == .updateAvailable {
            model.setGameState(gameID, GameState(status: .updateAvailable(from: "1.0", to: version)))
        } else {
            model.setGameState(gameID, GameState(status: .installed(tag: "1.0")))
            model.preDownloads[gameID] = PreDownloadOverlay(info: .init(state: .available, version: version))
        }
    }

    private func fixture(_ center: TestGameNotificationCenter, activity: NotificationTestActivity = NotificationTestActivity(), root: URL? = nil, history: (any GameNotificationHistoryAccess)? = nil) throws -> AppModel {
        let model = AppModel(paths: AppPaths(root: root ?? URL(fileURLWithPath: "/tmp/macgacha-inert-notifications-\(UUID())")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            notifications: center, notificationHistory: history, notificationIsFrontmost: { activity.frontmost },
            notificationReveal: { activity.reveals += 1 }, notificationSettings: { activity.settingsOpened += 1 })
        for id in ["genshin", "genshin-cn"] {
            offer(model, kind: .updateAvailable, gameID: id)
            model.preDownloads[id] = PreDownloadOverlay(info: .init(state: .available, version: "2.0"))
        }
        return model
    }
}

@MainActor final class NotificationTestActivity {
    var frontmost = false
    var reveals = 0
    var settingsOpened = 0
}

@MainActor final class TestGameNotificationCenter: GameNotificationCenter {
    var onResponse: (@MainActor @Sendable (String) -> Void)?
    var authorization: GameNotificationAuthorization = .notDetermined
    var grant = true
    var requests = 0
    var delivered: [GameNotification] = []
    var failDelivery = false
    var requestPermission: (() async -> Void)?
    var beforeDelivery: ((GameNotification) async -> Void)?
    func authorizationState() async -> GameNotificationAuthorization { authorization }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        await requestPermission?()
        authorization = grant ? .allowed : .denied
        return grant
    }
    func deliver(_ notification: GameNotification) async throws {
        await beforeDelivery?(notification)
        if failDelivery { throw LauncherError.io("Private /path must never be sent") }
        delivered.append(notification)
    }
}

private actor NotificationCatalogAccess: RuntimeCatalogAccess {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    private let value: RuntimeCatalogSnapshot
    private let fails: Bool
    init(_ value: RuntimeCatalogSnapshot, fails: Bool) { self.value = value; self.fails = fails }
    func snapshot() async throws -> RuntimeCatalogSnapshot { value }
    func persistSelection() async throws -> RuntimeCatalogSnapshot { value }
    func refresh(force: Bool) async throws -> RuntimeCatalogSnapshot { value }
    func activate(_ selections: RuntimeCatalogSelections) async throws -> RuntimeCatalogSnapshot {
        entered.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        _ = await iterator.next()
        if fails { throw LauncherError.io("Activation failed") }
        return value
    }
}

actor SuspendedNotificationHistory: GameNotificationHistoryAccess {
    enum Point: Sendable { case read, claim }
    let entered = AsyncStream<Void>.makeStream()
    let releaseGate = AsyncStream<Void>.makeStream()
    private let store: GameNotificationHistory
    private let point: Point
    init(paths: AppPaths, point: Point) { store = GameNotificationHistory(paths: paths); self.point = point }
    func contains(_ marker: GameNotificationHistory.Marker) async throws -> Bool {
        if point == .read { await wait() }
        let store = self.store
        return try await BlockingIO.run { try store.contains(marker) }
    }
    func claim(_ marker: GameNotificationHistory.Marker) async throws -> Bool {
        let store = self.store
        let result = try await BlockingIO.run { try store.claim(marker) }
        if result && point == .claim { await wait() }
        return result
    }
    func release(_ marker: GameNotificationHistory.Marker) async throws {
        let store = self.store
        try await BlockingIO.run { try store.release(marker) }
    }
    private func wait() async {
        entered.continuation.yield(())
        var iterator = releaseGate.stream.makeAsyncIterator(); _ = await iterator.next()
    }
}
