// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

@MainActor extension AppModel {
    /// Decimal bytes per second. A nil selection means Unlimited.
    static let downloadSpeedLimitOptions: [Int64?] = [nil, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000]
    var downloadSpeedLimit: Int64? { globalLaunchSettings.downloadSpeedLimit }

    func setDownloadSpeedLimit(_ bytesPerSecond: Int64?) throws {
        guard Self.downloadSpeedLimitOptions.contains(bytesPerSecond) else { throw LauncherError.io("Invalid download speed limit") }
        var settings = globalLaunchSettings
        settings.downloadSpeedLimit = bytesPerSecond
        try saveGlobalLaunchSettings(settings)
    }
}
