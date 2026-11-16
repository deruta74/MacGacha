// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport

@Suite struct PrefixResetRecoveryTests {
    @Test func interruptedDeletionCannotLeaveReadyPrefixAndNextPrepareReinitializes() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let fs = try ContainedFileSystem(root: paths.root)
        let wine = try SafeRelativePath("Runtimes/fake/bin/wine")
        try fs.writeAtomically(Data("wine".utf8), to: wine)
        let runner = FakeProcessRunner { invocation in
            #expect(invocation.arguments == ["wineboot", "--init"])
            try fs.writeAtomically(Data("initialized".utf8), to: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/users/player/settings"))
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let manager = PrefixManager(paths: paths, runner: runner, inspector: ResetRecoveryIdleInspector())
        _ = try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine.resolved(against: paths.root))
        let fault = PrefixResetFileOps(beforeUnlink: {
            // Delete profile data but retain the ready marker, regardless of directory traversal order.
            let tree = try #require(try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).first {
                try fs.itemType(at: $0) == .directory
            })
            try fs.removeItem(at: SafeRelativePath("\(tree)/drive_c/users"))
            throw LauncherError.io("Interrupted prefix deletion")
        })
        #expect(throws: LauncherError.io("Interrupted prefix deletion")) {
            try manager.resetPrefixes(game: "genshin", fileOps: fault)
        }
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == nil)
        let interrupted = try #require(try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).first {
            try fs.itemType(at: $0) == .directory
        })
        #expect(try fs.itemType(at: SafeRelativePath("\(interrupted)/.macgacha-prefix.json")) == .regularFile)
        #expect(try fs.itemType(at: SafeRelativePath("\(interrupted)/drive_c/users")) == nil)

        // A fresh manager represents the next launch after a quit during reset.
        _ = try await PrefixManager(paths: paths, runner: runner, inspector: ResetRecoveryIdleInspector())
            .createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine.resolved(against: paths.root))
        #expect(runner.invocations.count == 2)
        #expect(try fs.readFile(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/users/player/settings"), maxBytes: 100) == Data("initialized".utf8))
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).filter {
            try fs.itemType(at: $0) == .directory
        }.map(\.description) == ["Prefixes/genshin-dxmt"])
    }

    @Test func failedRetirementSyncLeavesIntactTreeAndRetrySyncsBeforeDeletion() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let fs = try ContainedFileSystem(root: paths.root)
        let original = try SafeRelativePath("Prefixes/genshin-dxmt")
        try fs.writeAtomically(Data("saved".utf8), to: SafeRelativePath("\(original)/keep"))
        let manager = PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: ResetRecoveryIdleInspector())
        let fault = PrefixResetFileOps(beforeRetirementSync: { throw LauncherError.io("Retirement sync failed") })
        #expect(throws: LauncherError.io("Retirement sync failed")) {
            try manager.resetPrefixes(game: "genshin", fileOps: fault)
        }
        #expect(try fs.itemType(at: original) == nil)
        let retired = try #require(try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes")).first {
            try fs.itemType(at: $0) == .directory
        })
        #expect(try fs.readFile(at: SafeRelativePath("\(retired)/keep"), maxBytes: 100) == Data("saved".utf8))
        let synced = Mutex(false)
        let retry = PrefixResetFileOps(beforeUnlink: { #expect(synced.withLock { $0 }) }, beforeSync: { synced.withLock { $0 = true } })
        #expect(try manager.resetPrefixes(game: "genshin", fileOps: retry) == 1)
        #expect(try fs.itemType(at: retired) == nil)
    }

    @Test(arguments: [false, true])
    func nextPrepareRefusesLiveOrUncertainOriginalWinePath(uncertain: Bool) async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        let retired = try SafeRelativePath("Prefixes/.macgacha-retired-genshin-dxmt/keep")
        try fs.writeAtomically(Data("saved".utf8), to: retired)
        let inspector = ResetRecoveryIdleInspector { value in
            guard value == paths.prefixes.appendingPathComponent("genshin-dxmt").path else { return [] }
            if uncertain { throw LauncherError.io("Inspection failed") }
            return [InspectedProcess(identity: ProcessIdentity(pid: 123, startTime: 456), executablePath: "/fake/wine", arguments: [])]
        }
        let runner = FakeProcessRunner()
        let manager = PrefixManager(paths: paths, runner: runner, inspector: inspector)
        await #expect(throws: LauncherError.self) {
            try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: paths.runtimes.appendingPathComponent("fake/wine"))
        }
        #expect(runner.invocations.isEmpty)
        #expect(try fs.readFile(at: retired, maxBytes: 100) == Data("saved".utf8))
        #expect(try fs.itemType(at: SafeRelativePath("Prefixes/genshin-dxmt")) == nil)
    }

    @Test func sweepHoldsOriginalPrefixLockAndPreservesOtherEditionsAndBundles() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        let retired = "Prefixes/.macgacha-retired-genshin-dxmt"
        let others = ["Prefixes/.macgacha-retired-genshin-cn-dxmt/keep", "Prefixes/.macgacha-retired-zenless-dxmt/keep",
                      "Prefixes/.macgacha-retired-genshin-old-bundle/keep"]
        for path in ["\(retired)/keep"] + others { try fs.writeAtomically(Data("saved".utf8), to: SafeRelativePath(path)) }
        let lockChecked = Mutex(false)
        let inspector = ResetRecoveryIdleInspector { value in
            if value == paths.prefixes.appendingPathComponent(".macgacha-retired-genshin-dxmt").path {
                #expect(throws: LauncherError.self) { try InstallLock(fs: fs, path: SafeRelativePath("Prefixes/.macgacha-prefix-genshin-dxmt.lock")) }
                lockChecked.withLock { $0 = true }
            }
            return []
        }
        let wine = try SafeRelativePath("Runtimes/fake/bin/wine")
        try fs.writeAtomically(Data("wine".utf8), to: wine)
        _ = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: inspector)
            .createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine.resolved(against: paths.root))
        #expect(lockChecked.withLock { $0 })
        #expect(try fs.itemType(at: SafeRelativePath(retired)) == nil)
        for path in others { #expect(try fs.readFile(at: SafeRelativePath(path), maxBytes: 100) == Data("saved".utf8)) }
    }

    @Test(arguments: [false, true]) func resetPreflightsAndSweepsAllSelectedEditionTrees(busy: Bool) throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
        let selected = ["genshin-dxmt", ".macgacha-retired-genshin-dxmt", ".macgacha-retired-genshin-old-bundle"]
        let others = ["genshin-cn-dxmt", ".macgacha-retired-genshin-cn-dxmt", ".macgacha-retired-zenless-dxmt"]
        for name in selected + others { try fs.writeAtomically(Data("saved".utf8), to: SafeRelativePath("Prefixes/\(name)/keep")) }
        let inspector = ResetRecoveryIdleInspector { value in
            if busy && value == paths.prefixes.appendingPathComponent(".macgacha-retired-genshin-old-bundle").path {
                throw LauncherError.io("Inspection failed")
            }
            return []
        }
        let manager = PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: inspector)
        if busy {
            #expect(throws: LauncherError.self) { try manager.resetPrefixes(game: "genshin") }
        } else {
            let fileOps = PrefixResetFileOps(beforeUnlink: {
                for name in ["genshin-dxmt", "genshin-old-bundle"] {
                    #expect(throws: LauncherError.self) { try InstallLock(fs: fs, path: SafeRelativePath("Prefixes/.macgacha-prefix-\(name).lock")) }
                }
            })
            #expect(try manager.resetPrefixes(game: "genshin", fileOps: fileOps) == 2)
            for name in selected { #expect(try fs.itemType(at: SafeRelativePath("Prefixes/\(name)")) == nil) }
        }
        for name in others + (busy ? selected : []) {
            #expect(try fs.readFile(at: SafeRelativePath("Prefixes/\(name)/keep"), maxBytes: 100) == Data("saved".utf8))
        }
    }

    @Test(arguments: [false, true]) func retiredSymlinkCannotBeSweptByResetOrPreparation(reset: Bool) async throws {
        let temp = try TempDir(), outside = try TempDir(), paths = AppPaths(root: temp.url)
        let fs = try ContainedFileSystem(root: temp.url), target = try ContainedFileSystem(root: outside.url)
        try target.writeAtomically(Data("saved".utf8), to: SafeRelativePath("keep"))
        try fs.createSymbolicLink(at: SafeRelativePath("Prefixes/.macgacha-retired-genshin-dxmt"), target: outside.url.path)
        let manager = PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: ResetRecoveryIdleInspector())
        if reset {
            #expect(throws: LauncherError.self) { try manager.resetPrefixes(game: "genshin") }
        } else {
            await #expect(throws: LauncherError.self) {
                try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: paths.runtimes.appendingPathComponent("fake/wine"))
            }
        }
        #expect(try target.readFile(at: SafeRelativePath("keep"), maxBytes: 100) == Data("saved".utf8))
    }
}

private struct ResetRecoveryIdleInspector: ProcessInspector {
    var inspect: @Sendable (String) throws -> [InspectedProcess] = { _ in [] }
    func isAlive(_ id: ProcessIdentity) -> Bool { false }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] { try inspect(value) }
}

private final class PrefixResetFileOps: FileOps, Sendable {
    private let fired = Mutex(false)
    private let renamed = Mutex(false)
    private let beforeUnlink: @Sendable () throws -> Void
    private let beforeRetirementSync: @Sendable () throws -> Void
    private let beforeSync: @Sendable () -> Void
    init(beforeUnlink: @escaping @Sendable () throws -> Void = {},
         beforeRetirementSync: @escaping @Sendable () throws -> Void = {}, beforeSync: @escaping @Sendable () -> Void = {}) {
        self.beforeUnlink = beforeUnlink; self.beforeRetirementSync = beforeRetirementSync; self.beforeSync = beforeSync
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        if renamed.withLock({ $0 }) { try beforeRetirementSync() }
        try SystemFileOps().synchronize(descriptor, durable: durable)
        beforeSync()
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        #expect(exclusive)
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
        renamed.withLock { $0 = true }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if fired.withLock({ if $0 { return false }; $0 = true; return true }) { try beforeUnlink() }
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
