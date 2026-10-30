// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import HoYoPlayAPI
@testable import MacGacha

@MainActor struct BackgroundSelectionTests {
    private let a = GameBackground(id: "a", image: URL(fileURLWithPath: "/tmp/a.png"),
        highlights: GameHighlights(image: URL(fileURLWithPath: "/tmp/a-icon.png"), link: URL(string: "https://hoyo.link/a")))
    private let b = GameBackground(id: "b", image: URL(fileURLWithPath: "/tmp/b.png"))

    @Test func rotationPointerEntryAndDotClicks() throws {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: true, reduceMotion: false)
        #expect(model.slides?.current == a && model.slides?.dotIDs == ["a", "b"])
        let first = try #require(model.rotation)
        clock.advance(by: .seconds(6)); model.advance(if: first)
        #expect(model.slides?.current.id == "a")
        clock.advance(by: .seconds(1)); model.advance(if: first)
        #expect(model.slides?.current == b)
        model.pointerEnteredDots()
        #expect(!model.userAllowsAuto && model.rotation == nil)
        model.clickDot("b")
        #expect(model.userAllowsAuto && model.rotation != nil)
        model.clickDot("a")
        #expect(model.slides?.current == a && !model.userAllowsAuto && model.rotation == nil)
        model.clickDot("a")
        #expect(model.userAllowsAuto)
        let resumed = try #require(model.rotation)
        #expect(clock.now.duration(to: resumed.deadline) == .seconds(7))
        model.advance(if: first)
        #expect(model.slides?.current == a)
    }

    @Test func inactiveRefreshAndReduceMotionNeverReenableAuto() throws {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: false, reduceMotion: true)
        #expect(!model.userAllowsAuto && !model.allowsCrossfade && model.rotation == nil)
        model.clickDot("b")
        model.update(region: .global, gameID: "genshin", backgrounds: [b, a], animated: false, reduceMotion: true)
        #expect(model.slides?.current == b && !model.userAllowsAuto)
        model.clickDot("b")
        model.setWindow(active: false, visible: true)
        #expect(model.userAllowsAuto && !model.canAutoAdvance && model.rotation == nil)
        clock.advance(by: .seconds(100))
        model.setWindow(active: true, visible: true)
        #expect(clock.now.duration(to: try #require(model.rotation).deadline) == .seconds(7))
        model.pointerEnteredDots()
        model.setWindow(active: true, visible: false)
        model.setWindow(active: true, visible: true)
        #expect(model.rotation == nil)
        model.update(region: .global, gameID: "genshin", backgrounds: [a], animated: false, reduceMotion: false)
        #expect(model.slides?.current == a && model.slides?.dotIDs == [] && model.rotation == nil)
        model.update(region: .global, gameID: "starrail", backgrounds: [a, b], animated: false, reduceMotion: false)
        #expect(model.userAllowsAuto && model.slides?.current == a)
    }

    @Test func videoFailureIsSourceScopedAndOldGenerationsAreIgnored() throws {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock)
        let video = GameBackground(id: "movie", image: a.image, video: URL(fileURLWithPath: "/tmp/video.webm"), theme: b.image, highlights: a.highlights)
        model.update(region: .global, gameID: "starrail", backgrounds: [a, video, b], animated: true, reduceMotion: false)
        let token = try #require(model.video?.token)
        #expect(model.video?.state == .preparing && model.slides == nil && model.rotation == nil)
        model.setPlaybackState(.playing, for: token)
        #expect(model.video?.state == .playing)
        model.setPlaybackState(.failed, for: token)
        #expect(model.video == nil && model.slides?.dotIDs.count == 3)
        #expect(model.slides?.current.highlights == video.highlights)
        model.update(region: .mainlandChina, gameID: "starrail-cn", backgrounds: [video], animated: true, reduceMotion: false)
        #expect(model.video?.state == .preparing)
        model.setPlaybackState(.failed, for: token)
        #expect(model.video != nil)
        let old = try #require(model.video?.token)
        model.update(region: .mainlandChina, gameID: "starrail-cn", backgrounds: [video], animated: true, reduceMotion: false)
        model.setPlaybackState(.failed, for: old)
        #expect(model.video != nil)
        model.update(region: .mainlandChina, gameID: "starrail-cn", backgrounds: [video], animated: false, reduceMotion: false)
        #expect(model.video == nil && model.slides?.dotIDs == [] && model.rotation == nil)
    }

    @Test func missingStillsAndStaleImageTokens() throws {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock)
        model.update(region: .global, gameID: "genshin", backgrounds: [GameBackground(id: "empty", image: nil)], animated: false, reduceMotion: false)
        #expect(model.slides == nil && model.video == nil && model.rotation == nil)
        model.update(region: .global, gameID: "genshin", backgrounds: [a, b], animated: false, reduceMotion: false)
        let content = model.contentGeneration
        model.clickDot("b")
        #expect(model.contentGeneration != content)
        model.update(region: .global, gameID: "genshin", backgrounds: [a], animated: false, reduceMotion: false)
        #expect(model.slides?.current.id == "a" && !model.userAllowsAuto)
    }
}

@MainActor struct BackgroundSourceRefreshTests {
    @Test func replacementAssetRetriesAndRefreshRejectsOldTimerAndCallback() throws {
        let clock = NativeWindowClock()
        var model = BackgroundSelection(clock: clock)
        let first = GameBackground(id: "one", image: URL(fileURLWithPath: "/tmp/a.png"), video: URL(fileURLWithPath: "/tmp/one.webm"))
        let second = GameBackground(id: "two", image: URL(fileURLWithPath: "/tmp/b.png"))
        model.update(region: .global, gameID: "zzz", backgrounds: [first, second], animated: true, reduceMotion: false)
        let failed = try #require(model.video?.token)
        model.setPlaybackState(.failed, for: failed)
        model.setPlaybackState(.playing, for: failed)
        #expect(model.video == nil)
        let timer = try #require(model.rotation)
        model.update(region: .global, gameID: "zzz", backgrounds: [first, second], animated: true, reduceMotion: false)
        #expect(model.video == nil)
        clock.advance(by: .seconds(7)); model.advance(if: timer)
        #expect(model.slides?.current.id == "one")
        let replacement = GameBackground(id: "one", image: first.image, video: URL(fileURLWithPath: "/tmp/replaced.webm"))
        model.update(region: .global, gameID: "zzz", backgrounds: [replacement, second], animated: true, reduceMotion: false)
        #expect(model.video?.state == .preparing)
        model.setPlaybackState(.failed, for: failed)
        #expect(model.video?.state == .preparing)
    }
}
