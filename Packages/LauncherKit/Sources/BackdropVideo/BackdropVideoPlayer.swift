// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import AVFoundation

public enum BackdropVideoState: Sendable, Equatable { case stopped, preparing, playing, failed }

@MainActor @Observable public final class BackdropVideoPlayer {
    public private(set) var state: BackdropVideoState = .stopped
    public private(set) var sourceURL: URL?
    public private(set) var isPaused = false
    public var onStateChange: (@MainActor @Sendable (URL, BackdropVideoState) -> Void)?
    @ObservationIgnored private let sink: any BackdropVideoSink
    @ObservationIgnored private let makeSource: @Sendable (URL) -> any BackdropFrameSource
    @ObservationIgnored private var source: (any BackdropFrameSource)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var pumpID = UUID()
    @ObservationIgnored private var pending: BackdropFrame?
    @ObservationIgnored private var didEnqueue = false
    @ObservationIgnored private var needsPreparation = true
    @ObservationIgnored private var restartWhenFinished = false

    public init(layer: AVSampleBufferDisplayLayer,
        onStateChange: (@MainActor @Sendable (URL, BackdropVideoState) -> Void)? = nil) {
        sink = LayerVideoSink(layer: layer); makeSource = { VideoFrameSource(url: $0) }; self.onStateChange = onStateChange
    }
    package init(sink: any BackdropVideoSink, makeSource: @escaping @Sendable (URL) -> any BackdropFrameSource) {
        self.sink = sink; self.makeSource = makeSource
    }
    /// The view must keep its still visible until state becomes .playing.
    public func play(_ url: URL) {
        stop()
        sourceURL = url; state = .preparing
        let token = generation
        source = makeSource(url)
        sink.onReady = { [weak self] in self?.markPlaying(token) }
        onStateChange?(url, .preparing)
        startPump(token)
    }
    public func pause() {
        guard source != nil else { return }
        isPaused = true; restartWhenFinished = false
        source?.setPaused(true); sink.setPlaying(false)
    }
    public func resume() {
        guard source != nil, isPaused else { return }
        isPaused = false; source?.setPaused(false)
        if didEnqueue { sink.setPlaying(true); markPlaying(generation) }
        if pump == nil { startPump(generation) } else { restartWhenFinished = true }
    }
    public func stop() {
        let previous = sourceURL
        generation = UUID(); pumpID = UUID()
        source?.stop(); source = nil
        pump?.cancel(); pump = nil; pending = nil
        sink.onReady = nil; sink.flush()
        sourceURL = nil; didEnqueue = false; needsPreparation = true; isPaused = false; restartWhenFinished = false; state = .stopped
        if let previous { onStateChange?(previous, .stopped) }
    }
    package var workTask: Task<Void, Never>? { pump }
    private func current(_ token: UUID) -> Bool { generation == token && source != nil && state != .failed }
    private func takePreparation() -> Bool { let value = needsPreparation; needsPreparation = false; return value }
    private func takePending() -> BackdropFrame? { let value = pending; pending = nil; return value }
    private func startPump(_ token: UUID) {
        guard current(token), !isPaused, pump == nil, let source else { return }
        let sink = sink, id = UUID(); pumpID = id
        pump = Task { [weak self] in
            defer { self?.pumpFinished(token, id: id) }
            do {
                if self?.takePreparation() == true { await sink.prepare() }
                guard self?.current(token) == true, !Task.isCancelled else { return }
                while !Task.isCancelled && self?.current(token) == true && self?.isPaused == false {
                    let frame: BackdropFrame?
                    if let pending = self?.takePending() { frame = pending } else { frame = try await source.next() }
                    guard self?.current(token) == true, !Task.isCancelled, let frame else { return }
                    if self?.isPaused == true { self?.pending = frame; return }
                    try await sink.enqueue(frame)
                    guard self?.current(token) == true, !Task.isCancelled else { return }
                    self?.enqueued(token)
                }
            } catch {
                guard self?.current(token) == true, !Task.isCancelled else { return }
                self?.fail(token)
            }
        }
    }
    private func enqueued(_ token: UUID) {
        if !didEnqueue { didEnqueue = true; if !isPaused { sink.setPlaying(true) } }
        markPlaying(token)
    }
    private func markPlaying(_ token: UUID) {
        guard current(token), !isPaused, didEnqueue, sink.isDisplayable, state != .playing, let sourceURL else { return }
        state = .playing; onStateChange?(sourceURL, .playing)
    }
    private func fail(_ token: UUID) {
        guard current(token), let sourceURL else { return }
        source?.stop(); source = nil; pending = nil; sink.setPlaying(false); sink.flush()
        state = .failed; onStateChange?(sourceURL, .failed)
    }
    private func pumpFinished(_ token: UUID, id: UUID) {
        guard pumpID == id, generation == token else { return }
        pump = nil
        if restartWhenFinished, !isPaused, current(token) { restartWhenFinished = false; startPump(token) }
    }
    isolated deinit { source?.stop(); pump?.cancel(); sink.onReady = nil; sink.flush() }
}
