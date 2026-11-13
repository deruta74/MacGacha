// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore

@Suite struct GameLocationTests {
    @Test(arguments: ["/Volumes/Games SSD/MacGacha/Game", "/System/Volumes/Data/Volumes/Games SSD/Game"])
    func derivesDisplayNameAndCanonicalVolumeFromPath(path: String) {
        let root = URL(fileURLWithPath: path)
        #expect(GameLocation.volumeDisplayName(for: root) == "Games SSD")
        #expect(GameLocation.volumeRoot(for: root) == URL(fileURLWithPath: "/Volumes/Games SSD", isDirectory: true))
    }

    @Test(arguments: ["/Users/player/Games", "/Volumes", "/VolumesOther/SSD/Game", "/System/Volumes/Data/Users/player"])
    func internalPathsHaveNoExternalDriveHint(path: String) {
        #expect(GameLocation.volumeDisplayName(for: URL(fileURLWithPath: path)) == nil)
    }

    @Test func leftoverMountDirectoryDoesNotEstablishAvailability() throws {
        let probe = SystemGameLocationProbe(mountedVolumes: { [URL(fileURLWithPath: "/")] })
        #expect(throws: LauncherError.installVolumeUnavailable) {
            try probe.requireAvailable(at: URL(fileURLWithPath: "/Volumes/Games SSD/Game"))
        }
        try probe.requireAvailable(at: URL(fileURLWithPath: "/Users/player/Games"))
    }

    @Test func mountedVolumeMustMatchWholeName() throws {
        let probe = SystemGameLocationProbe(mountedVolumes: { [URL(fileURLWithPath: "/Volumes/Games SSD 2")] })
        #expect(throws: LauncherError.installVolumeUnavailable) {
            try probe.requireAvailable(at: URL(fileURLWithPath: "/Volumes/Games SSD/Game"))
        }
        try probe.requireAvailable(at: URL(fileURLWithPath: "/System/Volumes/Data/Volumes/Games SSD 2/Game"))
    }
}
