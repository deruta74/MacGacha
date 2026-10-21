// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import DownloadEngine
import GameLibrary
@testable import MacGacha

struct PrimaryActionTests {
    @Test func activityBeatsStatus() {
        let cases: [(GameStatus, GameActivity, PrimaryAction)] = [
            (.notInstalled, .resolving, .preparing),
            (.notInstalled, .working(.staging, fraction: 0.2, bytesPerSecond: 10, downloaded: 20, total: 100), .progress),
            (.paused(.update), .working(.verifying, fraction: nil, bytesPerSecond: nil), .progress),
            (.paused(.install), .needsApproval(required: 200, available: 100), .continueInParts),
            (.locationUnavailable(URL(fileURLWithPath: "/unmounted")), .resolving, .preparing),
        ]
        for (status, activity, expected) in cases {
            #expect(PrimaryAction.resolve(GameState(status: status, activity: activity), runtimesReady: false) == expected)
        }
    }

    @Test func statusOrder() {
        let cases: [(GameStatus, PrimaryAction)] = [
            (.locationUnavailable(URL(fileURLWithPath: "/unmounted")), .locationUnavailable),
            (.notInstalled, .install), (.paused(.install), .resume), (.paused(.repair), .resume),
            (.uninstallPaused, .finishUninstall), (.updateAvailable(from: "1", to: "2"), .update(to: "2")),
        ]
        for ready in [false, true] {
            for (status, expected) in cases {
                #expect(PrimaryAction.resolve(GameState(status: status), runtimesReady: ready) == expected)
            }
        }
        for status in [GameStatus.installed(tag: "1"), .unknown] {
            #expect(PrimaryAction.resolve(GameState(status: status), runtimesReady: false) == .setUpRuntimes)
            #expect(PrimaryAction.resolve(GameState(status: status), runtimesReady: true) == .playUnavailable)
        }
    }

    @Test func spaceVerdictBoundaries() {
        for (available, expected) in [(Int64?(200), SpaceVerdict.whole), (250, .whole), (100, .batchedOnly),
            (199, .batchedOnly), (99, .insufficient), (nil, .whole)] {
            #expect(SpaceVerdict.of(GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: available)) == expected)
        }
        #expect(SpaceVerdict.of(GameEstimate(download: 0, diskWhole: 100, diskMinimum: 100, available: 100)) == .whole)
    }
}
