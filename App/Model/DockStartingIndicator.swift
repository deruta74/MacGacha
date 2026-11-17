// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit

/// Shows that a game is still starting. From a shortcut the launcher window stays hidden,
/// so the Dock icon is the only sign of life during the 10 to 15 seconds before the game appears.
@MainActor protocol DockStartingIndicating: AnyObject {
    func setStarting(_ starting: Bool)
}

@MainActor final class InertDockStartingIndicator: DockStartingIndicating {
    func setStarting(_ starting: Bool) {}
}

/// Draws the app icon with a spinning badge into the Dock tile. The Dock only
/// redraws on `display()`, so a timer advances the spinner while it is shown.
@MainActor final class LiveDockStartingIndicator: DockStartingIndicating {
    private var timer: Timer?
    private var view: SpinnerTileView?
    private var shown = false, ticks = 0
    /// A game whose window is never seen must not leave the Dock spinning for the whole session.
    private static let maximumTicks = 20 * 120

    func setStarting(_ starting: Bool) {
        let tile = NSApp.dockTile
        if starting {
            guard !shown else { return }
            shown = true; ticks = 0
            let view = SpinnerTileView(icon: NSApp.applicationIconImage)
            self.view = view
            tile.contentView = view
            tile.display()
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advance() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            guard shown else { return }
            shown = false
            clear()
        }
    }

    private func clear() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        view = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    private func advance() {
        guard let view else { return }
        ticks += 1
        guard ticks < Self.maximumTicks else { clear(); return }
        view.phase = (view.phase + 1.0 / 20).truncatingRemainder(dividingBy: 1)
        NSApp.dockTile.display()
    }
}

private final class SpinnerTileView: NSView {
    private let icon: NSImage?
    /// One full turn per second.
    var phase: CGFloat = 0

    init(icon: NSImage?) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds)
        let size = bounds.width * 0.38
        let badge = NSRect(x: bounds.maxX - size - bounds.width * 0.02, y: bounds.minY + bounds.width * 0.04, width: size, height: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let center = NSPoint(x: badge.midX, y: badge.midY), radius = size * 0.3
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = size * 0.11
        NSColor.white.withAlphaComponent(0.25).setStroke()
        track.stroke()
        let start = 90 - phase * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
        arc.lineWidth = size * 0.11
        arc.lineCapStyle = .round
        NSColor.white.setStroke()
        arc.stroke()
    }
}
