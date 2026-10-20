import Testing
import Diagnostics

@Test
func diagnosticsModuleLoads() {
    #expect(DiagnosticsModule.self == DiagnosticsModule.self)
}
