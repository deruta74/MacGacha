// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore

@Test
func launcherCoreModuleLoads() {
    #expect(LauncherCoreModule.self == LauncherCoreModule.self)
}

@Test
func failureStageIsAvailableToCoreConsumers() throws {
    #expect(try JSONDecoder().decode(FailureStage.self, from: JSONEncoder().encode(FailureStage.verify)) == .verify)
}
