// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import LauncherCore
@testable import Launch

struct PlayTimeStoreTests {
    @Test func recordsExactlyOnceAcrossReloadsAndKeepsEditionsSeparate() throws {
        let temp = try ManagerTemporaryDirectory()
        let paths = AppPaths(root: temp.url), id = UUID()
        let store = PlayTimeStore(paths: paths)
        try store.record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 3700), recovered: false)
        try PlayTimeStore(paths: paths).record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 7300), recovered: true)
        try store.record(sessionID: UUID(), game: "genshin-cn", runningSince: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 800), recovered: false)
        let summaries = try store.load()
        #expect(summaries["genshin"]?.totalSeconds == 3600)
        #expect(summaries["genshin"]?.lastSessionSeconds == 3600)
        #expect(summaries["genshin"]?.lastPlayed == Date(timeIntervalSince1970: 100))
        #expect(summaries["genshin-cn"]?.totalSeconds == 600)
    }

    @Test func skipsMissingRunningAndNegativeTimeAndBoundsUnknownRecovery() throws {
        let temp = try ManagerTemporaryDirectory(), store = PlayTimeStore(paths: AppPaths(root: temp.url))
        for (start, end, recovered) in [(nil, 500.0, false), (100.0, 90.0, false), (100.0, 86_501.0, true)] {
            try store.record(sessionID: UUID(), game: "zzz", runningSince: start.map(Date.init(timeIntervalSince1970:)),
                endedAt: Date(timeIntervalSince1970: end), recovered: recovered)
        }
        #expect(try store.load().isEmpty)
        try store.record(sessionID: UUID(), game: "zzz", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 86_500), recovered: true)
        #expect(try store.load()["zzz"]?.totalSeconds == 86_400)
        // A continuously supervised session can legitimately exceed the recovery bound.
        try store.record(sessionID: UUID(), game: "zzz", runningSince: Date(timeIntervalSince1970: 90_000),
            endedAt: Date(timeIntervalSince1970: 180_000), recovered: false, supervisedSeconds: 90_000)
        #expect(try store.load()["zzz"]?.totalSeconds == 176_400)
    }

    @Test func lateOlderSessionDoesNotReplaceLastPlayedDetails() throws {
        let temp = try ManagerTemporaryDirectory(), store = PlayTimeStore(paths: AppPaths(root: temp.url))
        for (start, end) in [(1000.0, 1600.0), (100.0, 400.0)] {
            try store.record(sessionID: UUID(), game: "starrail", runningSince: Date(timeIntervalSince1970: start),
                endedAt: Date(timeIntervalSince1970: end), recovered: false)
        }
        let summary = try #require(store.load()["starrail"])
        #expect(summary.totalSeconds == 900)
        #expect(summary.lastSessionSeconds == 600)
        #expect(summary.lastPlayed == Date(timeIntervalSince1970: 1000))
    }

    @Test func backfillPairsByEditionSkipsAmbiguityAndRunsOnce() throws {
        let temp = try ManagerTemporaryDirectory(), paths = AppPaths(root: temp.url)
        let fs = try ContainedFileSystem(root: temp.url), store = PlayTimeStore(paths: paths)
        let events: [(String, String, Double)] = [
            ("genshin", "Session ended", 0), // rotated start is absent
            ("genshin", "Game running", 100), ("genshin-cn", "Game running", 110),
            ("genshin", "Session ended", 3700), ("genshin-cn", "Session ended", 710),
            ("zzz", "Game running", 4000), ("zzz", "Game running", 4100), ("zzz", "Session ended", 4200),
            ("starrail", "Game running", 5000), ("starrail", "Session ended", 4900),
            ("starrail-cn", "Game running", 10_000), ("starrail-cn", "Session ended", 100_000),
            ("genshin", "Game running", 110_000) // unmatched tail
        ]
        var lines = Data("malformed\n".utf8)
        for (game, message, time) in events { lines.append(try eventLine(game, message, time)) }
        try fs.writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        let result = try store.backfill()
        #expect(result?.sessions == 3)
        #expect(try store.load()["genshin"]?.totalSeconds == 3600)
        #expect(try store.load()["genshin-cn"]?.totalSeconds == 600)
        #expect(try store.load()["starrail-cn"]?.totalSeconds == 86_400)
        #expect(try store.load()["zzz"] == nil)
        #expect(try store.load()["starrail"] == nil)
        #expect(try PlayTimeStore(paths: paths).backfill() == nil)
    }

    @Test func missingLogStillCompletesBackfill() throws {
        let temp = try ManagerTemporaryDirectory(), paths = AppPaths(root: temp.url), store = PlayTimeStore(paths: paths)
        #expect(try store.backfill()?.sessions == 0)
        let fs = try ContainedFileSystem(root: temp.url)
        var lines = try eventLine("genshin", "Game running", 100)
        lines.append(try eventLine("genshin", "Session ended", 200))
        try fs.writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        #expect(try PlayTimeStore(paths: paths).backfill() == nil)
        #expect(try store.load().isEmpty)
    }

    @Test func liveSessionIsNotCountedAgainByBackfill() throws {
        let temp = try ManagerTemporaryDirectory(), store = PlayTimeStore(paths: AppPaths(root: temp.url)), id = UUID()
        try store.record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200), recovered: false)
        var lines = try eventLine("genshin", "Game running", 100, sessionID: id)
        lines.append(try eventLine("genshin", "Session ended", 200, sessionID: id))
        try ContainedFileSystem(root: temp.url).writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        #expect(try store.backfill()?.sessions == 0)
        #expect(try store.load()["genshin"]?.totalSeconds == 100)
    }

    @Test func existingUUIDReceiptsDeduplicateHashedLogPairs() throws {
        let temp = try ManagerTemporaryDirectory(), paths = AppPaths(root: temp.url), id = UUID()
        let store = PlayTimeStore(paths: paths), fs = try ContainedFileSystem(root: temp.url)
        try store.record(sessionID: id, game: "genshin", runningSince: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200), recovered: false, supervisedSeconds: 100)
        let path = try SafeRelativePath("PlayTime/play-time.json")
        var state = try #require(JSONSerialization.jsonObject(with: fs.readFile(at: path, maxBytes: 8 << 20)) as? [String: Any])
        state["countedSessionIDs"] = [id.uuidString]
        try fs.writeAtomically(JSONSerialization.data(withJSONObject: state), to: path)
        var lines = Data()
        for (message, time) in [("Game running", 100.0), ("Session ended", 200.0)] {
            var record = try JSONDecoder().decode(EventLog.Record.self, from: eventLine("genshin", message, time))
            record.metadata["playID"] = PlayTimeStore.playID(for: id)
            lines.append(try JSONEncoder().encode(record)); lines.append(10)
        }
        try fs.writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        #expect(try store.backfill()?.sessions == 0)
        #expect(try store.load()["genshin"]?.totalSeconds == 100)
    }

    @Test func redactedLegacyIdentifiersDoNotBecomeUnrelatedBackfillReceipts() throws {
        let temp = try ManagerTemporaryDirectory(), store = PlayTimeStore(paths: AppPaths(root: temp.url))
        var lines = Data()
        for (message, time) in [("Game running", 100.0), ("Session ended", 200.0)] {
            var record = try JSONDecoder().decode(EventLog.Record.self, from: eventLine("genshin", message, time))
            record.metadata["sessionID"] = "[REDACTED]"
            lines.append(try JSONEncoder().encode(record)); lines.append(10)
        }
        try ContainedFileSystem(root: temp.url).writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        #expect(try store.backfill()?.sessions == 0)
        #expect(try store.load().isEmpty)
    }

    @Test func outOfOrderHistoryDoesNotCreateOverlappingCredit() throws {
        let temp = try ManagerTemporaryDirectory(), store = PlayTimeStore(paths: AppPaths(root: temp.url))
        var lines = Data()
        for (message, time) in [("Game running", 100.0), ("Session ended", 300.0),
            ("Game running", 200.0), ("Session ended", 400.0)] {
            lines.append(try eventLine("genshin", message, time))
        }
        try ContainedFileSystem(root: temp.url).writeAtomically(lines, to: SafeRelativePath("Logs/macgacha.log"))
        #expect(try store.backfill()?.sessions == 1)
        #expect(try store.load()["genshin"]?.totalSeconds == 200)
    }

    private func eventLine(_ game: String, _ message: String, _ time: Double, sessionID: UUID? = nil) throws -> Data {
        var metadata = ["game": game]
        if let sessionID { metadata["sessionID"] = sessionID.uuidString }
        var data = try JSONEncoder().encode(EventLog.Record(ts: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: time)),
            level: .info, category: "launch", message: message, metadata: metadata))
        data.append(10)
        return data
    }
}
