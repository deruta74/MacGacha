// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import HoYoPlayAPI
@testable import MacGacha

@Suite @MainActor struct BackgroundSelectionTests {
    private let a = GameBackground(id: "a", image: URL(fileURLWithPath: "/tmp/a.png"))
    private let b = GameBackground(id: "b", image: URL(fileURLWithPath: "/tmp/b.png"))
    private var movie: GameBackground { GameBackground(id: "movie", image: URL(fileURLWithPath: "/tmp/movie.png"),
        video: URL(fileURLWithPath: "/tmp/movie.webm"), theme: URL(fileURLWithPath: "/tmp/theme.png"),
        highlights: GameHighlights(image: URL(fileURLWithPath: "/tmp/icon.png"))) }

    @Test func firstShowSelectsNextAfterSavedAndWraps() {
        for (saved, expected) in [("a", "movie"), ("movie", "b"), ("b", "a")] {
            let store = MemoryBackgroundSelectionStore(["genshin": saved])
            var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: store))
            model.update(region: .global, gameID: "genshin", backgrounds: [a, movie, b], animated: true, reduceMotion: false)
            #expect(model.slides?.current.id == expected)
            #expect(store.values["genshin"] == expected)
        }
    }
    @Test func missingOrAbsentSavedEntryStartsAtFirst() {
        for values in [[:], ["genshin": "gone"]] {
            var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore(values)))
            model.update(region: .global, gameID: "genshin", backgrounds: [a, movie, b], animated: true, reduceMotion: false)
            #expect(model.slides?.current == a && model.video == nil)
        }
    }
    @Test func returningAndRemountingWithinSessionKeepsSelection() {
        let session = BackgroundSelectionSession(store: MemoryBackgroundSelectionStore())
        var model = BackgroundSelection(clock: NativeWindowClock(), session: session)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        model.clickDot("b")
        model.update(region: .global, gameID: "zzz", backgrounds: [a, b], animated: true, reduceMotion: false)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == b)
        var remounted = BackgroundSelection(clock: NativeWindowClock(), session: session)
        remounted.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(remounted.slides?.current == b)
    }
    @Test func eachSelectionPersistsAndEditionsStaySeparate() {
        let store = MemoryBackgroundSelectionStore(), session = BackgroundSelectionSession(store: store)
        var model = BackgroundSelection(clock: NativeWindowClock(), session: session)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        model.clickDot("b"); model.clickDot("b"); model.clickDot("missing")
        #expect(store.writes == ["genshin:a", "genshin:b"])
        model.update(region: .mainlandChina, gameID: "genshin-cn", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == a)
        #expect(store.values == ["genshin": "b", "genshin-cn": "a"])
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == b && store.writes.count == 3)
    }
    @Test func defaultsPersistenceSurvivesNewSessionUsingStableIDs() throws {
        let domain = "background-selection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var first = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: UserDefaultsBackgroundSelectionStore(defaults: defaults)))
        first.update(region: .global, gameID: "genshin", backgrounds: [a, movie, b], animated: true, reduceMotion: false)
        first.clickDot("movie")
        var next = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: UserDefaultsBackgroundSelectionStore(defaults: defaults)))
        let replacedImage = GameBackground(id: movie.id, image: URL(fileURLWithPath: "/tmp/refreshed-cache/movie.png"))
        next.update(region: .global, gameID: "genshin", backgrounds: [a, replacedImage, b], animated: true, reduceMotion: false)
        #expect(next.slides?.current == b)
    }
    @Test func videoStaysInServerOrderAndFailureKeepsItsStillAndTheme() throws {
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore()))
        model.update(region: .global, gameID: "starrail", backgrounds: [a, movie, b], animated: true, reduceMotion: false)
        #expect(model.slides?.dotIDs == ["a", "movie", "b"] && model.slides?.current == a && model.video == nil)
        model.clickDot("movie")
        let token = try #require(model.video?.token)
        #expect(model.slides?.current == movie && model.theme == movie.theme && model.video?.state == .preparing)
        model.setPlaybackState(.playing, for: token)
        #expect(model.theme == movie.theme)
        model.setPlaybackState(.failed, for: token)
        #expect(model.video == nil && model.slides?.current == movie && model.theme == movie.theme)
        #expect(model.slides?.dotIDs == ["a", "movie", "b"])
        #expect(model.slides?.current.highlights == movie.highlights)
    }
    @Test func emptyArtDoesNotConsumeFirstVisit() {
        let store = MemoryBackgroundSelectionStore(["genshin": "a"])
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: store))
        model.update(region: .global, gameID: "genshin", backgrounds: [], animated: true, reduceMotion: false)
        #expect(model.slides == nil && store.writes.isEmpty)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == b)
    }
    @Test func failedAndMissingStillsAreExcludedFromSelectionAndDots() throws {
        let store = MemoryBackgroundSelectionStore(["genshin": "movie"])
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: store))
        model.update(region: .global, gameID: "genshin", backgrounds: [a, GameBackground(id: "missing", image: nil), movie, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == b)
        model.setStillImageFailed(try #require(b.image))
        #expect(model.slides?.current == a && model.slides?.dotIDs == ["a", "movie"])
        model.setStillImageFailed(try #require(a.image))
        #expect(model.slides?.current == movie && model.slides?.dotIDs == [])
        model.setStillImageFailed(try #require(movie.image))
        #expect(model.slides == nil && model.video == nil)
        let replacement = GameBackground(id: "a", image: URL(fileURLWithPath: "/tmp/new-a.png"))
        model.update(region: .global, gameID: "genshin", backgrounds: [replacement], animated: true, reduceMotion: false)
        #expect(model.slides?.current == replacement)
    }
    @Test func singleBackgroundHasNoDotsAndAnimationDoesNotChangeSelection() {
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore()))
        for (animated, reduced) in [(true, false), (false, false), (true, true)] {
            model.update(region: .global, gameID: "genshin", backgrounds: [movie], animated: animated, reduceMotion: reduced)
            #expect(model.slides?.dotIDs == [] && model.slides?.current == movie && model.theme == movie.theme)
            #expect((model.video != nil) == (animated && !reduced))
            #expect(model.allowsCrossfade == !reduced)
        }
    }
    @Test func elapsedTimeAndWindowChangesNeverRotateSelection() {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock, session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore()))
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        clock.advance(by: .seconds(3600))
        model.setWindow(active: false, visible: false); model.setWindow(active: true, visible: true)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == a && clock.activeSleeps == 0)
    }
    @Test func windowStateOnlyPausesVideo() throws {
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore()))
        model.update(region: .global, gameID: "genshin", backgrounds: [movie, b], animated: true, reduceMotion: false)
        let token = try #require(model.video?.token)
        model.setPlaybackState(.playing, for: token)
        model.setWindow(active: false, visible: true)
        #expect(model.video?.isPaused == true && model.slides?.current == movie && model.video?.token == token)
        model.setWindow(active: true, visible: false)
        #expect(model.video?.isPaused == true)
        model.setWindow(active: true, visible: true)
        #expect(model.video?.isPaused == false && model.video?.token == token)
    }
    @Test func staleVideoCallbacksCannotAffectAnotherSelectionOrNewSource() throws {
        var model = BackgroundSelection(clock: NativeWindowClock(), session: BackgroundSelectionSession(store: MemoryBackgroundSelectionStore()))
        model.update(region: .global, gameID: "genshin", backgrounds: [movie, b], animated: true, reduceMotion: false)
        let original = try #require(model.video?.token)
        model.setPlaybackState(.playing, for: original)
        model.update(region: .global, gameID: "genshin", backgrounds: [movie, b], animated: true, reduceMotion: false)
        #expect(model.video?.token == original && model.video?.state == .playing)
        model.clickDot("b"); model.clickDot("movie")
        #expect(model.video?.token != original && model.video?.state == .preparing)
        model.setPlaybackState(.failed, for: original)
        #expect(model.video?.state == .preparing)
        let current = try #require(model.video?.token)
        model.setPlaybackState(.failed, for: current); model.setPlaybackState(.playing, for: current)
        #expect(model.video == nil && model.slides?.current == movie)
        let replacement = GameBackground(id: movie.id, image: movie.image, video: URL(fileURLWithPath: "/tmp/new-video.webm"))
        model.update(region: .global, gameID: "genshin", backgrounds: [replacement, b], animated: true, reduceMotion: false)
        #expect(model.video?.state == .preparing)
        model.setPlaybackState(.failed, for: current)
        #expect(model.video?.state == .preparing)
        let old = try #require(model.video?.token)
        model.update(region: .mainlandChina, gameID: "genshin-cn", backgrounds: [replacement, b], animated: true, reduceMotion: false)
        model.setPlaybackState(.failed, for: old)
        #expect(model.video?.state == .preparing)
    }
}

@MainActor private final class MemoryBackgroundSelectionStore: BackgroundSelectionStore {
    var values: [String: String]
    var writes: [String] = []
    init(_ values: [String: String] = [:]) { self.values = values }
    func lastShownID(for gameID: String) -> String? { values[gameID] }
    func setLastShownID(_ id: String, for gameID: String) { values[gameID] = id; writes.append("\(gameID):\(id)") }
}
