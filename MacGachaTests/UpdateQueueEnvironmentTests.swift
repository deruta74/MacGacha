// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Testing
@testable import MacGacha

@Suite struct UpdateQueueEnvironmentTests {
    @Test func automaticTransfersRequireAnAvailableUnconstrainedPath() {
        #expect(UpdateQueueEnvironment.permitsTransfer(available: true, constrained: false))
        #expect(!UpdateQueueEnvironment.permitsTransfer(available: false, constrained: false))
        #expect(!UpdateQueueEnvironment.permitsTransfer(available: true, constrained: true))
    }

    @Test @MainActor func closingOnlyWindowKeepsOptedInDiscoveryAliveAndExplicitQuitWorks() {
        let model = AppModel.preview()
        let delegate = LauncherAppDelegate()
        delegate.bind(model)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        model.updateQueue.automatic = true
        model.updateQueue.automaticGames = ["genshin"]
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        model.updateQueue.enabled = false
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    @Test @MainActor func monitoringStartsAndStopsWithAFailClosedSnapshot() {
        let environment = UpdateQueueEnvironment()
        #expect(!environment.permitsNetwork)
        environment.start {}
        environment.stop()
        #expect(!environment.permitsNetwork)
        #expect(environment.onAC == nil)
    }
}
