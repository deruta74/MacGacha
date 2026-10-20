// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore

@Test
func diskSpaceProbeHandlesExistingAndMissingPaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let probe = SystemDiskSpaceProbe()
    #expect(try probe.availableBytes(at: directory) > 0)

    let missingRoot = directory.appendingPathComponent("fresh/install/root", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
    #expect(try probe.availableBytes(at: missingRoot) > 0)
    #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
}
