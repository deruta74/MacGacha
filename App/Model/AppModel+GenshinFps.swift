// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import RuntimeManager

@MainActor extension AppModel {
    var genshinFpsRiskAcknowledged: Bool { globalLaunchSettings.genshinFpsRiskAcknowledged }
    func acknowledgeGenshinFpsRisk() { setGlobalLaunchPreference(\.genshinFpsRiskAcknowledged, to: true) }
    func offersGenshinFps(for gameID: String) -> Bool { GenshinFps.applies(to: gameID) }
    func genshinFpsUnlock(for gameID: String) -> Bool { offersGenshinFps(for: gameID) && launchSettings(for: gameID).unlockFPS }
    func genshinFpsTarget(for gameID: String) -> Int { launchSettings(for: gameID).unlockTarget }

    func setGenshinFpsUnlock(_ enabled: Bool, for gameID: String) throws {
        guard offersGenshinFps(for: gameID) else { throw LauncherError.io("Unsupported FPS unlock game") }
        if enabled, !genshinFpsRiskAcknowledged { throw LauncherError.genshinFpsRiskNotAcknowledged }
        var settings = launchSettings(for: gameID)
        if enabled, !settings.unlockFPS, let limit = settings.frameLimit, limit < settings.unlockTarget {
            settings.frameLimit = [30, 60, 90, 120].first { $0 >= settings.unlockTarget }
        }
        settings.unlockFPS = enabled
        try saveLaunchSettings(settings, for: gameID)
    }

    func setGenshinFpsTarget(_ target: Int, for gameID: String) throws {
        guard offersGenshinFps(for: gameID) else { throw LauncherError.io("Unsupported FPS unlock game") }
        var settings = launchSettings(for: gameID)
        settings.unlockTarget = min(360, max(61, target))
        try saveLaunchSettings(settings, for: gameID)
    }
}
