// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
