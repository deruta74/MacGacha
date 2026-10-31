// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch

@MainActor extension AppModel {
    func surroundSound(for gameID: String) -> Bool { launchSettings(for: gameID).surroundSound }

    func setSurroundSound(_ enabled: Bool, for gameID: String) throws {
        var settings = launchSettings(for: gameID)
        settings.surroundSound = enabled
        try saveLaunchSettings(settings, for: gameID)
    }

    func offersSurround(for gameID: String) -> Bool {
        let settings = launchSettings(for: gameID)
        return LaunchResolver.offersSurroundSound(gameID, backend: settings.backend,
            runtimeBundleID: manifest?.defaultBundle(for: settings.backend)?.id.rawValue)
    }
}
