// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import RuntimeManager

@Suite struct PrefixShellFoldersTests {
    @Test func winebootServicesAreJoinedBeforeRepair() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: paths.root)
            let binary = try SafeRelativePath("Runtimes/test/bin/wine")
            try fs.writeAtomically(Data("fake wine".utf8), to: binary)
            let active = Mutex(false)
            let inspector = IdlePrefixInspector(inspect: {
                active.withLock { $0 } ? [InspectedProcess(identity: ProcessIdentity(pid: 123, startTime: 456),
                    executablePath: "/runtime/bin/wineserver", arguments: [])] : []
            })
            let runner = FakeProcessRunner { call in
                if call.arguments == ["wineboot", "--init"] { active.withLock { $0 = true } }
                else {
                    #expect(call.arguments == ["-w"])
                    #expect(call.executable.lastPathComponent == "wineserver")
                    active.withLock { $0 = false }
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            _ = try await PrefixManager(paths: paths, runner: runner, inspector: inspector).createPrefix(
                game: "test", backend: .d3dmetal, wineBinary: binary.resolved(against: paths.root))
            #expect(runner.invocations.map(\.arguments) == [["wineboot", "--init"], ["-w"]])
        }
    }

    @Test func unsafeExistingProfileRejectsWinebootUpgradeBeforeMarkerChange() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), home = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: paths.root)
            let binary = try SafeRelativePath("Runtimes/test/bin/wine")
            try fs.writeAtomically(Data("wine v1".utf8), to: binary)
            let wine = binary.resolved(against: paths.root)
            _ = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "test", backend: .d3dmetal, wineBinary: wine)
            let marker = try SafeRelativePath("Prefixes/test-d3dmetal/.macgacha-prefix.json")
            let before = try fs.readFile(at: marker, maxBytes: 16_384)
            try fs.createSymbolicLink(at: SafeRelativePath("Prefixes/test-d3dmetal/drive_c/users/player"), target: home.url.path)
            try fs.writeAtomically(Data("wine v2".utf8), to: binary)
            let runner = FakeProcessRunner()
            await #expect(throws: LauncherError.self) {
                _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "test", backend: .d3dmetal, wineBinary: wine)
            }
            #expect(runner.invocations.isEmpty)
            #expect(try fs.readFile(at: marker, maxBytes: 16_384) == before)
        }
    }

    @Test func prefixManagerRepairsImmediatelyAfterWineboot() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), home = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: paths.root)
            let binaryPath = try SafeRelativePath("Runtimes/test/bin/wine")
            try fs.writeAtomically(Data("fake wine".utf8), to: binaryPath)
            let homePath = home.url.path
            let runner = FakeProcessRunner { call in
                #expect(call.arguments == ["wineboot", "--init"])
                try fs.createSymbolicLink(at: SafeRelativePath("Prefixes/test-d3dmetal/drive_c/users/player/Desktop"), target: homePath)
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "test", backend: .d3dmetal, wineBinary: binaryPath.resolved(against: paths.root))
            #expect(try fs.itemType(at: SafeRelativePath("Prefixes/test-d3dmetal/drive_c/users/player/Desktop")) == .directory)
        }
    }

    @Test func externalLinksBecomeEmptyDirectoriesWithoutOpeningTargets() throws {
        let temp = try TempDir(), home = try TempDir()
        let fs = try ContainedFileSystem(root: temp.url), outside = try ContainedFileSystem(root: home.url)
        for name in PrefixShellFolders.names {
            try outside.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("\(name)/sentinel"))
            try fs.createSymbolicLink(at: SafeRelativePath("drive_c/users/player/\(name)"), target: home.url.appendingPathComponent(name).path)
            #expect(chmod(home.url.appendingPathComponent(name).path, 0) == 0)
        }
        defer { for name in PrefixShellFolders.names { chmod(home.url.appendingPathComponent(name).path, 0o700) } }
        // Following any link would fail: the target directory cannot even be opened.
        let target = open(home.url.appendingPathComponent("Desktop").path, O_RDONLY | O_DIRECTORY)
        if target >= 0 { close(target) }
        #expect(target == -1)
        try PrefixShellFolders.repair(in: fs)
        for name in PrefixShellFolders.names {
            let path = try SafeRelativePath("drive_c/users/player/\(name)")
            #expect(try fs.itemType(at: path) == .directory)
            #expect(try fs.contentsOfDirectory(at: path).isEmpty)
            #expect(chmod(home.url.appendingPathComponent(name).path, 0o700) == 0)
            #expect(try outside.readFile(at: SafeRelativePath("\(name)/sentinel"), maxBytes: 100) == Data("untouched".utf8))
        }
    }

    @Test func preservesDirectoriesAndUnexpectedFilesButReplacesAllLinksIdempotently() throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.writeAtomically(Data("saved".utf8), to: SafeRelativePath("drive_c/users/player/Desktop/keep"))
        try fs.writeAtomically(Data("unexpected".utf8), to: SafeRelativePath("drive_c/users/player/Documents"))
        try fs.createSymbolicLink(at: SafeRelativePath("drive_c/users/player/Downloads"), target: "Desktop")
        try fs.createSymbolicLink(at: SafeRelativePath("drive_c/users/player/Music"), target: temp.url.appendingPathComponent("drive_c/users/player/Desktop").path)
        let log = Mutex([String]())
        for _ in 0..<2 { try PrefixShellFolders.repair(in: fs, log: { line in log.withLock { $0.append(line) } }) }
        #expect(try fs.readFile(at: SafeRelativePath("drive_c/users/player/Desktop/keep"), maxBytes: 100) == Data("saved".utf8))
        #expect(try fs.readFile(at: SafeRelativePath("drive_c/users/player/Documents"), maxBytes: 100) == Data("unexpected".utf8))
        for name in ["Downloads", "Music"] {
            #expect(try fs.itemType(at: SafeRelativePath("drive_c/users/player/\(name)")) == .directory)
        }
        #expect(log.withLock { $0.contains("skip Documents (unexpected entry)") })
        #expect(log.withLock { $0.contains("isolated Downloads") })
        #expect(log.withLock { $0.allSatisfy { !$0.contains(temp.url.path) && !$0.contains("player") } })
    }

    @Test func chainedLinkThroughZDriveAndPublicLinksAreReplaced() throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.createSymbolicLink(at: SafeRelativePath("dosdevices/z:"), target: "/")
        for profile in ["player", "Public"] {
            try fs.createSymbolicLink(at: SafeRelativePath("drive_c/users/\(profile)/Desktop"),
                target: "../../../dosdevices/z:/Users/synthetic/Desktop")
        }
        try PrefixShellFolders.repair(in: fs)
        for profile in ["player", "Public"] {
            #expect(try fs.itemType(at: SafeRelativePath("drive_c/users/\(profile)/Desktop")) == .directory)
        }
    }
}

/// Fake runners create no real processes; unit tests never inspect the host's table.
struct IdlePrefixInspector: ProcessInspector {
    var inspect: @Sendable () throws -> [InspectedProcess] = { [] }
    func isAlive(_ id: ProcessIdentity) -> Bool { false }
    func processes(environmentContains key: String, value: String, scope: ProcessInspectionScope) throws -> [InspectedProcess] {
        try inspect()
    }
}
