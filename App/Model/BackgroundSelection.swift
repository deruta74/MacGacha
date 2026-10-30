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

/// Decoder callbacks belong to this source and player generation only.
struct BackgroundVideoToken: Sendable, Hashable {
    let source: BackgroundVideoSource
    let generation: UUID
}

struct BackgroundSlides: Sendable, Equatable {
    let current: GameBackground
    let dotIDs: [String]
}

struct BackgroundVideo: Sendable, Equatable {
    let background: GameBackground
    let token: BackgroundVideoToken
    let state: BackgroundPlaybackState
    let isPaused: Bool
}

/// Server-order selection has no periodic work. Window state affects only video.
@MainActor struct BackgroundSelection<C: Clock> where C.Duration == Duration {
    struct Hover: Hashable, Sendable {
        let generation: UUID
        let backgroundID: String
        let deadline: C.Instant
    }
    static var dotHoverDelay: Duration { .milliseconds(100) }
    private(set) var dotHover: Hover?
    private let clock: C
    private let session: BackgroundSelectionSession
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
    private var failedStills: Set<URL> = []

    init(clock: C, session: BackgroundSelectionSession = .shared) { self.clock = clock; self.session = session }

    var allowsCrossfade: Bool { !reduceMotion }
    private var available: [GameBackground] { backgrounds.filter { $0.image.map { !failedStills.contains($0) } ?? false } }
    private var current: GameBackground? { available.first { $0.id == currentID } }
    var theme: URL? { current?.theme }
    private var videoCandidate: (GameBackground, BackgroundVideoSource)? {
        guard animated, !reduceMotion, let region, let gameID, let current, let url = current.video else { return nil }
        return (current, BackgroundVideoSource(region: region, gameID: gameID, backgroundID: current.id, assetURL: url))
    }
    var video: BackgroundVideo? {
        guard let (background, source) = videoCandidate, playback[source] != .failed else { return nil }
        return BackgroundVideo(background: background, token: BackgroundVideoToken(source: source, generation: generation),
            state: playback[source] ?? .preparing, isPaused: !windowActive || !windowVisible)
    }
    var slides: BackgroundSlides? {
        guard let current else { return nil }
        return BackgroundSlides(current: current, dotIDs: available.count > 1 ? available.map(\.id) : [])
    }

    mutating func update(region: Region, gameID: String, backgrounds: [GameBackground], animated: Bool, reduceMotion: Bool) {
        let previousSource = videoCandidate?.1
        dotHover = nil
        if self.region != region || self.gameID != gameID { playback = [:] }
        self.region = region; self.gameID = gameID
        var ids: Set<String> = []
        self.backgrounds = backgrounds.filter { ids.insert($0.id).inserted }
        self.animated = animated; self.reduceMotion = reduceMotion
        failedStills.formIntersection(Set(backgrounds.compactMap(\.image)))
        let sources = Set(backgrounds.compactMap { background in
            background.video.map { BackgroundVideoSource(region: region, gameID: gameID, backgroundID: background.id, assetURL: $0) }
        })
        playback = playback.filter { sources.contains($0.key) }
        currentID = session.selection(for: gameID, availableIDs: available.map(\.id))
        reconcileVideo(previousSource)
    }

    mutating func setPlaybackState(_ state: BackgroundPlaybackState, for token: BackgroundVideoToken) {
        guard token.generation == generation, videoCandidate?.1 == token.source, playback[token.source] != .failed else { return }
        playback[token.source] = state
    }
    mutating func hoverDot(_ id: String) {
        guard let slides, slides.dotIDs.contains(id), slides.current.id != id else { dotHover = nil; return }
        guard dotHover?.backgroundID != id else { return }
        dotHover = Hover(generation: UUID(), backgroundID: id, deadline: clock.now.advanced(by: Self.dotHoverDelay))
    }
    mutating func leaveDot(_ id: String) {
        if dotHover?.backgroundID == id { dotHover = nil }
    }
    /// The view sleeps on the injected clock and returns the exact hover token.
    /// A cancelled or superseded hover can never select another game's slide.
    mutating func selectHoveredDot(if token: Hover) {
        guard token == dotHover, clock.now >= token.deadline else { return }
        clickDot(token.backgroundID)
    }
    mutating func clickDot(_ id: String) {
        guard let gameID, let slides, slides.dotIDs.contains(id) else { return }
        dotHover = nil
        let previousSource = videoCandidate?.1
        session.select(id, for: gameID); currentID = id
        reconcileVideo(previousSource)
    }
    mutating func setStillImageFailed(_ url: URL) {
        guard let gameID, backgrounds.contains(where: { $0.image == url }) else { return }
        let previousSource = videoCandidate?.1
        dotHover = nil
        failedStills.insert(url)
        let availableIDs = available.map(\.id)
        var orderedIDs = availableIDs
        // Keep the failed choice as the anchor while resolving its successor.
        if let index = backgrounds.firstIndex(where: { $0.id == currentID }) {
            let successors = backgrounds.dropFirst(index + 1) + backgrounds.prefix(index + 1)
            orderedIDs = successors.map(\.id).filter { availableIDs.contains($0) }
        }
        currentID = session.selection(for: gameID, availableIDs: orderedIDs)
        reconcileVideo(previousSource)
    }
    mutating func setWindow(active: Bool, visible: Bool) {
        windowActive = active; windowVisible = visible
    }

    private mutating func reconcileVideo(_ previous: BackgroundVideoSource?) {
        let source = videoCandidate?.1
        guard source != previous || source == nil else { return }
        generation = UUID()
        // A newly mounted player must enqueue its own first frame, even if this source played earlier.
        if let source, playback[source] != .failed { playback[source] = .preparing }
    }
}
