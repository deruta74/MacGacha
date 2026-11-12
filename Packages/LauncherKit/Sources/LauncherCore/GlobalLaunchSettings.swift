// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Global preferences, separate from each game's launch recipe settings.
public struct GlobalLaunchSettings: Codable, Equatable, Sendable {
    public var sessionLogsEnabled: Bool
    public var gameModeEnabled: Bool
    public var autoUpdateDependencies: Bool
    public var genshinFpsRiskAcknowledged: Bool
    public init(sessionLogsEnabled: Bool = true, gameModeEnabled: Bool = true, genshinFpsRiskAcknowledged: Bool = false,
        autoUpdateDependencies: Bool = true) {
        self.sessionLogsEnabled = sessionLogsEnabled; self.gameModeEnabled = gameModeEnabled
        self.genshinFpsRiskAcknowledged = genshinFpsRiskAcknowledged
        self.autoUpdateDependencies = autoUpdateDependencies
    }
    private enum CodingKeys: CodingKey { case sessionLogsEnabled, gameModeEnabled, genshinFpsRiskAcknowledged, autoUpdateDependencies }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionLogsEnabled = try values.decodeIfPresent(Bool.self, forKey: .sessionLogsEnabled) ?? true
        gameModeEnabled = try values.decodeIfPresent(Bool.self, forKey: .gameModeEnabled) ?? true
        autoUpdateDependencies = try values.decodeIfPresent(Bool.self, forKey: .autoUpdateDependencies) ?? true
        genshinFpsRiskAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .genshinFpsRiskAcknowledged) ?? false
    }
}

/// Blocking filesystem I/O; async callers use BlockingIO.run.
public struct GlobalLaunchSettingsStore: Sendable {
    private let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }
    public func load() throws -> GlobalLaunchSettings {
        let fs = try ContainedFileSystem(root: paths.root)
        let path = try SafeRelativePath("launch-settings.json")
        guard try fs.itemType(at: path) != nil else { return GlobalLaunchSettings() }
        let bytes = try fs.readFile(at: path, maxBytes: 65_536)
        do { return try JSONDecoder().decode(GlobalLaunchSettings.self, from: bytes) }
        catch { throw LauncherError.io("Invalid global launch settings") }
    }
    public func save(_ settings: GlobalLaunchSettings) throws {
        let fs = try ContainedFileSystem(root: paths.root)
        try fs.createRootDurably()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try fs.writeAtomically(encoder.encode(settings), to: SafeRelativePath("launch-settings.json"))
    }
}
