// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Testing
import LauncherCore
import TestSupport
@testable import RuntimeManager

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_WINE"]?.isEmpty == false))
struct PrefixShellFoldersLiveTests {
    @Test(.timeLimit(.minutes(5))) func isolatedFoldersSurviveWinebootUpdate() async throws {
        try await BlockingIO.run {
            let wine = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_LIVE_WINE"]))
            let temp = try TempDir(), home = try TempDir()
            let paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: paths.root)
            let homeFS = try ContainedFileSystem(root: home.url)
            for name in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"] {
                try homeFS.writeAtomically(Data("host sentinel".utf8), to: SafeRelativePath("\(name)/sentinel"))
            }
            try homeFS.createDirectory(at: SafeRelativePath("tmp"))
            let runner = IsolatedShellFolderRunner(home: home.url)
            let manager = PrefixManager(paths: paths, runner: runner)
            let prefix = try manager.prefixURL(game: "live-shell-folders", backend: .d3dmetal)
            let environment = ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all"]
            let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
            var child: ProcessIdentity?
            defer {
                if let child {
                    _ = kill(-child.pid, SIGKILL)
                    var status: Int32 = 0
                    while waitpid(child.pid, &status, 0) < 0 && errno == EINTR { }
                }
            }
            var result: Result<Void, any Error>
            do {
                // Explicit wineboot is essential: ordinary commands in this runtime's
                // wrapper do not disable managed/HTML bootstrap in a fresh prefix.
                _ = try await manager.createPrefix(game: "live-shell-folders", backend: .d3dmetal, wineBinary: wine)
                let prep = LaunchPreparation(paths: paths, runner: runner)
                try await prep.ensure(prefix: prefix, wineBinary: wine,
                    request: PreparationRequest(retina: false, steamShim: nil, dxmtExtras: [], nvidiaKeys: false))
                let pinned = try fs.pinDirectoryIfPresent(at: SafeRelativePath("Prefixes/live-shell-folders-d3dmetal"))
                let prefixFS = try #require(pinned)
                try assertIsolatedProfiles(prefixFS)
                let profiles = try prefixFS.contentsOfDirectory(at: SafeRelativePath("drive_c/users"))
                for profile in profiles where try prefixFS.itemType(at: profile) == .directory {
                    try prefixFS.writeAtomically(Data("keep".utf8), to: SafeRelativePath("\(profile)/Desktop/prefix-sentinel"))
                }
                let update = try await runner.run(wine, arguments: ["wineboot", "-u"], environment: environment, currentDirectory: nil)
                #expect(update.exitCode == 0)
                let saved = try await runner.run(server, arguments: ["-w"], environment: environment, currentDirectory: nil)
                #expect(saved.exitCode == 0)
                // No repair between wineboot -u and this assertion.
                try assertIsolatedProfiles(prefixFS)
                for (key, value, expected) in [
                    ("HKCU\\Software\\Wine\\DllOverrides", "winemenubuilder.exe", "REG_SZ"),
                    ("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders", "Desktop", "%USERPROFILE%\\Desktop")
                ] {
                    let query = try await runner.run(wine, arguments: ["reg", "query", key, "/v", value], environment: environment, currentDirectory: nil)
                    #expect(query.exitCode == 0)
                    #expect(String(decoding: query.stdout, as: UTF8.self).contains(expected))
                }
                for profile in profiles where try prefixFS.itemType(at: profile) == .directory {
                    #expect(try prefixFS.readFile(at: SafeRelativePath("\(profile)/Desktop/prefix-sentinel"), maxBytes: 100) == Data("keep".utf8))
                }
                for name in ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"] {
                    #expect(try homeFS.readFile(at: SafeRelativePath("\(name)/sentinel"), maxBytes: 100) == Data("host sentinel".utf8))
                }
                let alias = temp.url.appendingPathComponent("prefix-alias")
                try fs.createSymbolicLink(at: SafeRelativePath("prefix-alias"), target: prefix.path)
                let aliasEnvironment = environment.merging(["WINEPREFIX": alias.path]) { _, value in value }
                child = try SystemProcessSpawner().spawn(wine, arguments: ["cmd", "/c", "ping -n 120 127.0.0.1"],
                    environment: runner.isolated(aliasEnvironment), currentDirectory: temp.url, output: .discard)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(10))
                while true {
                    do {
                        if try !WineServerProbe().isIdle(prefix: prefixFS) { break }
                    } catch LauncherError.io { }
                    guard clock.now < deadline else { throw LauncherError.io("Live Wine did not become observable") }
                    try await clock.sleep(for: .milliseconds(100))
                }
                let refusedRunner = FakeProcessRunner()
                await #expect(throws: LauncherError.busy("Wine is using this prefix")) {
                    try await LaunchPreparation(paths: paths, runner: refusedRunner).ensure(prefix: prefix, wineBinary: wine,
                        request: PreparationRequest(retina: false, steamShim: nil, dxmtExtras: [], nvidiaKeys: false))
                }
                #expect(refusedRunner.invocations.isEmpty)
                // Prove the server identity alone also protects an alias that
                // an exact-string WINEPREFIX process scan could omit.
                await #expect(throws: LauncherError.busy("Wine is using this prefix")) {
                    try await LaunchPreparation(paths: paths, runner: refusedRunner, inspector: IdlePrefixInspector()).ensure(
                        prefix: prefix, wineBinary: wine,
                        request: PreparationRequest(retina: false, steamShim: nil, dxmtExtras: [], nvidiaKeys: false))
                }
                #expect(refusedRunner.invocations.isEmpty)
                result = .success(())
            } catch { result = .failure(error) }
            // Shield cleanup from test cancellation; target only this temporary
            // WINEPREFIX, and join/reap both direct commands before removing it.
            try await Task.detached {
                try await BlockingIO.run {
                    _ = try await runner.run(server, arguments: ["-k"], environment: environment, currentDirectory: nil)
                    let stopped = try await runner.run(server, arguments: ["-w"], environment: environment, currentDirectory: nil)
                    #expect(stopped.exitCode == 0)
                }
            }.value
            try result.get()
        }
    }
}

private func assertIsolatedProfiles(_ fs: ContainedFileSystem) throws {
    // Tree inspection uses readlinkat and never follows a link, including an
    // unexpected one. A new isolated Wine prefix needs no links in its profiles.
    let entries = try fs.inspectTree(at: SafeRelativePath("drive_c/users"))
    #expect(entries.allSatisfy { $0.linkTarget == nil })
    for profile in try fs.contentsOfDirectory(at: SafeRelativePath("drive_c/users")) {
        for name in PrefixShellFolders.names {
            #expect(try fs.itemType(at: SafeRelativePath("\(profile)/\(name)")) == .directory)
        }
    }
}

private struct IsolatedShellFolderRunner: ProcessRunner {
    let home: URL
    func isolated(_ environment: [String: String]) -> [String: String] {
        environment.merging(["HOME": home.path, "WINEHOMEDIR": home.path,
            "TMPDIR": home.appendingPathComponent("tmp").path]) { _, local in local }
    }
    func run(_ executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) async throws -> ProcessResult {
        return try await SystemProcessRunner().run(executable, arguments: arguments, environment: isolated(environment),
            currentDirectory: currentDirectory, timeout: .seconds(60), timeoutWait: { try await Task.sleep(for: $0) })
    }
}
