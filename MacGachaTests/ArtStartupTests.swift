// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import HoYoPlayAPI
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct ArtStartupTests {
    @Test func cacheHitRevealsBeforeRefreshFinishes() async throws {
        let fixture = try StartupArtFixture(cached: true)
        defer { fixture.remove() }
        let model = fixture.model
        #expect(model.artCacheState == .notChecked)
        model.startArtStartup()
        await fixture.provider.entered.wait()
        #expect(model.artCacheState == .usable)
        #expect(model.launcherRevealed)
        await fixture.provider.finish.signal()
        await model.artStartupTask?.value
    }

    @Test func alreadyHydratedCacheRevealsSynchronouslyAtStartup() async throws {
        let fixture = try StartupArtFixture(cached: true)
        defer { fixture.remove() }
        let load = Task { await fixture.model.loadGameArt() }
        await fixture.provider.entered.wait()
        fixture.model.startArtStartup()
        #expect(fixture.model.launcherRevealed)
        await fixture.provider.finish.signal()
        await load.value
        await fixture.model.artStartupTask?.value
    }

    @Test(arguments: [true, false]) func fastRefreshReveals(success: Bool) async throws {
        let fixture = try StartupArtFixture(cached: false, success: success)
        defer { fixture.remove() }
        fixture.model.startArtStartup()
        await fixture.provider.entered.wait()
        #expect(fixture.model.artCacheState == .none)
        #expect(!fixture.model.launcherRevealed)
        await fixture.provider.finish.signal()
        await fixture.model.artStartupTask?.value
        #expect(fixture.model.launcherRevealed)
        #expect((fixture.model.gameArt["genshin"]?.background != nil) == success)
    }

    @Test func timeoutDoesNotCancelRefreshAndLateArtUpdates() async throws {
        let fixture = try StartupArtFixture(cached: false)
        defer { fixture.remove() }
        let model = fixture.model
        model.startArtStartup()
        await fixture.provider.entered.wait()
        await fixture.clock.waitForSleep(.seconds(8))
        fixture.clock.advance(by: .seconds(8))
        await model.artRevealTask?.value
        #expect(model.launcherRevealed)
        #expect(model.gameArt["genshin"]?.background == nil)
        await fixture.provider.finish.signal()
        await model.artStartupTask?.value
        #expect(model.gameArt["genshin"]?.background == fixture.image)
        #expect(model.launcherRevealed)
    }

    @Test func timeoutStartsBeforeHydrationCompletesAndNotCheckedIsDistinct() async throws {
        let fixture = try StartupArtFixture(cached: false, delayHydration: true)
        defer { fixture.remove() }
        fixture.model.startArtStartup()
        fixture.model.startArtStartup()
        await fixture.provider.hydrationEntered.wait()
        #expect(fixture.model.artCacheState == .notChecked)
        await fixture.clock.waitForSleep(.seconds(8))
        fixture.clock.advance(by: .seconds(8))
        await fixture.model.artRevealTask?.value
        #expect(fixture.model.launcherRevealed)
        await fixture.provider.hydrationFinish.signal()
        await fixture.provider.entered.wait()
        await fixture.provider.finish.signal()
        await fixture.model.artStartupTask?.value
        #expect(fixture.model.gameArt["genshin"]?.background == fixture.image)
    }

    @Test func modelStartStartsArtWithoutLauncherContent() async throws {
        let fixture = try StartupArtFixture(cached: false)
        defer { fixture.remove() }
        await fixture.model.start()
        await fixture.provider.entered.wait()
        #expect(!fixture.model.launcherRevealed)
        await fixture.provider.finish.signal()
        await fixture.model.artStartupTask?.value
        #expect(fixture.model.launcherRevealed)
    }

    @Test func nonexistentSnapshotIsNotUsableCache() async throws {
        let fixture = try StartupArtFixture(cached: true)
        fixture.remove()
        fixture.model.startArtStartup()
        await fixture.provider.entered.wait()
        #expect(fixture.model.artCacheState == .none)
        #expect(!fixture.model.launcherRevealed)
        await fixture.provider.finish.signal()
        await fixture.model.artStartupTask?.value
    }
}

private struct StartupArtFixture {
    let root: URL
    let image: URL
    let clock = NativeWindowClock()
    let provider: StartupArtProvider
    let model: AppModel
    @MainActor init(cached: Bool, success: Bool = true, delayHydration: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtStartup-\(UUID())")
        let fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("art"))
        try fs.writeAtomically(Data([1]), to: SafeRelativePath("art/image.png"))
        image = root.appendingPathComponent("art/image.png")
        provider = StartupArtProvider(image: image, hasCache: cached, success: success, delayHydration: delayHydration)
        model = AppModel(paths: AppPaths(root: root), services: FakeRuntimeServices(), defaults: nil,
            artService: provider, locale: Locale(identifier: "en_US"), artClock: clock)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private struct StartupArtProvider: GameArtProviding {
    let image: URL
    let hasCache: Bool
    let success: Bool
    let delayHydration: Bool
    let hydrationEntered = ArtSignal(), hydrationFinish = ArtSignal()
    let entered = ArtSignal(), finish = ArtSignal()
    func cached() -> [String: GameArt] { hasCache ? ["genshin": GameArt(background: image)] : [:] }
    func loadCached() async -> [String: GameArt] {
        await hydrationEntered.signal()
        if delayHydration { await hydrationFinish.wait() }
        return cached()
    }
    func refresh() async -> [String: GameArt] {
        await entered.signal(); await finish.wait()
        return success ? ["genshin": GameArt(background: image)] : [:]
    }
}
private actor ArtSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
