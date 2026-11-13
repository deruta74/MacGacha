// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import Synchronization
import Testing
import LauncherCore
import Launch
import RuntimeManager
@testable import MacGacha

@MainActor struct AppModelPlayTimeTests {
    @Test func startupBackfillPublishesObservableEditionSummaryAndRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("play-time-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try await BlockingIO.run {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fs = try ContainedFileSystem(root: root)
            let lines = """
            {"ts":"2026-11-12T10:00:00Z","level":"info","category":"launch","message":"Game running","metadata":{"game":"genshin-cn"}}
            {"ts":"2026-11-12T11:30:00Z","level":"info","category":"launch","message":"Session ended","metadata":{"game":"genshin-cn"}}
            """
            try fs.writeAtomically(Data(lines.utf8), to: SafeRelativePath("Logs/macgacha.log"))
        }
        let model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil)
        #expect(model.playTime(for: "genshin-cn") == nil)
        let changed = PlayTimeObservation()
        withObservationTracking { _ = model.playTime(for: "genshin-cn") } onChange: { changed.mark() }
        await model.reattachOnStart()
        #expect(changed.changed)
        #expect(model.playTime(for: "genshin-cn")?.totalSeconds == 5400)
        #expect(model.playTime(for: "genshin-cn")?.lastSessionSeconds == 5400)
        #expect(model.playTime(for: "genshin") == nil)
        await model.reattachOnStart()
        #expect(model.playTime(for: "genshin-cn")?.totalSeconds == 5400)
    }

    @Test func sessionEndAndFinalizationRefreshDurableSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("play-time-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []), services: PreviewRuntimeServices(), defaults: nil)
        await model.reattachOnStart()
        await model.handleLaunch(.ended(normal: true), id: "zzz")
        #expect(model.playTime(for: "zzz") == nil)
        // Core accounting may publish after .ended, but before .restored.
        try await BlockingIO.run {
            try PlayTimeStore(paths: paths).record(sessionID: UUID(), game: "zzz", runningSince: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 700), recovered: false)
        }
        await model.handleLaunch(.restored(.clean), id: "zzz")
        #expect(model.playTime(for: "zzz")?.totalSeconds == 600)
        try await BlockingIO.run {
            try PlayTimeStore(paths: paths).record(sessionID: UUID(), game: "zzz-cn", runningSince: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 1120), recovered: true)
        }
        // A finalized session discovered by polling follows the same refresh path.
        _ = await model.refreshLaunchSession("zzz-cn")
        #expect(model.playTime(for: "zzz-cn")?.totalSeconds == 120)
    }
}

private final class PlayTimeObservation: Sendable {
    private let value = Mutex(false)
    var changed: Bool { value.withLock { $0 } }
    func mark() { value.withLock { $0 = true } }
}
