// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import GameLibrary
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct LaunchJournalTests {
    @Test func snapshotRoundTripsWithoutConsultingCurrentSettings() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            #expect(try f.journal.read(game: "starrail") == nil)
            f.session.processes = [ProcessIdentity(pid: 42, startTime: 123456)]; f.session.proxyPort = 1234
            f.session.hides = [f.entry(status: .planned)]; f.session.state = .running
            try f.journal.write(f.session)
            var changed = f.session.settings; changed.backend = .dxmt; changed.retina = true; changed.frameLimit = 120
            try LaunchSettingsStore(paths: f.paths).save(changed, for: "starrail")
            let read = try #require(try f.journal.read(game: "starrail"))
            #expect(read == f.session)
            #expect(read.settings != changed)
        }
    }
    @Test func corruptJournalThrowsAndIsNotRemoved() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(), fs = try ContainedFileSystem(root: f.paths.root)
            try fs.writeAtomically(Data("bad json".utf8), to: SafeRelativePath("Games/starrail/launch-session.json"))
            #expect(throws: LauncherError.self) { try f.journal.read(game: "starrail") }
            #expect(try fs.readFile(at: SafeRelativePath("Games/starrail/launch-session.json"), maxBytes: 100) == Data("bad json".utf8))
        }
    }
    @Test func failedAtomicWriteLeavesPreviousSnapshotAndNoTemporary() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.journal.write(f.session)
            f.session.state = .running
            #expect(throws: LauncherError.self) { try LaunchJournal(paths: f.paths, fileOps: LaunchFaultOps(failJournalRename: true)).write(f.session) }
            #expect(try f.journal.read(game: "starrail")?.state == .preparing)
            let entries = try FileManager.default.contentsOfDirectory(atPath: f.paths.games.appendingPathComponent("starrail").path)
            #expect(entries == ["launch-session.json"])
        }
    }
    @Test func journalDeletedOnlyWhenResolved() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]; try f.journal.write(f.session)
            #expect(throws: LauncherError.self) { try f.journal.delete(game: "starrail") }
            #expect(try f.journal.read(game: "starrail") != nil)
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.journal.read(game: "starrail") == nil)
        }
    }
    @Test func otherSessionCannotReplaceAnExistingJournal() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.journal.write(f.session)
            let other = try testSession(root: f.session.installRoot)
            #expect(throws: LauncherError.self) { try f.journal.write(other) }
            #expect(try f.journal.read(game: "starrail")?.sessionID == f.session.sessionID)
        }
    }
    @Test func unsafeOrMismatchedHideEntriesAreRejected() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            for name in ["../escape", "foreign.macgacha-hidden-OTHER", "data/escape"] {
                f.session.hides = [HideEntry(path: gamePath, hiddenName: name, size: 1, sha256: testDigest(Data()), status: .done)]
                #expect(throws: LauncherError.self) { try f.journal.write(f.session) }
            }
        }
    }
    @Test func orphanReconciliationCannotDeleteSnapshotOrRecovery() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.journal.write(f.session)
            let fs = try ContainedFileSystem(root: f.paths.root)
            try fs.writeAtomically(oldBytes, to: SafeRelativePath("Games/starrail/recovery/prior/file"))
            let store = GameRecordStore(directory: f.paths.games), lease = try await store.acquireOperationLease()
            defer { withExtendedLifetime(lease) {} }
            try await store.cleanupOrphanGameDirectory("starrail")
            #expect(try f.journal.read(game: "starrail") != nil)
            #expect(try fs.readFile(at: SafeRelativePath("Games/starrail/recovery/prior/file"), maxBytes: 100) == oldBytes)
        }
    }
}
