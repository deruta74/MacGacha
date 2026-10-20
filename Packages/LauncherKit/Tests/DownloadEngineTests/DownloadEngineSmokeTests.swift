// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Testing
import DownloadEngine

@Test
func downloadEngineModuleLoads() {
    #expect(DownloadEngineModule.self == DownloadEngineModule.self)
}
