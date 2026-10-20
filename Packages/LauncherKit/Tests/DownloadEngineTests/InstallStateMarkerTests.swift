// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func installMarkerIsTypedAtomicAndFailsClosed() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let id = try SafeIdentifier("build")
    try InstallStateMarker.requireIdle(fs: fs)
    let marker = InstallStateMarker(planID: id)
    try marker.write(fs: fs)
    #expect(try InstallStateMarker.load(fs: fs) == marker)
    #expect(throws: LauncherError.busy("install is updating")) { try InstallStateMarker.requireIdle(fs: fs) }
    try InstallStateMarker.clear(fs: fs, matching: id)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    let path = try SafeRelativePath(".macgacha-state.json")
    for text in ["broken", "{\"state\":\"updating\",\"planID\":\"../escape\"}", "{\"state\":\"ready\",\"planID\":\"build\"}"] {
        try fs.writeAtomically(Data(text.utf8), to: path)
        #expect(throws: LauncherError.journalCorrupt("Invalid install state marker")) { try InstallStateMarker.load(fs: fs) }
        #expect(throws: LauncherError.busy("install is updating")) { try InstallStateMarker.requireIdle(fs: fs) }
    }
}
