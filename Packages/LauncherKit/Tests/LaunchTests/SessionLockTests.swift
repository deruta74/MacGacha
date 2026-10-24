// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport
import Launch

@Suite(.timeLimit(.minutes(1))) struct SessionLockTests {
    @Test func sameProcessSecondAcquireIsBusyAndDeinitReleases() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            do {
                let lock = try SessionLock.acquire(paths: paths, game: "starrail")
                defer { withExtendedLifetime(lock) {} }
                #expect(throws: LauncherError.busy("install root in use")) { try SessionLock.acquire(paths: paths, game: "starrail") }
                let other = try SessionLock.acquire(paths: paths, game: "zzz")
                withExtendedLifetime(other) {}
            }
            let retry = try SessionLock.acquire(paths: paths, game: "starrail")
            withExtendedLifetime(retry) {}
        }
    }

    @Test(arguments: [false, true])
    func symlinkedLockPathIsRejected(runtime: Bool) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: temp.url)
            let path = try SafeRelativePath(runtime ? "Runtimes/.pin-wine-1.lock" : "Games/starrail/.session.lock")
            try fs.createDirectory(at: SafeRelativePath(path.components.dropLast().joined(separator: "/")))
            try fs.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("target"))
            try fs.createSymbolicLink(at: path, target: runtime ? "../target" : "../../target")
            do {
                if runtime { _ = try RuntimePin.pin(paths: paths, componentIDs: ["wine-1"]) }
                else { _ = try SessionLock.acquire(paths: paths, game: "starrail") }
                Issue.record("A symlinked lock was accepted")
            } catch LauncherError.unsafePath { }
            #expect(try fs.readFile(at: SafeRelativePath("target"), maxBytes: 100) == Data("untouched".utf8))
        }
    }

    @Test func unsafeIdentifiersAreRejectedBeforeCreatingFiles() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            #expect(throws: LauncherError.unsafePath("../other")) { try SessionLock.acquire(paths: paths, game: "../other") }
            #expect(throws: LauncherError.unsafePath("../other")) {
                try RuntimePin.pin(paths: paths, componentIDs: ["wine-1", "../other"])
            }
            #expect(try ContainedFileSystem(root: temp.url).contentsOfRootDirectory().isEmpty)
        }
    }

    @Test func runtimePinsAreSharedAndReleaseOnDeinit() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: temp.url)
            let path = try SafeRelativePath("Runtimes/.pin-wine-1.lock")
            do {
                let first = try RuntimePin.pin(paths: paths, componentIDs: ["wine-1", "wine-1"])
                let second = try RuntimePin.pin(paths: paths, componentIDs: ["wine-1"])
                defer { withExtendedLifetime((first, second)) {} }
                #expect(throws: LauncherError.busy("install root in use")) { try InstallLock(fs: fs, path: path) }
            }
            let removal = try InstallLock(fs: fs, path: path)
            withExtendedLifetime(removal) {}
        }
    }

    @Test func failedMultiPinReleasesEarlierPins() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let fs = try ContainedFileSystem(root: temp.url)
            let removal = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-1.lock"))
            defer { withExtendedLifetime(removal) {} }
            #expect(throws: LauncherError.busy("install root in use")) {
                try RuntimePin.pin(paths: paths, componentIDs: ["dxmt-1", "wine-1"])
            }
            let retry = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-dxmt-1.lock"))
            withExtendedLifetime(retry) {}
        }
    }

    @Test func secondProcessCannotAcquire() async throws {
        try await withLockHolder(mode: "hold-session-lock", id: "starrail") { paths in
            #expect(throws: LauncherError.busy("install root in use")) { try SessionLock.acquire(paths: paths, game: "starrail") }
        }
    }

    @Test func pinReleasedOnProcessDeath() async throws {
        try await withLockHolder(mode: "hold-runtime-pin", id: "wine-1") { paths in
            let fs = try ContainedFileSystem(root: paths.root)
            #expect(throws: LauncherError.busy("install root in use")) {
                try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-wine-1.lock"))
            }
        }
    }
}

private final class SessionLockBundleToken { }

private func withLockHolder(mode: String, id: String, check: @escaping @Sendable (AppPaths) throws -> Void) async throws {
    try await BlockingIO.run {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let ready = temp.url.appendingPathComponent("ready")
        let event = try FileAppearanceEvent(ready)
        let harness = Bundle(for: SessionLockBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        let child = try SystemProcessSpawner().spawn(harness,
            arguments: [mode, temp.url.path, id, ready.path, temp.url.appendingPathComponent("release").path],
            environment: [:], currentDirectory: temp.url, output: .discard)
        var reaped = false
        defer {
            if !reaped {
                _ = kill(-child.pid, SIGKILL); _ = kill(child.pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(child.pid, &status, 0) < 0 && errno == EINTR { }
            }
        }
        try await event.wait()
        try check(paths)
        try #require(kill(child.pid, SIGKILL) == 0)
        var status: Int32 = 0, result: pid_t
        repeat { result = waitpid(child.pid, &status, 0) } while result < 0 && errno == EINTR
        try #require(result == child.pid); reaped = true
        #expect(status & 0x7f == SIGKILL)
        if mode == "hold-runtime-pin" {
            let fs = try ContainedFileSystem(root: paths.root)
            let removal = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.pin-\(id).lock"))
            withExtendedLifetime(removal) {}
        } else {
            let retry = try SessionLock.acquire(paths: paths, game: id)
            withExtendedLifetime(retry) {}
        }
    }
}
