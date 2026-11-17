// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

@MainActor extension AppModel {
    /// Decimal bytes per second the user can type: 0.1 to 10,000 MB/s in 0.1 MB/s steps.
    static let downloadSpeedLimitRange: ClosedRange<Int64> = 100_000...10_000_000_000
    static let downloadSpeedLimitStep: Int64 = 100_000
    /// The value offered when the limit is first turned on.
    static let defaultDownloadSpeedLimit: Int64 = 10_000_000
    var downloadSpeedLimit: Int64? { globalLaunchSettings.downloadSpeedLimit }

    /// A nil limit means Unlimited.
    func setDownloadSpeedLimit(_ bytesPerSecond: Int64?) throws {
        if let bytesPerSecond {
            guard Self.downloadSpeedLimitRange.contains(bytesPerSecond), bytesPerSecond % Self.downloadSpeedLimitStep == 0 else {
                throw LauncherError.io("Invalid download speed limit")
            }
        }
        var settings = globalLaunchSettings
        settings.downloadSpeedLimit = bytesPerSecond
        try saveGlobalLaunchSettings(settings)
    }

    /// Rounds a typed megabytes-per-second value to a valid limit.
    static func downloadSpeedLimit(megabytesPerSecond: Double) -> Int64 {
        let step = Double(downloadSpeedLimitStep)
        let lower = Double(downloadSpeedLimitRange.lowerBound), upper = Double(downloadSpeedLimitRange.upperBound)
        guard !megabytesPerSecond.isNaN else { return downloadSpeedLimitRange.lowerBound }
        return Int64(min(max((megabytesPerSecond * 1_000_000 / step).rounded() * step, lower), upper))
    }
}
