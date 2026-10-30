// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
import HoYoPlayAPI
@testable import MacGacha

@Suite @MainActor struct GameEventsModelTests {
    @Test func visibleRegionUsesItsCacheAndRefreshesIndependentlyFromArt() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let global = ModelEvents(region: .global, date: date), cn = ModelEvents(region: .mainlandChina, date: date)
        let model = try model(global: global, cn: cn, now: { date })
        await model.loadGameArt()
        await model.eventsTasks[model.region]?.value
        #expect(model.gameEvents["genshin"]?.first?.title == "fresh")
        #expect(global.refreshes == 1 && cn.refreshes == 0)
        #expect(cn.hydrations == 1)
        model.region = .mainlandChina
        #expect(model.gameEvents["genshin"] == nil)
        #expect(model.gameEvents["genshin-cn"]?.first?.title == "cached")
        await model.loadGameArt()
        await model.eventsTasks[model.region]?.value
        #expect(model.gameEvents["genshin-cn"]?.first?.title == "fresh")
    }

    @Test func runningModelExpiresWithoutPollingOrAnotherNetworkRequest() async throws {
        let clock = ModelEventsClock(), provider = ModelEvents(region: .global, date: clock.now)
        let model = try model(global: provider, now: { clock.now }, sleep: { try await clock.sleep($0) })
        await model.loadGameArt()
        await model.eventsTasks[model.region]?.value
        await clock.scheduled.wait()
        #expect(model.gameEvents["genshin"]?.isEmpty == false)
        #expect(clock.delay == .seconds(24 * 3600))
        let expiry = try #require(model.eventsExpiryTask)
        clock.advance(24 * 3600)
        await clock.release.signal()
        await expiry.value
        #expect(model.gameEvents.isEmpty)
        #expect(provider.refreshes == 1)
        #expect(model.eventsExpiryTask == nil)
    }

    @Test func revealAndActivationRevalidationRemoveExpiredEvents() async throws {
        let clock = ModelEventsClock(), provider = ModelEvents(region: .global, date: clock.now)
        let model = try model(global: provider, now: { clock.now }, sleep: { try await clock.sleep($0) })
        await model.loadGameArt()
        await model.eventsTasks[model.region]?.value
        clock.advance(24 * 3600)
        model.revalidateGameEvents()
        #expect(model.gameEvents.isEmpty)
        #expect(provider.refreshes == 1)
        await clock.release.signal()
    }

    @Test func lateOldRegionRefreshCannotReplaceVisibleEvents() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000), entered = EventsSignal(), release = EventsSignal()
        let global = ModelEvents(region: .global, date: date, entered: entered, release: release)
        let cn = ModelEvents(region: .mainlandChina, date: date)
        let model = try model(global: global, cn: cn, now: { date })
        let pending = Task { await model.loadGameEvents() }
        await entered.wait()
        model.region = .mainlandChina
        await model.loadGameEvents()
        let visible = model.gameEvents
        await release.signal(); await pending.value
        #expect(model.gameEvents == visible)
        #expect(model.gameEvents["genshin"] == nil)
        model.region = .global
        #expect(model.gameEvents["genshin"]?.first?.title == "fresh")
    }

    @Test(.timeLimit(.minutes(1))) func slowEventsDoNotHoldUpArtCompletion() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000), entered = EventsSignal(), release = EventsSignal()
        let global = ModelEvents(region: .global, date: date, entered: entered, release: release)
        let model = try model(global: global, now: { date })
        // Cancellation is only a failure bound. Success requires art completion
        // while the Events response is still held by this explicit handshake.
        await withTaskCancellationHandler {
            await model.loadGameArt()
        } onCancel: { Task { await release.signal() } }
        #expect(!Task.isCancelled)
        await entered.wait()
        #expect(model.gameEvents["genshin"]?.first?.title == "cached")
        let pending = model.eventsTasks[.global]
        await release.signal(); await pending?.value
        #expect(model.gameEvents["genshin"]?.first?.title == "fresh")
    }

    @Test func startHydratesBothCachesWithoutFetchingEitherRegion() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let global = ModelEvents(region: .global, date: date, initiallyEmpty: true)
        let cn = ModelEvents(region: .mainlandChina, date: date, initiallyEmpty: true)
        let model = try model(global: global, cn: cn, now: { date })
        #expect(model.gameEvents.isEmpty)
        await model.start()
        #expect(model.gameEvents["genshin"]?.first?.title == "cached")
        #expect(global.hydrations == 1 && cn.hydrations == 1)
        #expect(global.refreshes == 0 && cn.refreshes == 0)
        model.regionLoadingEnabled = false
        model.region = .mainlandChina
        #expect(model.gameEvents["genshin-cn"]?.first?.title == "cached")
    }

    private func model(global: any GameEventsProviding, cn: any GameEventsProviding = EmptyGameEventsProvider(),
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws -> AppModel {
        AppModel(paths: AppPaths(root: URL(fileURLWithPath: "/inert/EventsModel")), manifest: try RuntimeManifest(components: []),
            services: PreviewRuntimeServices(), defaults: nil, eventsServices: [.global: global, .mainlandChina: cn],
            locale: Locale(identifier: "en_US"), eventsNow: now, eventsSleep: sleep)
    }
}

private final class ModelEvents: GameEventsProviding, Sendable {
    let region: Region, date: Date
    let entered: EventsSignal?, release: EventsSignal?, initiallyEmpty: Bool
    private let counts = Mutex((hydrations: 0, refreshes: 0))
    var hydrations: Int { counts.withLock { $0.hydrations } }
    var refreshes: Int { counts.withLock { $0.refreshes } }
    init(region: Region, date: Date, entered: EventsSignal? = nil, release: EventsSignal? = nil, initiallyEmpty: Bool = false) {
        self.region = region; self.date = date; self.entered = entered; self.release = release; self.initiallyEmpty = initiallyEmpty
    }
    func cached() -> [String: GameEventsSnapshot] { initiallyEmpty && hydrations == 0 ? [:] : value("cached") }
    func loadCached() async -> [String: GameEventsSnapshot] { counts.withLock { $0.hydrations += 1 }; return cached() }
    func refresh() async -> [String: GameEventsSnapshot] {
        counts.withLock { $0.refreshes += 1 }; await entered?.signal(); await release?.wait()
        return value("fresh")
    }
    private func value(_ title: String) -> [String: GameEventsSnapshot] {
        [region == .global ? "genshin" : "genshin-cn": GameEventsSnapshot(posts: [GameEvent(title: title, date: "10/22", link: nil)],
            region: region, language: region == .global ? .enUS : .zhCN, fetchedAt: date)]
    }
}

private actor EventsSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !signaled { await withCheckedContinuation { waiters.append($0) } } }
    func signal() { signaled = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private final class ModelEventsClock: Sendable {
    let scheduled = EventsSignal(), release = EventsSignal()
    private let state = Mutex((now: Date(timeIntervalSince1970: 1_800_000_000), delay: Duration?.none))
    var now: Date { state.withLock { $0.now } }
    var delay: Duration? { state.withLock { $0.delay } }
    func advance(_ seconds: TimeInterval) { state.withLock { $0.now.addTimeInterval(seconds) } }
    func sleep(_ duration: Duration) async throws {
        state.withLock { $0.delay = duration }
        await scheduled.signal(); await release.wait()
        try Task.checkCancellation()
    }
}
