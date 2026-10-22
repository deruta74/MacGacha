// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
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

@Test func diskSpaceUsesImmediatelyAvailableBlocksWithoutPurgeableCredit() throws {
    let directory = FileManager.default.temporaryDirectory
    func available() throws -> Int64 {
        var info = statfs()
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw LauncherError.io("open failed") }; defer { close(fd) }
        guard fstatfs(fd, &info) == 0 else { throw LauncherError.io("statfs failed") }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
    let before = try available()
    let result = try SystemDiskSpaceProbe().availableBytes(at: directory)
    let after = try available()
    // Concurrent test/system writes can move free space during the probe.
    // Purgeable caches must never count as already available allocation.
    #expect(result >= 0 && result <= max(before, after) + 1_048_576)
}
