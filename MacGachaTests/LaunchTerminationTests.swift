// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Testing
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor
struct LaunchTerminationTests {
    #if DEBUG
    @Test(arguments: ["playing", "launching", "launchFailed", "recoveryNeeded"])
    func debugLaunchStatesUseInertPreview(name: String) throws {
        let model = try #require(AppModel.debugLaunchPreview(state: name, recoveryNotice: false))
        for id in ["genshin", "starrail", "zzz"] { #expect(model.launchState(for: id) != nil) }
        #expect((model.launchSlotOwner != nil) == (name != "launchFailed"))
        #expect((model.liveSessionGameName != nil) == (name == "playing" || name == "launching"))
    }

    @Test func debugRecoveryNoticeIsAvailableWithoutLiveSession() throws {
        let model = try #require(AppModel.debugLaunchPreview(state: nil, recoveryNotice: true))
        #expect(model.recoveryNotices.count == 1)
        #expect(model.recoveryNotices.first?.game == "starrail")
        #expect(model.liveSessionGameName == nil)
        #expect(AppModel.debugLaunchPreview(state: "installed", recoveryNotice: false) == nil)
    }
    #endif

    @Test func noLiveGameTerminatesImmediately() {
        let delegate = LauncherAppDelegate()
        delegate.requestConfirmation = { _, _ in Issue.record("No confirmation is needed without a live game") }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test(arguments: [true, false]) func liveGameDefersConfirmationAndReplies(quit: Bool) async {
        let delegate = LauncherAppDelegate()
        delegate.liveGameName = { "Genshin Impact" }
        var returned = false
        var observedGame: String?
        delegate.requestConfirmation = { game, completion in
            #expect(returned)
            observedGame = game
            completion(quit ? .terminateNow : .terminateCancel)
        }
        let result = await withCheckedContinuation { continuation in
            delegate.replyToTermination = { continuation.resume(returning: $0) }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            returned = true
        }
        #expect(result == quit)
        #expect(observedGame == "Genshin Impact")
    }

    @Test func confirmationHookDefaultsToQuitAndCanBeOverridden() {
        let model = AppModel.preview(rows: [], logLines: [], games: [:])
        var result: NSApplication.TerminateReply?
        model.confirmQuit(gameName: "Genshin Impact") { result = $0 }
        #expect(result == .terminateNow)
        model.quitConfirmation = { game, completion in
            #expect(game == "Genshin Impact")
            completion(.terminateCancel)
        }
        model.confirmQuit(gameName: "Genshin Impact") { result = $0 }
        #expect(result == .terminateCancel)
    }
}
