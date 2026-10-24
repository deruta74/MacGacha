// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import GameLibrary
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct LaunchSettingsStoreTests {
    @Test(arguments: GameDefinition.all.map(\.id)) func settingsStoreRoundTripAndDefaults(game: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let store = LaunchSettingsStore(paths: paths)
            let defaults = try store.load(game)
            #expect(defaults == .defaults(for: game))
            #expect(defaults.backend == .d3dmetal && !defaults.retina && defaults.compatibilityPatches)
            #expect(defaults.frameLimit == (GameDefinition.find(game)?.family == .zzz ? nil : 60))
            #expect(defaults.directX12 == (GameDefinition.find(game)?.family == .zzz))
            #expect(!FileManager.default.fileExists(atPath: paths.games.path))
            var settings = defaults
            settings.backend = .dxmt; settings.retina = true; settings.frameLimit = nil
            settings.directX12 = false; settings.compatibilityPatches = false
            try store.save(settings, for: game)
            #expect(try store.load(game) == settings)
            let file = paths.games.appendingPathComponent(game + "/launch-settings.json")
            #expect(FileManager.default.fileExists(atPath: file.path))
            try Data("not json".utf8).write(to: file)
            #expect(throws: LauncherError.self) { try store.load(game) }
            #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
        }
    }

    @Test(arguments: GameDefinition.all.map(\.id)) func partialJSONUsesGameDefaultsAndIgnoresFutureFields(game: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data(#"{"backend":"dxmt","future":{"version":99}}"#.utf8),
                to: SafeRelativePath("Games/\(game)/launch-settings.json"))
            var expected = LaunchSettings.defaults(for: game); expected.backend = .dxmt
            #expect(try LaunchSettingsStore(paths: paths).load(game) == expected)
        }
    }

    @Test func codablePreservesExplicitOffAndDefaultsMissingFields() throws {
        let decoded = try JSONDecoder().decode(LaunchSettings.self, from: Data("{}".utf8))
        #expect(decoded == .defaults(for: "genshin"))
        var settings = decoded; settings.frameLimit = nil
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func failedAtomicReplacementKeepsOldSettingsAndRemovesTemporary() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let store = LaunchSettingsStore(paths: paths), old = LaunchSettings.defaults(for: "genshin")
            try store.save(old, for: "genshin")
            var changed = old; changed.retina = true
            let failing = LaunchSettingsStore(paths: paths, fileOps: SettingsRenameFailure())
            #expect(throws: LauncherError.self) { try failing.save(changed, for: "genshin") }
            #expect(try store.load("genshin") == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.games.appendingPathComponent("genshin").path) == ["launch-settings.json"])
            try store.save(changed, for: "genshin")
            #expect(try store.load("genshin") == changed)
        }
    }

    @Test func orphanReconciliationPreservesSettings() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let settings = LaunchSettings.defaults(for: "genshin")
            try LaunchSettingsStore(paths: paths).save(settings, for: "genshin")
            let records = GameRecordStore(directory: paths.games)
            let lease = try await records.acquireOperationLease()
            defer { withExtendedLifetime(lease) {} }
            try await records.cleanupOrphanGameDirectory("genshin")
            #expect(try LaunchSettingsStore(paths: paths).load("genshin") == settings)
            #expect(FileManager.default.fileExists(atPath: paths.games.appendingPathComponent("genshin/launch-settings.json").path))
        }
    }

    @Test func operationOwnershipPreventsSweepingAnActiveSettingsWrite() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let store = LaunchSettingsStore(paths: paths), old = LaunchSettings.defaults(for: "genshin")
            try store.save(old, for: "genshin")
            let records = GameRecordStore(directory: paths.games), lease = try await records.acquireOperationLease()
            defer { withExtendedLifetime(lease) {} }
            var changed = old; changed.retina = true
            #expect(throws: LauncherError.self) { try store.save(changed, for: "genshin") }
            #expect(try store.load("genshin") == old)
        }
    }

    @Test(arguments: ["../escape", "unknown"]) func invalidGameCannotReadOrSaveSettings(game: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), store = LaunchSettingsStore(paths: AppPaths(root: temp.url))
            #expect(throws: LauncherError.self) { try store.load(game) }
            #expect(throws: LauncherError.self) { try store.save(.defaults(for: "genshin"), for: game) }
        }
    }

    @Test func invalidFrameLimitCannotBeSavedOrLoaded() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), store = LaunchSettingsStore(paths: paths)
            var invalid = LaunchSettings.defaults(for: "genshin"); invalid.frameLimit = 144
            #expect(throws: LauncherError.self) { try store.save(invalid, for: "genshin") }
            try ContainedFileSystem(root: temp.url).writeAtomically(Data(#"{"frameLimit":144}"#.utf8),
                to: SafeRelativePath("Games/genshin/launch-settings.json"))
            #expect(throws: LauncherError.self) { try store.load("genshin") }
        }
    }

    @Test func symlinkedSettingsCannotEscapeTheStore() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), store = LaunchSettingsStore(paths: paths)
            try store.save(.defaults(for: "genshin"), for: "genshin")
            let file = paths.games.appendingPathComponent("genshin/launch-settings.json"), target = temp.url.appendingPathComponent("outside.json")
            let original = Data("{}".utf8); try original.write(to: target)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            #expect(throws: LauncherError.self) { try store.load("genshin") }
            #expect(throws: LauncherError.self) { try store.save(.defaults(for: "genshin"), for: "genshin") }
            #expect(try Data(contentsOf: target) == original)
        }
    }
}

private struct SettingsRenameFailure: FileOps {
    private let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to destination: String, in dst: Int32, exclusive: Bool) throws {
        throw LauncherError.io("Injected settings rename failure")
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try base.unlink(name, in: directory, isDirectory: isDirectory) }
}
