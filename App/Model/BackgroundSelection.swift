// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import HoYoPlayAPI
import LauncherCore

enum BackgroundPlaybackState: Sendable, Equatable { case preparing, playing, failed }

struct BackgroundVideoSource: Sendable, Hashable {
    let region: Region
    let gameID: String
    let backgroundID: String
    let assetURL: URL
}

/// Pass this token back with decoder callbacks; the same URL in another edition
/// or a refreshed player is a different callback owner.
struct BackgroundVideoToken: Sendable, Hashable {
    let source: BackgroundVideoSource
    let generation: UUID
}

struct BackgroundSlides: Sendable, Equatable {
    let current: GameBackground
    let dotIDs: [String]
    let userAllowsAuto: Bool
    let canAutoAdvance: Bool
}

struct BackgroundVideo: Sendable, Equatable {
    let background: GameBackground
    let token: BackgroundVideoToken
    let state: BackgroundPlaybackState
}

/// No tasks or view lifetime. The caller sleeps until rotation.deadline on the
/// same clock, then returns that exact token to advance(if:).
struct BackgroundSelection<C: Clock> where C.Duration == Duration {
    struct Rotation: Hashable, Sendable {
        let generation: UUID
        let deadline: C.Instant
    }

    private let clock: C
    private var region: Region?
    private var gameID: String?
    private var backgrounds: [GameBackground] = []
    private var animated = false
    private var reduceMotion = false
    private var windowActive = true
    private var windowVisible = true
    private var currentID: String?
    private var generation = UUID()
    private var playback: [BackgroundVideoSource: BackgroundPlaybackState] = [:]
    private(set) var contentGeneration = UUID()
    private(set) var userAllowsAuto = true
    private(set) var rotation: Rotation?

    init(clock: C) { self.clock = clock }

    var allowsCrossfade: Bool { !reduceMotion }
    private var stills: [GameBackground] { backgrounds.filter { $0.image != nil } }
    private var videoCandidate: (GameBackground, BackgroundVideoSource)? {
        guard animated, let region, let gameID,
            let background = backgrounds.first(where: { $0.video != nil }), let url = background.video else { return nil }
        return (background, BackgroundVideoSource(region: region, gameID: gameID, backgroundID: background.id, assetURL: url))
    }
    var video: BackgroundVideo? {
        guard let (background, source) = videoCandidate, playback[source] != .failed else { return nil }
        return BackgroundVideo(background: background, token: BackgroundVideoToken(source: source, generation: generation),
            state: playback[source] ?? .preparing)
    }
    var slides: BackgroundSlides? {
        guard video == nil, let current = stills.first(where: { $0.id == currentID }) ?? stills.first else { return nil }
        return BackgroundSlides(current: current, dotIDs: stills.count > 1 ? stills.map(\.id) : [],
            userAllowsAuto: userAllowsAuto, canAutoAdvance: canAutoAdvance)
    }
    var canAutoAdvance: Bool { video == nil && stills.count > 1 && userAllowsAuto && windowActive && windowVisible }

    /// Call on art/settings changes. An art refresh preserves selection and the
    /// user's stop decision, including while video fallback is active.
    mutating func update(region: Region, gameID: String, backgrounds: [GameBackground], animated: Bool, reduceMotion: Bool,
        playbackStates: [BackgroundVideoSource: BackgroundPlaybackState]? = nil) {
        let previousSource = videoCandidate?.1
        let changedGame = self.region != region || self.gameID != gameID
        if changedGame {
            currentID = nil; userAllowsAuto = !reduceMotion; playback = [:]
        } else if reduceMotion && !self.reduceMotion { userAllowsAuto = false }
        self.region = region; self.gameID = gameID
        // IDs from the API are unique; keep UI iteration safe for injected data too.
        var ids: Set<String> = []
        self.backgrounds = backgrounds.filter { ids.insert($0.id).inserted }
        self.animated = animated; self.reduceMotion = reduceMotion
        let sources = Set(self.backgrounds.compactMap { background in
            background.video.map { BackgroundVideoSource(region: region, gameID: gameID, backgroundID: background.id, assetURL: $0) }
        })
        playback = (playbackStates ?? playback).filter { sources.contains($0.key) }
        // The view keeps the same player while the source is unchanged, and that player won't report
        // its state again, so a refresh must not orphan callbacks already in flight.
        if videoCandidate?.1 == nil || videoCandidate?.1 != previousSource { generation = UUID() }
        reconcileCurrent()
        invalidateContentAndRestart()
    }

    mutating func setPlaybackState(_ state: BackgroundPlaybackState, for token: BackgroundVideoToken) {
        guard token.generation == generation, videoCandidate?.1 == token.source,
            playback[token.source] != .failed else { return }
        playback[token.source] = state
        if state == .failed {
            reconcileCurrent()
            invalidateContentAndRestart()
        }
    }

    /// Entry only: leaving does nothing, and a click can resume while still hovered.
    mutating func pointerEnteredDots() {
        userAllowsAuto = false
        restartRotation()
    }

    mutating func clickDot(_ id: String) {
        guard let slides, slides.dotIDs.contains(id) else { return }
        userAllowsAuto = slides.current.id == id
        currentID = id
        invalidateContentAndRestart()
    }

    mutating func setWindow(active: Bool, visible: Bool) {
        guard active != windowActive || visible != windowVisible else { return }
        windowActive = active; windowVisible = visible
        restartRotation()
    }

    mutating func advance(if token: Rotation) {
        guard token == rotation, clock.now >= token.deadline, canAutoAdvance,
            let index = stills.firstIndex(where: { $0.id == currentID }) else { return }
        currentID = stills[(index + 1) % stills.count].id
        invalidateContentAndRestart()
    }

    private mutating func reconcileCurrent() {
        if let video { currentID = video.background.id }
        else if !stills.contains(where: { $0.id == currentID }) { currentID = stills.first?.id }
    }

    private mutating func invalidateContentAndRestart() {
        contentGeneration = UUID()
        restartRotation()
    }

    private mutating func restartRotation() {
        rotation = canAutoAdvance ? Rotation(generation: UUID(), deadline: clock.now.advanced(by: .seconds(7))) : nil
    }
}
