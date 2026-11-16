// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport
@testable import Launch

@Suite struct WinePrefixResetTests {
    @Test func removesOnlyExactEditionPrefixesAndPreservesOtherData() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        for path in ["Prefixes/genshin-dxmt/keep", "Prefixes/genshin-old-bundle/keep", "Prefixes/genshin-cn-dxmt/keep",
                     "Prefixes/zzz-dxmt/keep", "Games/genshin/record.json", "Games/genshin/recovery/keep", "launch-settings.json", "game/ScreenShot/photo"] {
            try fs.writeAtomically(Data("saved".utf8), to: SafeRelativePath(path))
        }
        try await WinePrefixResetter(paths: paths, inspector: ResetIdleInspector()).reset(game: "genshin")
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == nil)
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-old-bundle")) == nil)
        for path in ["Prefixes/genshin-cn-dxmt/keep", "Prefixes/zzz-dxmt/keep", "Games/genshin/record.json",
                     "Games/genshin/recovery/keep", "launch-settings.json", "game/ScreenShot/photo"] {
            #expect(try fs.readFile(at: SafeRelativePath(path), maxBytes: 100) == Data("saved".utf8))
        }
    }

    @Test(arguments: ["Games/genshin/launch-session.json", "Games/genshin/move-journal.json"])
    func durableJournalBlocksEvenWhenUnreadable(path: String) async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt"))
        try fs.writeAtomically(Data("malformed".utf8), to: SafeRelativePath(path))
        await #expect(throws: LauncherError.self) { try await WinePrefixResetter(paths: paths, inspector: ResetIdleInspector()).reset(game: "genshin") }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == .directory)
    }

    @Test(arguments: ["Games/genshin/.session.lock", "Prefixes/.macgacha-prefix-genshin-dxmt.lock"])
    func heldExclusionBlocksDeletion(path: String) async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt"))
        let lock = try InstallLock(fs: fs, path: SafeRelativePath(path))
        defer { withExtendedLifetime(lock) {} }
        await #expect(throws: LauncherError.self) { try await WinePrefixResetter(paths: paths, inspector: ResetIdleInspector()).reset(game: "genshin") }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == .directory)
    }

    @Test(arguments: [false, true]) func liveOrUncertainWinePreservesEveryPrefix(uncertain: Bool) async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        for name in ["genshin-dxmt", "genshin-d3dmetal"] { try fs.createDirectory(at: SafeRelativePath("Prefixes/\(name)")) }
        let inspector = ResetIdleInspector { prefix in
            if uncertain { throw LauncherError.io("Unknown process state") }
            return prefix.hasSuffix("-dxmt") ? [InspectedProcess(identity: ProcessIdentity(pid: 123, startTime: 456), executablePath: "/fake/wine", arguments: [])] : []
        }
        await #expect(throws: LauncherError.self) { try await WinePrefixResetter(paths: paths, inspector: inspector).reset(game: "genshin") }
        for name in ["genshin-dxmt", "genshin-d3dmetal"] { #expect(try fs.itemType(at: SafeRelativePath("Prefixes/\(name)")) == .directory) }
    }

    @Test func escapingPrefixIsRejectedAndTargetsSurvive() async throws {
        let temp = try TempDir(), outside = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        let target = try ContainedFileSystem(root: outside.url)
        try target.writeAtomically(Data("saved".utf8), to: SafeRelativePath("keep"))
        try fs.createSymbolicLink(at: SafeRelativePath("Prefixes/genshin-dxmt"), target: outside.url.path)
        await #expect(throws: LauncherError.self) { try await WinePrefixResetter(paths: AppPaths(root: temp.url), inspector: ResetIdleInspector()).reset(game: "genshin") }
        #expect(try target.readFile(at: SafeRelativePath("keep"), maxBytes: 100) == Data("saved".utf8))
    }

    @Test func invalidWineNamespaceBlocksResetWithoutProcesses() async throws {
        let temp = try TempDir(), namespace = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt"))
        // A private Wine namespace must be mode 0700. Uncertain ownership is busy.
        let reset = WinePrefixResetter(paths: AppPaths(root: temp.url), inspector: ResetIdleInspector(), wineServerRoot: namespace.url)
        await #expect(throws: LauncherError.self) { try await reset.reset(game: "genshin") }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == .directory)
    }

    @Test func componentRemovalBlocksResetAndPinsSurviveUntilDeletion() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        let record = try InstalledComponent(kind: .wine, version: "1", installedAt: Date(), source: .download)
        try fs.writeAtomically(JSONEncoder().encode(record), to: SafeRelativePath("Runtimes/wine/1/.macgacha-component.json"))
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt"))
        do {
            let lock = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-1.lock"))
            defer { withExtendedLifetime(lock) {} }
            await #expect(throws: LauncherError.self) { try await WinePrefixResetter(paths: paths, inspector: ResetIdleInspector()).reset(game: "genshin") }
        }
        let reset = WinePrefixResetter(paths: paths, inspector: ResetIdleInspector(), beforeReset: {
            #expect(throws: LauncherError.self) { try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-1.lock")) }
            #expect(throws: LauncherError.self) { try SessionLock.acquire(paths: paths, game: "genshin") }
        })
        try await reset.reset(game: "genshin")
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == nil)
        let released = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-1.lock"))
        withExtendedLifetime(released) {}
    }

    @Test func cancellationBeforeDeletionPreservesPrefix() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await WinePrefixResetter(paths: paths, inspector: ResetIdleInspector()).reset(game: "genshin")
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == .directory)
    }

    @Test func resetIsIdempotentAndNextPreparationRecreatesPrefix() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        let reset = WinePrefixResetter(paths: paths, inspector: ResetIdleInspector())
        let manager = PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: ResetIdleInspector())
        let binary = try SafeRelativePath("Runtimes/fake/bin/wine")
        try fs.writeAtomically(Data("fake".utf8), to: binary)
        _ = try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: binary.resolved(against: paths.root))
        try await reset.reset(game: "genshin")
        try await reset.reset(game: "genshin")
        _ = try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: binary.resolved(against: paths.root))
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt/.macgacha-prefix.json")) == .regularFile)
    }
}

private struct ResetIdleInspector: ProcessInspector {
    var inspect: @Sendable (String) throws -> [InspectedProcess] = { _ in [] }
    func isAlive(_ id: ProcessIdentity) -> Bool { false }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] { try inspect(value) }
}
