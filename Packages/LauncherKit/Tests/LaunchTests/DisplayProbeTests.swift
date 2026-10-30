// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import Synchronization
import LauncherCore
@testable import Launch

@Suite struct DisplayProbeTests {
    @Test func onlineEnumerationKeepsSleepingDisplayBeforeSelectedMonitor() throws {
        let main = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000001", name: "Main", isMain: true)
        let sleeping = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000002", name: "", isMain: false)
        let awake = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000003", name: "Awake", isMain: false)
        let follower = ConnectedDisplay(id: "00000000-0000-0000-0000-000000000004", name: "Mirror", isMain: false)
        let requested = Mutex<[SystemDisplayProbe.DisplayList]>([])
        let probe = SystemDisplayProbe { list in
            requested.withLock { $0.append(list) }
            switch list {
            case .active: return [(main, false), (awake, false)]
            case .online: return [(main, false), (sleeping, false), (follower, true), (awake, false)]
            }
        }
        let displays = probe.connectedDisplays()
        #expect(requested.withLock { $0 } == [.online])
        #expect(displays == [main, sleeping, awake])
        var settings = LaunchSettings.defaults(for: "genshin")
        settings.compatibilityPatches = false
        settings.display = DisplayChoice(id: awake.id, name: awake.name)
        let resolved = try LaunchResolver.resolve(recipe: #require(Recipes.recipe(for: "genshin")), settings: settings,
            installRoot: URL(fileURLWithPath: "/games"), prefix: URL(fileURLWithPath: "/prefix"),
            wineBinary: URL(fileURLWithPath: "/runtime/wine"), proxyPort: 1, componentRoots: [:],
            baseEnvironment: [:], displays: displays.map(\.id))
        #expect(resolved.arguments == [#"Z:\games\GenshinImpact.exe"#, "-monitor", "3"])
        #expect(!resolved.displayFallback)
    }

    @Test func mirrorSourceIsKeptWhileItsFollowersAreExcluded() {
        let main = ConnectedDisplay(id: "main", name: "", isMain: true)
        let source = ConnectedDisplay(id: "source", name: "", isMain: false)
        let follower = ConnectedDisplay(id: "follower", name: "", isMain: false)
        #expect(SystemDisplayProbe.ordered([(source, false), (follower, true), (main, false)]) == [main, source])
    }

    @Test func orderingPutsMainFirstAndDropsMirrorsWithoutSortingOthers() {
        let a = ConnectedDisplay(id: "a", name: "", isMain: false)
        let b = ConnectedDisplay(id: "b", name: "", isMain: true)
        let c = ConnectedDisplay(id: "c", name: "", isMain: false)
        let mirror = ConnectedDisplay(id: "mirror", name: "", isMain: false)
        #expect(SystemDisplayProbe.ordered([(a, false), (mirror, true), (b, false), (c, false)]) == [b, a, c])
        #expect(SystemDisplayProbe.ordered([]).isEmpty)
    }

}
