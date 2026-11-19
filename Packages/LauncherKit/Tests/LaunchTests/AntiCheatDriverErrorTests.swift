// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import LauncherCore
import TestSupport
@testable import Launch

struct AntiCheatDriverErrorTests {
    private static let start = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-17T08:26:40Z

    private static func log(at date: Date, message: String = "initDriver Failed: Error [4,1114,0].") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        // The game writes local time first, then UTC with a trailing space.
        return "[Local_Time]2026-01-01 00:00:00.000\r\n[UTC_Time]\(formatter.string(from: date)) \r\n\(message)\r\n"
    }

    @Test func freshDriverFailureMatches() {
        #expect(AntiCheatDriverError.matches(Self.log(at: Self.start.addingTimeInterval(9)), since: Self.start))
        // A game clock a moment behind ours still counts.
        #expect(AntiCheatDriverError.matches(Self.log(at: Self.start.addingTimeInterval(-1)), since: Self.start))
    }

    @Test func staleOrUnrelatedLogsDoNotMatch() {
        #expect(!AntiCheatDriverError.matches(Self.log(at: Self.start.addingTimeInterval(-60)), since: Self.start))
        #expect(!AntiCheatDriverError.matches(Self.log(at: Self.start.addingTimeInterval(5), message: "something else"), since: Self.start))
        #expect(!AntiCheatDriverError.matches("initDriver Failed: Error [4,1114,0].", since: Self.start))
        #expect(!AntiCheatDriverError.matches("[UTC_Time]not a date\ninitDriver Failed", since: Self.start))
        #expect(!AntiCheatDriverError.matches("", since: Self.start))
    }

    @Test func gameEndingWithFreshDriverErrorReportsOfflineCause() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning()
        try await f.writeDriverError(Self.log(at: Date()))
        try await f.end(manager); await consumer.value
        let failure = try #require(await events.values.compactMap { if case .failed(let value) = $0 { value } else { nil } }.first)
        #expect(failure.stage == .watch)
        #expect(failure.cause == .antiCheatOffline)
    }

    @Test func staleDriverErrorLeavesCauseUnknown() async throws {
        let f = try await ManagerFixture.make(), manager = f.manager(), events = ManagerEvents()
        try await f.writeDriverError(Self.log(at: Date().addingTimeInterval(-3_600)))
        let consumer = await f.consume(manager, events: events)
        await events.waitForRunning(); try await f.end(manager); await consumer.value
        let failure = try #require(await events.values.compactMap { if case .failed(let value) = $0 { value } else { nil } }.first)
        #expect(failure.stage == .watch)
        #expect(failure.cause == nil)
    }

    @Test func oversizedLogIsIgnored() async throws {
        let f = try await ManagerFixture.make()
        let text = Self.log(at: Self.start) + String(repeating: "x", count: AntiCheatDriverError.maxBytes)
        try await f.writeDriverError(text)
        let root = f.installRoot
        let identity = try await BlockingIO.run { try ContainedFileSystem(root: root).pinRoot().rootIdentity() }
        let found = try await BlockingIO.run { AntiCheatDriverError.occurred(installRoot: root, identity: identity, since: Self.start) }
        #expect(!found)
    }
}

extension ManagerFixture {
    func writeDriverError(_ text: String) async throws {
        let root = installRoot
        try await BlockingIO.run {
            try ContainedFileSystem(root: root).writeAtomically(Data(text.utf8), to: AntiCheatDriverError.path)
        }
    }
}
