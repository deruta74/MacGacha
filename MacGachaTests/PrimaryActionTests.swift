// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import DownloadEngine
import GameLibrary
import Launch
import LauncherCore
@testable import MacGacha

struct PrimaryActionTests {
    @Test func rosettaPrecedenceIsLimitedToInstalledIdleGames() {
        let installed = GameState(status: .installed(tag: "1"))
        for ready in [true, false] {
            #expect(PrimaryAction.resolve(installed, runtimesReady: ready, rosetta: .missing) == .needsRosetta)
            #expect(PrimaryAction.resolve(installed, runtimesReady: ready, rosetta: .unknown) == (ready ? .play : .setUpRuntimes))
            #expect(PrimaryAction.resolve(installed, runtimesReady: ready, launch: .running, rosetta: .missing) == .playing)
        }
        #expect(PrimaryAction.resolve(GameState(status: .notInstalled), runtimesReady: false, rosetta: .missing) == .install)
        #expect(PrimaryAction.resolve(GameState(status: .updateAvailable(from: "1", to: "2")), runtimesReady: true, rosetta: .missing) == .update(to: "2"))
    }
    @Test func installedAndReadyIsPlay() {
        let action = PrimaryAction.resolve(GameState(status: .installed(tag: "1")), runtimesReady: true)
        #expect(action == .play)
    }

    @Test func missingCompatibilityComponentsRequireSetup() {
        let state = GameState(status: .installed(tag: "1"))
        #expect(PrimaryAction.resolve(state, runtimesReady: true, missingComponents: true) == .setUpRuntimes)
        #expect(PrimaryAction.resolve(state, runtimesReady: true, missingComponents: false) == .play)
    }

    @Test func updateAvailableStaysUpdate() {
        let state = GameState(status: .updateAvailable(from: "1", to: "2"))
        for ready in [false, true] {
            for missing in [false, true] {
                #expect(PrimaryAction.resolve(state, runtimesReady: ready, missingComponents: missing) == .update(to: "2"))
            }
        }
    }

    @Test func liveSessionIsPlaying() {
        let state = GameState(status: .installed(tag: "1"))
        for launch in [LaunchUIState.running, .ready] {
            #expect(PrimaryAction.resolve(state, runtimesReady: false, launch: launch, missingComponents: true) == .playing)
        }
    }

    @Test func launchStagesAreLaunching() {
        let stages: [LaunchStage] = [.preflight, .lock, .snapshot, .prepare, .proxy, .spawn, .watch, .restore, .report]
        for stage in stages {
            #expect(PrimaryAction.resolve(GameState(status: .installed(tag: "1")), runtimesReady: true,
                launch: .starting(stage)) == .launching)
        }
    }

    @Test func recoveryPendingIsRecoveryNeeded() {
        let state = GameState(status: .installed(tag: "1"), activity: .resolving)
        #expect(PrimaryAction.resolve(state, runtimesReady: true,
            launch: .recoveryNeeded("Reconnect the game drive")) == .recoveryNeeded("Reconnect the game drive"))
    }

    @Test func failedLaunchAllowsRetry() {
        let failure = LaunchFailureInfo(stage: .spawn, message: "The game could not start.", hasLog: true, unverifiedBuild: false)
        #expect(PrimaryAction.resolve(GameState(status: .installed(tag: "1")), runtimesReady: true,
            launch: .failed(failure)) == .play)
    }

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
            #expect(PrimaryAction.resolve(GameState(status: status), runtimesReady: true) == .play)
        }
    }

    @Test func spaceVerdictBoundaries() {
        for (available, expected) in [(Int64?(200), SpaceVerdict.whole), (250, .whole), (100, .batchedOnly),
            (199, .batchedOnly), (99, .insufficient), (nil, .whole)] {
            #expect(SpaceVerdict.of(GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: available)) == expected)
        }
        #expect(SpaceVerdict.of(GameEstimate(download: 0, diskWhole: 100, diskMinimum: 100, available: 100)) == .whole)
    }
    @Test func purgeableSpaceExplainsShortfallWithoutEnablingInstall() {
        let held = GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 80, purgeable: 120)
        #expect(SpaceVerdict.of(held) == .heldByMacOS(purgeable: 120))
        #expect(SpaceVerdict.immediate(held) == .insufficient)
        let parts = GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100, available: 100, purgeable: 100)
        #expect(SpaceVerdict.of(parts) == .heldByMacOS(purgeable: 100))
        #expect(SpaceVerdict.immediate(parts) == .batchedOnly)
        #expect(SpaceVerdict.of(GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100,
            available: 80, purgeable: 119)) == .insufficient)
        #expect(SpaceVerdict.of(GameEstimate(download: 50, diskWhole: 200, diskMinimum: 100,
            available: 200, purgeable: 100)) == .whole)
        #expect(SpaceVerdict.of(GameEstimate(download: 50, diskWhole: Int64.max, diskMinimum: 100,
            available: Int64.max - 1, purgeable: 100)) == .heldByMacOS(purgeable: 100))
    }
    @Test func allocationPlaceholderCannotDescribeHeldSpace() {
        #expect(GameSpaceShortage(required: 1, available: 0, purgeable: 300).heldByMacOS == nil)
    }

}
