// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) struct GameNotificationHistoryTests {
    @Test func legacyHistoryCompactsWithoutForgettingEarlierCampaignsOrFailedClaimRetries() async throws {
        try await BlockingIO.run { () throws -> Void in
            let root = URL(fileURLWithPath: "/tmp/macgacha-history-compaction-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let fs = try ContainedFileSystem(root: root)
            let old = Set((1...8_000).map { GameNotificationHistory.Marker(gameID: "genshin", version: "\($0).0", kind: .updateAvailable) })
            try fs.writeAtomically(JSONEncoder().encode(old), to: SafeRelativePath("notification-history.json"))
            let history = GameNotificationHistory(paths: AppPaths(root: root))
            let next = GameNotificationHistory.Marker(gameID: "genshin", version: "8001.0", kind: .updateAvailable)
            #expect(try history.claim(next))
            #expect(try fs.readFile(at: SafeRelativePath("notification-history.json"), maxBytes: 1_048_576).count < 4_096)
            let restarted = GameNotificationHistory(paths: AppPaths(root: root))
            for version in ["1.0", "2.0", "79.0", "8000.0"] {
                #expect(try restarted.contains(.init(gameID: "genshin", version: version, kind: .updateAvailable)))
            }
            try restarted.release(next)
            #expect(try !restarted.contains(next))
            #expect(try restarted.claim(next))
            #expect(try restarted.claim(.init(gameID: "genshin-cn", version: "8001.0", kind: .updateAvailable)))
            #expect(try restarted.claim(.init(gameID: "genshin", version: "8001.0", kind: .preDownloadAvailable)))
        }
    }

    @Test func compactionUsesNumericOrderAndKeepsOpaqueReceiptsAndOtherEditions() async throws {
        try await BlockingIO.run { () throws -> Void in
            let root = URL(fileURLWithPath: "/tmp/macgacha-history-order-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = GameNotificationHistory(paths: AppPaths(root: root))
            for version in ["7.2.0", "7.9.0", "7.10.0", "campaign-alpha", "campaign-beta"] {
                #expect(try history.claim(.init(gameID: "genshin", version: version, kind: .updateAvailable)))
            }
            #expect(try history.claim(.init(gameID: "genshin-cn", version: "7.2.0", kind: .updateAvailable)))
            #expect(try history.claim(.init(gameID: "genshin", version: "7.11.0", kind: .updateAvailable)))
            let restarted = GameNotificationHistory(paths: AppPaths(root: root))
            for version in ["7.2.0", "7.9.0", "7.10.0", "campaign-alpha", "campaign-beta"] {
                #expect(try restarted.contains(.init(gameID: "genshin", version: version, kind: .updateAvailable)))
            }
            #expect(try !restarted.claim(.init(gameID: "genshin", version: "7.9.0", kind: .updateAvailable)))
            #expect(try restarted.claim(.init(gameID: "genshin", version: "7.12.0", kind: .updateAvailable)))
            #expect(try !restarted.contains(.init(gameID: "genshin", version: "campaign-gamma", kind: .updateAvailable)))
            #expect(try !restarted.contains(.init(gameID: "zzz", version: "7.2.0", kind: .updateAvailable)))
            #expect(try !restarted.contains(.init(gameID: "genshin", version: "7.2.0", kind: .preDownloadAvailable)))
        }
    }

    @Test func repeatedCampaignsKeepHistoryBoundedWithoutEvictingDeduplicationState() async throws {
        try await BlockingIO.run { () throws -> Void in
            let root = URL(fileURLWithPath: "/tmp/macgacha-history-growth-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let history = GameNotificationHistory(paths: AppPaths(root: root))
            for version in 1...100 {
                #expect(try history.claim(.init(gameID: "zzz", version: "\(version).0.0", kind: .preDownloadAvailable)))
            }
            let fs = try ContainedFileSystem(root: root)
            #expect(try fs.readFile(at: SafeRelativePath("notification-history.json"), maxBytes: 1_048_576).count < 4_096)
            #expect(try history.contains(.init(gameID: "zzz", version: "1.0.0", kind: .preDownloadAvailable)))
            #expect(try !history.claim(.init(gameID: "zzz", version: "99.0.0", kind: .preDownloadAvailable)))
        }
    }
}
