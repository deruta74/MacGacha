// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import TestSupport

@Suite struct ChinaLogFilesTests {
    @Test func logDiscoverySeparatesHyphenatedEditions() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            for game in GameDefinition.all {
                let prefix = try SafeRelativePath("Prefixes/\(game.id)-bundle/drive_c/users/player")
                try fs.createDirectory(at: prefix)
                try fs.writeAtomically(Data("session".utf8), to: SafeRelativePath("Logs/\(game.id)-20261024-120000.log"))
            }
            let candidates = try LaunchLogFiles.gameLogCandidates(in: temp.url.appendingPathComponent("Prefixes"))
            #expect(Set(candidates.keys) == Set(GameDefinition.all.map(\.id)))
            for game in GameDefinition.all {
                let paths = try #require(candidates[game.id])
                #expect(paths.count == LaunchLogFiles.gameLogPaths(for: game.id).count)
                #expect(paths.allSatisfy { $0.description.hasPrefix("\(game.id)-bundle/") })
            }
            let logs = try LaunchLogFiles.latestSessionLogURLs(in: temp.url.appendingPathComponent("Logs"))
            #expect(Set(logs.compactMap { LaunchLogFiles.parseName($0.lastPathComponent)?.game }) == Set(GameDefinition.all.map(\.id)))
        }
    }
}
