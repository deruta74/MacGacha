// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Nested under the single Europe & Americas card in getGames.
struct HonkaiServerConfig: Decodable {
    let game_id: String?
    let i18n_description: String?

    var server: HonkaiImpactServer? { HonkaiImpactServer.allCases.first { $0.gameID == game_id } }

    static func displayDescription(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, value.utf8.count <= 256,
            value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }
}
