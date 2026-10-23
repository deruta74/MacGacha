// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Dispatch
import Foundation
import Testing
import TestSupport
import LauncherCore
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct SessionLogTests {
    @Test func disabledLogsPreserveExistingFilesAndRecoveryState() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            let store = GlobalLaunchSettingsStore(paths: f.paths)
            try store.save(GlobalLaunchSettings(sessionLogsEnabled: false))
            let fs = try ContainedFileSystem(root: f.paths.root)
            try fs.writeAtomically(Data("existing".utf8), to: SafeRelativePath("Logs/starrail-20261022-120000.log"))
            let log = try SessionLog.create(paths: f.paths, game: "starrail", header: [:],
                sessionLogsEnabled: store.load().sessionLogsEnabled)
            #expect(log == nil)
            #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Logs")).count == 1)
            try f.fs.writeAtomically(Data("driver".utf8), to: SafeRelativePath("HoYoKProtect.sys"))
            let prefixFS = try ContainedFileSystem(root: f.session.prefix)
            try prefixFS.createDirectory(at: SafeRelativePath("drive_c/windows"))
            try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")],
                installRoot: f.session.installRoot, system32: f.session.prefix.appendingPathComponent("drive_c/windows/system32"), log: log)
            #expect(try prefixFS.readFile(at: SafeRelativePath("drive_c/windows/system32/HoYoKProtect.sys"), maxBytes: 100) == Data("driver".utf8))
            f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            try f.journal.write(f.session)
            #expect(try f.journal.read(game: "starrail") == f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try fs.readFile(at: SafeRelativePath("Logs/starrail-20261022-120000.log"), maxBytes: 100) == Data("existing".utf8))
        }
    }

    @Test func disabledLoggingDoesNotCreateLogDirectory() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            #expect(try SessionLog.create(paths: paths, game: "genshin", header: [:], sessionLogsEnabled: false) == nil)
            #expect(!FileManager.default.fileExists(atPath: paths.logs.path))
        }
    }

    @Test func retentionKeepsTenAndMatchesGameExactly() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let foreign = try SessionLog.create(paths: paths, game: "zzz-extra", header: [:])
            var names: [String] = []
            for _ in 0..<13 { names.append(try makeTestLog(paths).url.lastPathComponent) }
            let fs = try ContainedFileSystem(root: paths.logs)
            let retained = try fs.contentsOfRootDirectory().filter { SessionLog.parseName($0.description) != nil }.map(\.description)
            #expect(Set(retained) == Set(Array(names.suffix(10)) + [foreign.url.lastPathComponent]))
            #expect(names[1].hasSuffix("-2.log"))
            #expect(names[12].hasSuffix("-13.log"))
        }
    }
    @Test func creationNeverPrunesItsOwnFileEvenWithOlderClock() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            for _ in 0..<10 { _ = try makeTestLog(paths) }
            let oldest = try SessionLog.create(paths: paths, game: "zzz", header: [:], now: Date(timeIntervalSince1970: 1), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: 4096)
            let fs = try ContainedFileSystem(root: paths.logs)
            #expect(try fs.size(at: SafeRelativePath(oldest.url.lastPathComponent)) != nil)
            #expect(try fs.contentsOfRootDirectory().filter { SessionLog.parseName($0.description) != nil }.count == 10)
        }
    }
    @Test func headerOrderPrivacyAndUnverifiedBuild() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url)
            let log = try makeTestLog(paths, header: ["gameBuild": "new-build", "settings": "path=/Users/alice/Games token=planted-secret mail=alice@example.test uid=123456789", "account": "private-account"])
            let text = try readTestLog(log)
            #expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: ": ")[0] } == SessionLog.headerKeys)
            #expect(text.contains("unverified build"))
            for secret in ["/Users/alice", "planted-secret", "alice@example.test", "123456789", "private-account"] { #expect(!text.contains(secret)) }
            #expect(text.contains("~/Games"))
            #expect(log.url.lastPathComponent == "zzz-20261023-120000.log")
            let fs = try ContainedFileSystem(root: paths.logs)
            let handle = try fs.openForReading(at: SafeRelativePath(log.url.lastPathComponent)); defer { try? handle.close() }
            var info = stat(); try #require(fstat(handle.fileDescriptor, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
        }
    }
    @Test func knownBuildIsVerified() async throws {
        try await BlockingIO.run {
            let temp = try TempDir()
            let log = try SessionLog.create(paths: AppPaths(root: temp.url), game: "genshin", header: ["gameBuild": "7.1"])
            #expect(try readTestLog(log).contains("buildVerification: verified build"))
        }
    }
    @Test func existingSymlinkIsACollisionAndNeverOpened() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("unchanged".utf8), to: SafeRelativePath("outside"))
            try fs.createSymbolicLink(at: SafeRelativePath("Logs/zzz-20261023-120000.log"), target: "../outside")
            let log = try makeTestLog(paths)
            #expect(log.url.lastPathComponent == "zzz-20261023-120000-2.log")
            #expect(try fs.readFile(at: SafeRelativePath("outside"), maxBytes: 100) == Data("unchanged".utf8))
        }
    }
    @Test(arguments: [false, true]) func destinationLinksAreRefused(ancestor: Bool) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), log = try makeTestLog(AppPaths(root: temp.url))
            try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath("game/HoYoKProtect.sys"))
            try fs.writeAtomically(Data("unchanged".utf8), to: SafeRelativePath("outside/HoYoKProtect.sys"))
            try fs.createDirectory(at: SafeRelativePath("prefix/drive_c/windows"))
            if ancestor {
                try fs.createSymbolicLink(at: SafeRelativePath("prefix/drive_c/windows/system32"), target: "../../../outside")
            } else {
                try fs.createSymbolicLink(at: SafeRelativePath("prefix/drive_c/windows/system32/HoYoKProtect.sys"), target: "../../../../outside/HoYoKProtect.sys")
            }
            #expect(throws: LauncherError.self) {
                try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")], installRoot: temp.url.appendingPathComponent("game"), system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: log)
            }
            #expect(try fs.readFile(at: SafeRelativePath("outside/HoYoKProtect.sys"), maxBytes: 100) == Data("unchanged".utf8))
        }
    }
    @Test func capStopsAtLimitAndWritesOneMarker() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), log = try makeTestLog(AppPaths(root: temp.url), maxBytes: 1024)
            for n in 0..<100 { log.append(line: "line \(n) " + String(repeating: "x", count: 90)) }
            log.enforceCap(); log.enforceCap()
            let text = try readTestLog(log)
            #expect(text.utf8.count == 1024)
            #expect(text.hasPrefix("recipe: zzz\n"))
            #expect(text.hasSuffix("[log truncated]\n"))
            #expect(text.components(separatedBy: "[log truncated]").count == 2)
            log.append(line: "must not be appended")
            #expect(try readTestLog(log) == text)
        }
    }
    @Test func appendLinesAreWholeUnderConcurrency() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), log = try makeTestLog(AppPaths(root: temp.url), maxBytes: 1 << 20)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for n in 0..<100 { group.addTask { try await BlockingIO.run { log.append(line: "line-\(n)-" + String(repeating: "x", count: 100)) } } }
                try await group.waitForAll()
            }
            let lines = try readTestLog(log).split(separator: "\n").filter { $0.hasPrefix("line-") }
            #expect(lines.count == 100)
            #expect(Set(lines.map(String.init)).count == 100)
            #expect(lines.allSatisfy { $0.hasSuffix(String(repeating: "x", count: 100)) })
        }
    }
    @Test func enforceCapWhileAppendChildKeepsWriting() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), log = try makeTestLog(AppPaths(root: temp.url), maxBytes: 4096)
            let header = try readTestLog(log)
            let fs = try ContainedFileSystem(root: log.url.deletingLastPathComponent()), path = try SafeRelativePath(log.url.lastPathComponent)
            let handle = try fs.openForReading(at: path)
            let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor, eventMask: .write, queue: DispatchQueue(label: "SessionLogTests.writer"))
            source.setEventHandler { continuation.yield(()) }
            source.setCancelHandler { try? handle.close() }; source.resume()
            defer { source.cancel(); continuation.finish() }
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do printf 'wine-output-012345678901234567890123456789\\n'; done"], environment: [:], currentDirectory: temp.url, output: log.processOutput)
            var childPID = child.pid
            defer { if childPID > 0 { killLogWriter(childPID) } }
            var iterator = events.makeAsyncIterator()
            for _ in 0..<10 {
                while (try fs.size(at: path) ?? 0) <= 4096 {
                    try #require(await iterator.next() != nil)
                }
                log.enforceCap()
            }
            killLogWriter(childPID); childPID = 0
            log.enforceCap()
            let text = try readTestLog(log)
            #expect(text.utf8.count == 4096)
            #expect(text.hasPrefix(header))
            #expect(text.hasSuffix("[log truncated]\n"))
            #expect(text.components(separatedBy: "[log truncated]").count == 2)
            #expect(!text.contains("\0"))
        }
    }
    @Test func copyIfPresentSkipsMissing() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), log = try makeTestLog(paths)
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.createDirectory(at: SafeRelativePath("game")); try fs.createDirectory(at: SafeRelativePath("prefix/drive_c/windows/system32"))
            try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")], installRoot: temp.url.appendingPathComponent("game"), system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: log)
            #expect(try readTestLog(log).contains("skip HoYoKProtect.sys (not present)"))
        }
    }
    @Test(arguments: [false, true]) func copyIsVerifiedOrRejectsSymlink(symlink: Bool) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), log = try makeTestLog(AppPaths(root: temp.url))
            let fs = try ContainedFileSystem(root: temp.url)
            try fs.createDirectory(at: SafeRelativePath("game")); try fs.createDirectory(at: SafeRelativePath("prefix/drive_c/windows/system32"))
            let bytes = Data(repeating: 17, count: 100_003)
            try fs.writeAtomically(bytes, to: SafeRelativePath("source"))
            if symlink { try fs.createSymbolicLink(at: SafeRelativePath("game/HoYoKProtect.sys"), target: "../source") }
            else { try fs.writeAtomically(bytes, to: SafeRelativePath("game/HoYoKProtect.sys")) }
            let action = { try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")], installRoot: temp.url.appendingPathComponent("game"), system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: log) }
            if symlink { #expect(throws: LauncherError.self, performing: action) }
            else { try action(); #expect(try fs.readFile(at: SafeRelativePath("prefix/drive_c/windows/system32/HoYoKProtect.sys"), maxBytes: 200_000) == bytes) }
            #expect(try fs.readFile(at: SafeRelativePath("source"), maxBytes: 200_000) == bytes)
        }
    }
}

private func makeTestLog(_ paths: AppPaths, header: [String: String] = [:], maxBytes: Int = 4096) throws -> SessionLog {
    try SessionLog.create(paths: paths, game: "zzz", header: header, now: Date(timeIntervalSince1970: 1792756800), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: maxBytes)
}
private func readTestLog(_ log: SessionLog) throws -> String {
    let fs = try ContainedFileSystem(root: log.url.deletingLastPathComponent())
    return String(decoding: try fs.readFile(at: SafeRelativePath(log.url.lastPathComponent), maxBytes: 2 << 20), as: UTF8.self)
}
private func killLogWriter(_ pid: Int32) {
    _ = kill(-pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
}
