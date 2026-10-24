// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import CoreGraphics
import LauncherCore

struct GameWindowInfo: Sendable {
    let ownerPID: Int32
    let width: Double
    let height: Double
}

protocol GameWindowProviding: Sendable {
    func hasVisibleWindow(ownerPIDs: Set<Int32>) async -> Bool
}

/// Queries public window geometry and ownership only; window titles and image
/// capture APIs are intentionally excluded, so detection needs no recording grant.
struct GameWindowDetector: GameWindowProviding {
    let windows: @Sendable () async -> [GameWindowInfo]

    init(windows: @escaping @Sendable () async -> [GameWindowInfo] = Self.onScreenWindows) {
        self.windows = windows
    }

    func hasVisibleWindow(ownerPIDs: Set<Int32>) async -> Bool {
        guard !ownerPIDs.isEmpty else { return false }
        return await windows().contains {
            ownerPIDs.contains($0.ownerPID) && $0.width > 0 && $0.height > 0
        }
    }

    private static func onScreenWindows() async -> [GameWindowInfo] {
        (try? await BlockingIO.run {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
                return []
            }
            return windows.compactMap { window in
                guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                    let bounds = window[kCGWindowBounds as String] as? [String: Any],
                    let width = bounds["Width"] as? NSNumber,
                    let height = bounds["Height"] as? NSNumber else { return nil }
                return GameWindowInfo(ownerPID: pid.int32Value, width: width.doubleValue, height: height.doubleValue)
            }
        }) ?? []
    }
}

@MainActor protocol LaunchWindowActions: AnyObject {
    func minimize()
    func restore()
}

@MainActor final class SystemLaunchWindowActions: LaunchWindowActions {
    private weak var launcherWindow: NSWindow?

    func minimize() {
        launcherWindow = NSApp.windows.first(where: \.isMainWindow)
        launcherWindow?.miniaturize(nil)
    }

    func restore() {
        launcherWindow?.deminiaturize(nil)
        NSApp.activate()
        launcherWindow = nil
    }
}

/// Observation is independent of launch supervision: ending cancels both timers;
/// fallback minimization never declares the game ready without a game window.
@MainActor final class LaunchWindowCoordinator {
    private let detector: any GameWindowProviding
    private let actions: any LaunchWindowActions
    private let sleep: @Sendable (Duration) async throws -> Void
    private var polling: Task<Void, Never>?
    private var fallback: Task<Void, Never>?
    private var active: (game: String, generation: UUID)?
    private var minimized = false

    init(detector: any GameWindowProviding = GameWindowDetector(),
        actions: any LaunchWindowActions = SystemLaunchWindowActions(),
        clock: any Clock<Duration> = ContinuousClock()) {
        self.detector = detector; self.actions = actions
        self.sleep = { try await clock.sleep(for: $0) }
    }

    func running(gameID: String, processIDs: @escaping @Sendable () async -> [Int32],
        markReady: @escaping @Sendable () async -> Void) {
        if active?.game == gameID { return }
        cancel()
        let generation = UUID()
        active = (gameID, generation); minimized = false
        let detector = detector, sleep = sleep
        polling = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let pids = await processIDs()
                    let visible = await detector.hasVisibleWindow(ownerPIDs: Set(pids))
                    guard !Task.isCancelled, self?.active?.generation == generation else { return }
                    if visible {
                        await markReady()
                        guard !Task.isCancelled, self?.active?.generation == generation else { return }
                        self?.ready(gameID: gameID)
                        return
                    }
                    try await sleep(.milliseconds(500))
                }
            } catch { /* Session end cancels observation. */ }
        }
        fallback = Task { [weak self] in
            do {
                try await sleep(.seconds(20))
                guard !Task.isCancelled, self?.active?.generation == generation else { return }
                self?.minimizeOnce()
            } catch { /* Session end cancels the fallback. */ }
        }
    }

    func ready(gameID: String) {
        guard active?.game == gameID else { return }
        minimizeOnce()
        fallback?.cancel(); fallback = nil
        polling?.cancel(); polling = nil
    }

    func ended(gameID: String) {
        guard active?.game == gameID else { return }
        cancel(); active = nil
        actions.restore(); minimized = false
    }

    private func minimizeOnce() {
        guard !minimized else { return }
        minimized = true; actions.minimize()
    }

    private func cancel() {
        polling?.cancel(); polling = nil
        fallback?.cancel(); fallback = nil
    }

    deinit { polling?.cancel(); fallback?.cancel() }
}
