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
