// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import TestSupport
@testable import LauncherCore

@Suite(.timeLimit(.minutes(1))) struct GlobalLaunchSettingsTests {
    @Test func gameModeDefaultsOnAndRoundTripsGlobally() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), store = GlobalLaunchSettingsStore(paths: AppPaths(root: temp.url))
            #expect(try store.load().gameModeEnabled)
            #expect(try JSONDecoder().decode(GlobalLaunchSettings.self, from: Data(#"{"sessionLogsEnabled":false}"#.utf8)).gameModeEnabled)
            try store.save(GlobalLaunchSettings(sessionLogsEnabled: false, gameModeEnabled: false))
            #expect(try !store.load().gameModeEnabled)
            #expect(try !store.load().sessionLogsEnabled)
        }
    }

    @Test func loggingDefaultsOnAndRoundTripsGlobally() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let store = GlobalLaunchSettingsStore(paths: paths)
            #expect(try store.load().sessionLogsEnabled)
            #expect(try JSONDecoder().decode(GlobalLaunchSettings.self, from: Data("{}".utf8)).sessionLogsEnabled)
            try store.save(GlobalLaunchSettings(sessionLogsEnabled: false))
            #expect(try !GlobalLaunchSettingsStore(paths: paths).load().sessionLogsEnabled)
            #expect(!FileManager.default.fileExists(atPath: paths.games.path))
            let fs = try ContainedFileSystem(root: paths.root)
            try fs.writeAtomically(Data(#"{"sessionLogsEnabled":true,"future":42}"#.utf8), to: SafeRelativePath("launch-settings.json"))
            #expect(try store.load().sessionLogsEnabled)
            try fs.writeAtomically(Data("broken".utf8), to: SafeRelativePath("launch-settings.json"))
            #expect(throws: LauncherError.self) { try store.load() }
        }
    }
}
