// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public enum GameFamily: String, Sendable, Hashable, CaseIterable { case genshin, starrail, zzz }

public struct VoiceOption: Sendable, Hashable {
    public let code: String
    public let name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
}

public struct GameDefinition: Sendable, Hashable, Identifiable {
    public let id: String
    public let biz: String
    public let region: Region
    public let gameID: String
    public let voices: [VoiceOption]
    public let family: GameFamily
    public init(id: String, biz: String, region: Region = .global, gameID: String, voices: [VoiceOption], family: GameFamily? = nil) {
        self.id = id; self.biz = biz; self.region = region; self.gameID = gameID; self.voices = voices
        self.family = family ?? (biz.hasPrefix("hkrpg_") ? .starrail : biz.hasPrefix("nap_") ? .zzz : .genshin)
    }

    public static func find(_ id: String) -> Self? { all.first { $0.id == id } }
    public static func inRegion(_ region: Region) -> [Self] { all.filter { $0.region == region } }

    public var executableName: String {
        switch family {
        case .genshin: region == .global ? "GenshinImpact.exe" : "YuanShen.exe"
        case .starrail: "StarRail.exe"
        case .zzz: "ZenlessZoneZero.exe"
        }
    }
    public var dataDirectoryName: String { String(executableName.dropLast(4)) + "_Data" }
    /// Folder names are edition identities, independent of the interface language.
    public var defaultInstallDirectoryName: String {
        switch (family, region) {
        case (.genshin, .global): "Genshin Impact"
        case (.starrail, .global): "Honkai: Star Rail"
        case (.zzz, .global): "Zenless Zone Zero"
        case (.genshin, .mainlandChina): "原神"
        case (.starrail, .mainlandChina): "崩坏星穹铁道"
        case (.zzz, .mainlandChina): "绝区零"
        }
    }
    /// Canonical system app identity, independent of the interface language.
    public var gameApplicationName: String {
        region == .mainlandChina ? unityLogProductName : defaultInstallDirectoryName
    }

    /// Unity's product name differs from the installation directory name.
    public var unityLogProductName: String {
        switch (family, region) {
        case (.genshin, .global): "Genshin Impact"
        case (.starrail, .global): "Star Rail"
        case (.zzz, .global): "ZenlessZoneZero"
        case (.genshin, .mainlandChina): "原神"
        case (.starrail, .mainlandChina): "崩坏：星穹铁道"
        case (.zzz, .mainlandChina): "绝区零"
        }
    }

    public static let all: [GameDefinition] = {
        let voices = [VoiceOption(code: "zh-cn", name: "Chinese"), VoiceOption(code: "en-us", name: "English"),
            VoiceOption(code: "ja-jp", name: "Japanese"), VoiceOption(code: "ko-kr", name: "Korean")]
        return [GameDefinition(id: "genshin", biz: "hk4e_global", region: .global, gameID: "gopR6Cufr3", voices: voices, family: .genshin),
            GameDefinition(id: "starrail", biz: "hkrpg_global", region: .global, gameID: "4ziysqXOQ8", voices: voices, family: .starrail),
            GameDefinition(id: "zzz", biz: "nap_global", region: .global, gameID: "U5hbdsT9W7", voices: voices, family: .zzz),
            GameDefinition(id: "genshin-cn", biz: "hk4e_cn", region: .mainlandChina, gameID: "1Z8W5NHUQb", voices: voices, family: .genshin),
            GameDefinition(id: "starrail-cn", biz: "hkrpg_cn", region: .mainlandChina, gameID: "64kMb5iAWu", voices: voices, family: .starrail),
            GameDefinition(id: "zzz-cn", biz: "nap_cn", region: .mainlandChina, gameID: "x6znKlJ0xK", voices: voices, family: .zzz)]
    }()
}
