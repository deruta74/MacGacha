// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
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

    private func fixture(_ center: TestGameNotificationCenter, activity: NotificationTestActivity = NotificationTestActivity(), root: URL? = nil) throws -> AppModel {
        AppModel(paths: AppPaths(root: root ?? URL(fileURLWithPath: "/tmp/macgacha-inert-notifications-\(UUID())")),
            manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil,
            notifications: center, notificationIsFrontmost: { activity.frontmost },
            notificationReveal: { activity.reveals += 1 }, notificationSettings: { activity.settingsOpened += 1 })
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
    func authorizationState() async -> GameNotificationAuthorization { authorization }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        await requestPermission?()
        authorization = grant ? .allowed : .denied
        return grant
    }
    func deliver(_ notification: GameNotification) async throws {
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
