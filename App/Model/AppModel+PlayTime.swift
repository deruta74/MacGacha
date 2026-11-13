// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Launch

@MainActor extension AppModel {
    /// Observable completed-session totals. nil hides editions with no counted play.
    func playTime(for id: String) -> PlayTimeSummary? { playTimeSummaries[id] }

    /// Independent of launch recovery and preferences, with all log parsing and
    /// metadata I/O on BlockingIO. The durable marker survives launcher restarts.
    @discardableResult func startPlayTime() -> Task<Void, Never> {
        if let task = playTimeStartupTask { return task }
        let paths = paths
        let task = Task { [weak self] in
            do {
                let result = try await BlockingIO.run { try PlayTimeStore(paths: paths).backfill() }
                if let result {
                    EventLog(directory: paths.logs).post(.info, "playTime", "Play time backfill completed",
                        metadata: ["sessions": String(result.sessions)])
                }
            } catch {
                EventLog(directory: paths.logs).post(.warning, "playTime", "Play time backfill unavailable")
            }
            await self?.refreshPlayTime()
        }
        playTimeStartupTask = task
        return task
    }

    func refreshPlayTime() async {
        let revision = UUID(), paths = paths
        playTimeRefreshRevision = revision
        do {
            let summaries = try await BlockingIO.run { try PlayTimeStore(paths: paths).load() }
            guard !Task.isCancelled, playTimeRefreshRevision == revision else { return }
            playTimeSummaries = summaries
        } catch {
            // A transient read must not erase the last known completed totals.
            EventLog(directory: paths.logs).post(.warning, "playTime", "Play time summary unavailable")
        }
    }
}
