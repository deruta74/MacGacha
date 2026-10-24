// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI
import LauncherCore

/// The games MacGacha knows. Art is never bundled: it comes from the official
/// HoYoPlay API at run time and is cached locally (see `AppModel.gameArt`).
struct LauncherGame: Identifiable, Hashable {
    let id: String
    let name: String
    var region: Region { GameDefinition.find(id)?.region ?? .global }
    /// Fallback colors while art loads or when offline.
    let tint: Color
    let deepTint: Color
}

extension LauncherGame {
    static let all: [LauncherGame] = GameDefinition.all.map { definition in
        let name: String, tint: Color, deepTint: Color
        switch definition.family {
        case .genshin:
            name = definition.region == .global ? String(localized: "Genshin Impact") : String(localized: "原神", comment: "Mainland China edition; keep the official Chinese name in every language")
            tint = Color(red: 0.98, green: 0.78, blue: 0.46); deepTint = Color(red: 0.16, green: 0.22, blue: 0.38)
        case .starrail:
            name = definition.region == .global ? String(localized: "Honkai: Star Rail") : String(localized: "崩坏：星穹铁道", comment: "Mainland China edition; keep the official Chinese name in every language")
            tint = Color(red: 0.69, green: 0.66, blue: 0.93); deepTint = Color(red: 0.10, green: 0.08, blue: 0.24)
        case .zzz:
            name = definition.region == .global ? String(localized: "Zenless Zone Zero") : String(localized: "绝区零", comment: "Mainland China edition; keep the official Chinese name in every language")
            tint = Color(red: 0.85, green: 0.93, blue: 0.30); deepTint = Color(red: 0.10, green: 0.10, blue: 0.10)
        }
        return LauncherGame(id: definition.id, name: name, tint: tint, deepTint: deepTint)
    }
    static func games(in region: Region) -> [LauncherGame] { all.filter { $0.region == region } }

    var defaultInstallDirectoryName: String {
        GameDefinition.find(id)?.defaultInstallDirectoryName ?? name
    }

}

