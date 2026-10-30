// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport
import Launch

private let mainDisplay = "00000000-0000-0000-0000-000000000001"
private let secondDisplay = "00000000-0000-0000-0000-000000000002"

@Suite struct DisplayChoiceTests {
    @Test func oldSettingsDefaultToMainAndChoiceRoundTrips() async throws {
        let old = try JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8))
        #expect(old.display == nil)
        var settings = old
        settings.display = DisplayChoice(id: secondDisplay, name: "Second screen")
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let saved = settings
        try await BlockingIO.run {
            let temp = try TempDir(), store = LaunchSettingsStore(paths: AppPaths(root: temp.url))
            try store.save(saved, for: "genshin")
            #expect(try store.load("genshin") == saved)
            #expect(try store.load("genshin-cn").display == nil)
        }
    }

    @Test(arguments: ["not-a-uuid", "", "../screen"]) func invalidDisplayIDIsRejected(id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["display": ["id": id, "name": "Screen"]])
        #expect(throws: LauncherError.self) { try JSONDecoder().decode(LaunchSettings.self, from: data) }
    }

    @Test func invalidDisplayNameIsRejected() throws {
        let data = try JSONSerialization.data(withJSONObject: ["display": ["id": mainDisplay, "name": String(repeating: "x", count: 257)]])
        #expect(throws: LauncherError.self) { try JSONDecoder().decode(LaunchSettings.self, from: data) }
    }

}
