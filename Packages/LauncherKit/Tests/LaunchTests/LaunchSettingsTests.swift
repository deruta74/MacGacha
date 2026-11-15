// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

@Suite struct LaunchSettingsTests {
    @Test func metalHUDOptionsAlwaysEncodeLegacyDefaults() throws {
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"metalHUD":true}"#.utf8))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["metalHUDContents"] as? String == "standard")
        #expect(encoded["metalHUDElements"] as? [String] == ["fps", "frameinterval", "gputime"])
        #expect(encoded["metalHUDPosition"] as? String == "topright")
        #expect(encoded["metalHUDSize"] as? String == "standard")
    }

    @Test(arguments: MetalHUDContents.allCases, MetalHUDPosition.allCases)
    func metalHUDOptionsRoundTrip(contents: MetalHUDContents, position: MetalHUDPosition) throws {
        for size in MetalHUDSize.allCases {
            var settings = LaunchSettings.defaults(for: "genshin")
            settings.metalHUDContents = contents
            settings.metalHUDElements = MetalHUDElement.allCases
            settings.metalHUDPosition = position
            settings.metalHUDSize = size
            #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test func unknownMetalHUDValuesUseDefaultsAndDropUnknownElements() throws {
        let data = Data(#"{"metalHUD":true,"metalHUDContents":"future","metalHUDPosition":"elsewhere","metalHUDSize":"huge","metalHUDElements":["fps","future","gputime","fps"]}"#.utf8)
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: data)
        #expect(settings.metalHUDContents == .standard)
        #expect(settings.metalHUDPosition == .topRight)
        #expect(settings.metalHUDSize == .standard)
        #expect(settings.metalHUDElements == [.fps, .gputime])
        #expect(settings.metalHUD)
    }

    @Test func customRequiresAtLeastOneKnownElement() throws {
        var settings = LaunchSettings.defaults(for: "genshin")
        settings.metalHUDElements = []
        try settings.validate()
        settings.metalHUDContents = .custom
        #expect(throws: LauncherError.self) { try settings.validate() }
        settings.metalHUDElements = [.fps, .fps]
        try settings.validate()
    }

    @Test(arguments: [#"[]"#, #"["future"]"#, #"["fps","fps"]"#])
    func decodedElementsAreDistinctAndNeverEmpty(elements: String) throws {
        // Custom must stay reachable and editable: duplicates would defeat the
        // last-element guard, and an empty list would make Custom invalid.
        for contents in ["standard", "custom"] {
            let json = #"{"metalHUDContents":"\#(contents)","metalHUDElements":\#(elements)}"#
            let settings = try JSONDecoder().decode(LaunchSettings.self, from: Data(json.utf8))
            #expect(Set(settings.metalHUDElements).count == settings.metalHUDElements.count)
            #expect(!settings.metalHUDElements.isEmpty)
            try settings.validate()
        }
    }

    @Test func metalHUDElementsHaveStableLibMTLHudOrder() throws {
        let names = ["device", "rosetta", "layersize", "memory", "refreshrate", "thermal", "gamemode",
            "fps", "fpsgraph", "frameinterval", "frameintervalgraph", "gputime", "presentdelay"]
        #expect(MetalHUDElement.allCases.map(\.rawValue) == names)
        for element in MetalHUDElement.allCases {
            #expect(try JSONDecoder().decode(MetalHUDElement.self, from: JSONEncoder().encode(element)) == element)
        }
        #expect(MetalHUDContents.custom.elementString(custom: MetalHUDElement.allCases.reversed()
            + [.fps, .device]) == names.joined(separator: ","))
    }

    @Test func sessionSettingsDumpIncludesHUDOptions() {
        var settings = LaunchSettings.defaults(for: "genshin")
        settings.metalHUDContents = .custom
        settings.metalHUDElements = [.fps, .thermal]
        settings.metalHUDPosition = .bottomRight
        settings.metalHUDSize = .large
        let dump = String(describing: settings)
        for field in ["metalHUDContents", "custom", "metalHUDElements", "fps", "thermal",
            "metalHUDPosition", "bottomRight", "metalHUDSize", "large"] {
            #expect(dump.contains(field))
        }
    }

    @Test func metalHUDSizesExposeExactScaleStrings() {
        #expect(MetalHUDSize.small.scaleString == "0.15")
        #expect(MetalHUDSize.standard.scaleString == nil)
        #expect(MetalHUDSize.large.scaleString == "0.3")
    }

    @Test func legacySettingsDecodeWithMetalHUDOff() throws {
        let data = Data(#"{"backend":"dxmt","retina":true,"frameLimit":90,"directX12":false,"compatibilityPatches":false,"unlockFPS":true,"unlockTarget":120,"surroundSound":true}"#.utf8)
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: data)
        #expect(!settings.metalHUD)
        #expect(settings.backend == .dxmt && settings.retina && settings.frameLimit == 90)
        #expect(!settings.directX12 && !settings.compatibilityPatches)
        #expect(settings.unlockFPS && settings.unlockTarget == 120 && settings.surroundSound)
    }

    @Test(arguments: GameDefinition.all.map(\.id)) func metalHUDDefaultsOff(game: String) {
        let settings = LaunchSettings.defaults(for: game)
        #expect(!settings.metalHUD)
        #expect(settings.metalHUDContents == .standard)
        #expect(settings.metalHUDElements == [.fps, .frameinterval, .gputime])
        #expect(settings.metalHUDPosition == .topRight)
        #expect(settings.metalHUDSize == .standard)
    }

    @Test(arguments: [false, true]) func metalHUDAlwaysEncodesAndRoundTrips(enabled: Bool) throws {
        var settings = LaunchSettings.defaults(for: "genshin-cn")
        settings.metalHUD = enabled
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["metalHUD"] as? Bool == enabled)
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: data) == settings)
    }

    @Test func legacySettingsDecodeWithUnlockOff() throws {
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"backend":"dxmt","frameLimit":60}"#.utf8))
        #expect(!settings.unlockFPS && settings.unlockTarget == 120)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(encoded["unlockFPS"] as? Bool == false && encoded["unlockTarget"] as? Int == 120)
    }
    @Test func unlockSettingsRoundTrip() throws {
        var settings = LaunchSettings.defaults(for: "genshin-cn")
        settings.unlockFPS = true; settings.unlockTarget = 360
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func ninetyIsAValidFrameLimit() throws {
        var settings = LaunchSettings.defaults(for: "genshin"); settings.frameLimit = 90
        try settings.validate()
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.frameLimit = 45
        #expect(throws: LauncherError.self) { try settings.validate() }
    }
    @Test(arguments: [60, 61, 120, 360, 361]) func unlockTargetBounds(target: Int) throws {
        var settings = LaunchSettings.defaults(for: "genshin"); settings.unlockFPS = true; settings.unlockTarget = target
        if (61...360).contains(target) { try settings.validate() }
        else { #expect(throws: LauncherError.self) { try settings.validate() } }
    }
    @Test(arguments: ["starrail", "starrail-cn"]) func starRailOnlyUnlocksTo120(game: String) async throws {
        var settings = LaunchSettings.defaults(for: game); settings.unlockFPS = true
        try settings.validate(for: game)
        settings.unlockTarget = 90
        #expect(throws: LauncherError.self) { try settings.validate(for: game) }
        let invalid = settings
        try await BlockingIO.run {
            let root = try TempDir(), paths = AppPaths(root: root.url)
            #expect(throws: LauncherError.self) { try LaunchSettingsStore(paths: paths).save(invalid, for: game) }
            let decoder = JSONDecoder(); decoder.userInfo[LaunchSettings.gameKey] = game
            #expect(throws: LauncherError.self) { try decoder.decode(LaunchSettings.self, from: JSONEncoder().encode(invalid)) }
        }
    }
}
