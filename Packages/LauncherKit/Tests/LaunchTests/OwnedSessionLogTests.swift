// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import TestSupport
import LauncherCore
@testable import Launch

final class ManualLogTicker: SessionLogTicker, Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)
    package func start(_ callback: @escaping @Sendable () -> Void) -> LogTickCancellation {
        action.withLock { $0 = callback }
        return LogTickCancellation { self.action.withLock { $0 = nil } }
    }
    func fire() { action.withLock { $0 }?() }
}

@Suite(.timeLimit(.minutes(1))) struct OwnedSessionLogTests {
    @Test func replacementNeverRedirectsAppendOrCap() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), ticker = ManualLogTicker()
            let log = try ownedTestLog(paths, ticker: ticker)
            let fs = try ContainedFileSystem(root: paths.logs), name = try SafeRelativePath(log.url.lastPathComponent)
            try fs.rename(from: name, to: SafeRelativePath("held.log"))
            let foreign = Data(repeating: 88, count: 4000)
            try fs.writeAtomically(foreign, to: name)
            log.append(line: "owned-line")
            #expect(String(decoding: try fs.readFile(at: SafeRelativePath("held.log"), maxBytes: 8192), as: UTF8.self).contains("owned-line"))
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/echo"), arguments: ["child-line"], environment: [:], currentDirectory: temp.url, output: log.processOutput)
            var status: Int32 = 0, pid = child.pid
            defer { if pid > 0 { _ = kill(-pid, SIGKILL); while waitpid(pid, &status, 0) < 0 && errno == EINTR {} } }
            var reaped: Int32
            repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
            try #require(reaped == pid); pid = 0
            #expect(status == 0)
            #expect(String(decoding: try fs.readFile(at: SafeRelativePath("held.log"), maxBytes: 8192), as: UTF8.self).contains("child-line"))
            let writer = try fs.openForWriting(at: SafeRelativePath("held.log"), truncate: false)
            _ = try writer.seekToEnd()
            try writer.write(contentsOf: Data(repeating: 65, count: 4096)); try writer.close()
            ticker.fire()
            #expect(try fs.size(at: SafeRelativePath("held.log")) == 1024)
            #expect(try fs.readFile(at: name, maxBytes: 8192) == foreign)
            log.finish()
        }
    }
    @Test func retentionSkipsReplacementAndUnrecordedLogs() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), ticker = ManualLogTicker()
            let first = try ownedTestLog(paths, ticker: ticker)
            let fs = try ContainedFileSystem(root: paths.logs), old = try SafeRelativePath(first.url.lastPathComponent)
            try fs.writeAtomically(Data("legacy".utf8), to: SafeRelativePath("zzz-20261021-000000.log"))
            for _ in 0..<9 { try ownedTestLog(paths, ticker: ManualLogTicker()).finish() }
            let replacement = Data("not owned".utf8)
            let newest = try ownedTestLog(paths, ticker: ManualLogTicker(), beforeRetention: { candidate in
                if candidate == old {
                    try! fs.rename(from: old, to: SafeRelativePath("held.log"))
                    try! fs.writeAtomically(replacement, to: old)
                }
            })
            #expect(try fs.readFile(at: old, maxBytes: 100) == replacement)
            #expect(try fs.readFile(at: SafeRelativePath("zzz-20261021-000000.log"), maxBytes: 100) == Data("legacy".utf8))
            first.finish(); newest.finish()
        }
    }
    @Test func finishAndStaleRecoveryEnforceThroughRecordedInode() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), log = try ownedTestLog(paths, ticker: ManualLogTicker())
            let fs = try ContainedFileSystem(root: paths.logs), name = try SafeRelativePath(log.url.lastPathComponent)
            let writer = try fs.openForWriting(at: name, truncate: false); defer { try? writer.close() }
            _ = try writer.seekToEnd()
            try writer.write(contentsOf: Data(repeating: 65, count: 4096))
            log.finish(); #expect(try fs.size(at: name) == 1024)
            _ = try writer.seekToEnd()
            _ = try writer.seekToEnd()
            try writer.write(contentsOf: Data(repeating: 66, count: 4096))
            let recovered = try #require(try SessionLog.recover(at: log.url))
            #expect(try fs.size(at: name) == 1024); recovered.finish()
            try fs.rename(from: name, to: SafeRelativePath("old.log"))
            try fs.writeAtomically(Data(repeating: 90, count: 4096), to: name)
            #expect(try SessionLog.recover(at: log.url) == nil)
            #expect(try fs.size(at: name) == 4096)
        }
    }
    @Test func injectedTicksBoundAStillRunningChildWriter() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), ticker = ManualLogTicker()
            let log = try ownedTestLog(paths, ticker: ticker)
            let control = temp.url.appendingPathComponent("control"), ack = temp.url.appendingPathComponent("ack")
            try #require(mkfifo(control.path, 0o600) == 0 && mkfifo(ack.path, 0o600) == 0)
            let input = open(control.path, O_RDWR | O_CLOEXEC), output = open(ack.path, O_RDWR | O_CLOEXEC)
            try #require(input >= 0 && output >= 0); defer { close(input); close(output) }
            let payload = String(repeating: "x", count: 4096)
            let script = "exec 3<control; exec 4>ack; while IFS= read -r command <&3; do printf '\(payload)'; printf a >&4; done"
            let child = try SystemProcessSpawner().spawn(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: [:], currentDirectory: temp.url, output: log.processOutput)
            defer { _ = kill(-child.pid, SIGKILL); var status: Int32 = 0; while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {} }
            let fs = try ContainedFileSystem(root: paths.logs), name = try SafeRelativePath(log.url.lastPathComponent)
            for _ in 0..<8 {
                try #require("write\n".withCString { Darwin.write(input, $0, 6) } == 6)
                try waitForLogWriterAck(output, child: child)
                #expect(try fs.size(at: name)! <= 1024 + 4096)
                ticker.fire()
                #expect(try fs.size(at: name) == 1024)
                #expect(SystemProcessInspector().isAlive(child))
            }
            log.finish()
        }
    }
}

func ownedTestLog(_ paths: AppPaths, ticker: any SessionLogTicker,
    beforeRetention: @escaping @Sendable (SafeRelativePath) -> Void = { _ in }) throws -> SessionLog {
    try SessionLog.create(paths: paths, game: "zzz", header: [:], now: Date(timeIntervalSince1970: 1792756800), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: 1024, ticker: ticker, beforeRetention: beforeRetention)
}

@Suite(.timeLimit(.minutes(1))) struct ClaimedLaunchCopyTests {
    @Test(arguments: [false, true]) func substitutedTemporaryIsNeverAcceptedOrDeleted(atSyscall: Bool) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), root = temp.url, fs = try ContainedFileSystem(root: root)
            try fs.writeAtomically(Data("verified".utf8), to: SafeRelativePath("game/HoYoKProtect.sys"))
            try fs.createDirectory(at: SafeRelativePath("prefix/drive_c/windows/system32"))
            let ops = SessionLogRaceOps { source, parent, target, _ in
                if atSyscall && source.hasPrefix(".macgacha-copy-") && target == "HoYoKProtect.sys" { try replaceCopySource(source, parent: parent) }
            }
            #expect(throws: LauncherError.self) {
                try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")],
                    installRoot: temp.url.appendingPathComponent("game"), system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: nil,
                    fileOps: ops, beforePublication: { path in
                        if !atSyscall {
                            let prefixFS = try! ContainedFileSystem(root: root.appendingPathComponent("prefix"))
                            try! prefixFS.rename(from: path, to: SafeRelativePath(path.description + ".held"))
                            try! prefixFS.writeAtomically(Data("foreign".utf8), to: path)
                        }
                    })
            }
            let directory = try SafeRelativePath("prefix/drive_c/windows/system32")
            let files = try fs.contentsOfDirectory(at: directory)
            #expect(try files.contains { try fs.itemType(at: $0) == .regularFile && fs.readFile(at: $0, maxBytes: 1024) == Data("foreign".utf8) })
            if !atSyscall { #expect(try fs.itemType(at: SafeRelativePath("prefix/drive_c/windows/system32/HoYoKProtect.sys")) == nil) }
            #expect(try fs.readFile(at: SafeRelativePath("game/HoYoKProtect.sys"), maxBytes: 100) == Data("verified".utf8))
        }
    }
    @Test func updatedCopyUsesExclusivePublicationAndRetainsVerifiedBytes() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            try fs.writeAtomically(Data("new".utf8), to: SafeRelativePath("game/HoYoKProtect.sys"))
            try fs.writeAtomically(Data("old".utf8), to: SafeRelativePath("prefix/drive_c/windows/system32/HoYoKProtect.sys"))
            try LaunchCopies.copyIfPresent([(SafeRelativePath("HoYoKProtect.sys"), "HoYoKProtect.sys")], installRoot: temp.url.appendingPathComponent("game"),
                system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: nil)
            #expect(try fs.readFile(at: SafeRelativePath("prefix/drive_c/windows/system32/HoYoKProtect.sys"), maxBytes: 100) == Data("new".utf8))
        }
    }
    @Test func retentionReturnsAnInodeSwappedAtTheRenameBoundary() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), paths = AppPaths(root: temp.url), ticker = ManualLogTicker()
            let first = try ownedTestLog(paths, ticker: ticker), name = first.url.lastPathComponent
            for _ in 0..<9 { try ownedTestLog(paths, ticker: ManualLogTicker()).finish() }
            let ops = SessionLogRaceOps { source, parent, target, _ in
                if source == name && target == "file" { try replaceCopySource(source, parent: parent) }
            }
            let newest = try SessionLog.create(paths: paths, game: "zzz", header: [:], now: Date(timeIntervalSince1970: 1792756800), timeZone: TimeZone(secondsFromGMT: 0)!, maxBytes: 1024,
                ticker: ManualLogTicker(), fileOps: ops)
            let fs = try ContainedFileSystem(root: paths.logs)
            #expect(try fs.readFile(at: SafeRelativePath(name), maxBytes: 100) == Data("foreign".utf8))
            first.finish(); newest.finish()
        }
    }
}

private func replaceCopySource(_ source: String, parent: Int32) throws {
    guard renameat(parent, source, parent, source + ".held") == 0 else { throw LauncherError.io("Test source swap failed") }
    let fd = openat(parent, source, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LauncherError.io("Test replacement failed") }
    defer { close(fd) }
    _ = "foreign".withCString { Darwin.write(fd, $0, 7) }
}
private struct SessionLogRaceOps: FileOps {
    let onRename: @Sendable (String, Int32, String, Int32) throws -> Void
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try onRename(source, sourceDirectory, destination, destinationDirectory)
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
}

private func waitForLogWriterAck(_ fd: Int32, child: ProcessIdentity) throws {
    // The poll timeout is only a cancellation/death guard. An acknowledgement,
    // never elapsed wall time, determines that this interval's writes finished.
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        try Task.checkCancellation()
        let ready = poll(&descriptor, 1, 250)
        if ready < 0 && errno == EINTR { continue }
        guard ready >= 0 else { throw LauncherError.io("Test writer poll failed") }
        if descriptor.revents & Int16(POLLIN) != 0 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw LauncherError.io("Test writer acknowledgement failed") }
            return
        }
        guard SystemProcessInspector().isAlive(child) else { throw LauncherError.io("Test writer exited before acknowledgement") }
    }
}
