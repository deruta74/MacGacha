// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct ClaimedSourceTests {
    @Test(arguments: SourceSwapKind.allCases, [false, true])
    func substitutedSourceKeepsJournalAndPreservesUnrelatedInodes(kind: SourceSwapKind, conflict: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            if conflict { try f.fs.writeAtomically(newBytes, to: gamePath) }
            try f.journal.write(f.session)
            let victim = f.temp.url.appendingPathComponent("outside-victim")
            try oldBytes.write(to: victim)
            let ops = SourceSwapOps(kind: kind, source: f.hidden.resolved(against: f.session.installRoot),
                backup: f.temp.url.appendingPathComponent("saved-source"), victim: victim)
            let outcome = try HiddenFiles(fileOps: ops).restore(session: &f.session, journal: f.journal)
            #expect(ops.triggered.withLock { $0 })
            #expect(outcome != .clean)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            let unrelated = kind == .replacement || kind == .symlink
            if unrelated {
                guard case .pending = outcome else { Issue.record("Unrelated inode must stay pending"); return }
            }
            if conflict { #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes) }
            else if unrelated {
                // A replaced source inode is not ours, even if it was raced
                // into place by this test. The newer ownership rule leaves it.
                if kind == .replacement { #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == Data(repeating: 0x58, count: oldBytes.count)) }
                else { #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == .other) }
            } else { #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == nil) }
            #expect(try Data(contentsOf: victim) == oldBytes)
            let retry = try HiddenFiles().restore(session: &f.session, journal: f.journal)
            #expect(retry != .clean)
            #expect(try f.journal.read(game: "starrail") != nil)
            if !conflict && !unrelated { #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == nil) }
            if !conflict && kind == .replacement { #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == Data(repeating: 0x58, count: oldBytes.count)) }
            if !conflict && kind == .symlink { #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == .other) }
        }
    }

    @Test(arguments: [LaunchFileStep.beforeClaimWrite, .afterClaimWrite, .afterClaimRename, .afterClaimPostcheck], [false, true])
    func processDeathDuringClaimPublicationIsReverified(point: LaunchFileStep, conflict: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            if conflict { try f.fs.writeAtomically(newBytes, to: gamePath) }
            try f.journal.write(f.session)
            try await crash(point: point, action: "restore", paths: f.paths)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal)
                == (conflict ? .conflict(movedTo: [f.recovery]) : .clean))
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == (conflict ? newBytes : oldBytes))
        }
    }

    @Test(arguments: [false, true])
    func postRenameCrashRejectsSameSizeCorruption(conflict: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            if conflict { try f.fs.writeAtomically(newBytes, to: gamePath) }
            try f.journal.write(f.session)
            try await crash(point: .afterClaimRename, action: "restore", paths: f.paths)
            let moved = conflict ? f.recovery : gamePath.resolved(against: f.session.installRoot)
            let fd = open(moved.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            try #require(fd >= 0)
            defer { close(fd) }
            var before = stat()
            try #require(fstat(fd, &before) == 0)
            let changed = Data(repeating: 0x58, count: oldBytes.count)
            try #require(changed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == changed.count)
            var times = [before.st_atimespec, before.st_mtimespec]
            try #require(futimens(fd, &times) == 0)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) != .clean)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            if conflict { #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes) }
            else { #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == nil) }
        }
    }

    @Test func hardLinkedAtClaimTimeIsQuarantinedWithJournalKept() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            let alias = f.temp.url.appendingPathComponent("alias")
            try #require(link(f.hidden.resolved(against: f.session.installRoot).path, alias.path) == 0)
            try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) != .clean)
            #expect(try f.fs.itemType(at: gamePath, allowingLeafSymlink: true) == nil)
            #expect(try Data(contentsOf: f.recovery) == oldBytes)
            #expect(try Data(contentsOf: alias) == oldBytes)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) != .clean)
            #expect(try f.journal.read(game: "starrail") != nil)
        }
    }
}

enum SourceSwapKind: CaseIterable, Sendable { case replacement, hardLinkMutation, symlink, sameInodeMutation }
private final class SourceSwapOps: FileOps {
    let kind: SourceSwapKind
    let source: URL
    let backup: URL
    let victim: URL
    let triggered = Mutex(false)
    private let base = SystemFileOps()
    init(kind: SourceSwapKind, source: URL, backup: URL, victim: URL) {
        self.kind = kind; self.source = source; self.backup = backup; self.victim = victim
    }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from name: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        let inject = exclusive && name.contains(".macgacha-hidden-") && triggered.withLock { value in
            if value { return false }; value = true; return true
        }
        if inject {
            switch kind {
            case .replacement:
                try FileManager.default.moveItem(at: source, to: backup)
                try Data(repeating: 0x58, count: oldBytes.count).write(to: source)
            case .symlink:
                try FileManager.default.moveItem(at: source, to: backup)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: victim)
            case .sameInodeMutation:
                let fd = open(source.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                try #require(fd >= 0)
                defer { close(fd) }
                var before = stat()
                try #require(fstat(fd, &before) == 0)
                let changed = Data(repeating: 0x58, count: oldBytes.count)
                try #require(changed.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == changed.count)
                var times = [before.st_atimespec, before.st_mtimespec]
                try #require(futimens(fd, &times) == 0)
            case .hardLinkMutation:
                try #require(link(source.path, backup.path) == 0)
                let writer = try FileHandle(forWritingTo: backup)
                defer { try? writer.close() }
                try writer.write(contentsOf: Data(repeating: 0x58, count: oldBytes.count))
            }
        }
        try base.rename(from: name, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}
