// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func secondLockHolderGetsBusy() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath(".macgacha-staging/lock")
    var first: InstallLock? = try InstallLock(fs: fs, path: path)
    #expect(throws: LauncherError.busy("install root in use")) { _ = try InstallLock(fs: fs, path: path) }
    #expect(first != nil)
    first = nil
    let reacquired = try InstallLock(fs: fs, path: path)
    let size = try fs.size(at: path)
    withExtendedLifetime(reacquired) { #expect(size == 0) }
}

@Test
func releasingLockUnlocksBeforeDuplicatedDescriptionCloses() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath(".macgacha-staging/lock")
    var owner: InstallLock? = try InstallLock(fs: fs, path: path)
    let absolutePath = path.resolved(against: temp.url).resolvingSymlinksInPath().path
    var duplicate = try withExtendedLifetime(owner) { try duplicateLockDescription(at: absolutePath) }
    defer { if duplicate >= 0 { close(duplicate) } }
    #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)
    _ = withExtendedLifetime(owner) {
        #expect(throws: LauncherError.busy("install root in use")) { try InstallLock(fs: fs, path: path) }
    }

    // posix_spawn temporarily retains open-file descriptions before exec closes CLOEXEC
    // descriptors. A duplicate models that reference deterministically, without timing a child.
    owner = nil
    let next = try InstallLock(fs: fs, path: path)
    close(duplicate); duplicate = -1
    _ = withExtendedLifetime(next) {
        // Closing the old reference must neither delay release nor unlock the new owner.
        #expect(throws: LauncherError.busy("install root in use")) { try InstallLock(fs: fs, path: path) }
    }
}

private func duplicateLockDescription(at path: String) throws -> Int32 {
    // The lock intentionally exposes no descriptor. Find only this test's unique lock
    // through the OS, then duplicate it atomically with CLOEXEC just as a spawn retains it.
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    for fd in 0..<getdtablesize() {
        let status = buffer.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        guard status == 0 else { continue }
        let found = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        guard URL(fileURLWithPath: found).resolvingSymlinksInPath().path == path else { continue }
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw LauncherError.io("Cannot duplicate test lock description") }
        return duplicate
    }
    throw LauncherError.io("Cannot find test lock descriptor")
}
