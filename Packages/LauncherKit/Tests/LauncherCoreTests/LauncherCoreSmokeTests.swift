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
