// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import GameLibrary
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct HiddenFilesCrashTests {
    @Test func hideWritesPlannedBeforeRename() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath); try f.journal.write(f.session)
            try await crash(point: .afterPlannedWrite, action: "hide", paths: f.paths)
            f.session = try #require(try f.journal.read(game: "starrail"))
            #expect(f.session.hides.first?.status == .planned)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.itemType(at: f.hidden) == nil)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
        }
    }
    @Test(arguments: ["afterTempCreate", "afterTempWrite", "beforeTempSync", "afterTempSync", "beforeRename", "afterRename", "beforeDirectorySync", "afterDirectorySync"])
    func processDeathInsideAtomicJournalWriteKeepsValidSnapshot(point: String) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath); try f.journal.write(f.session)
            let harness = Bundle(for: LaunchCrashBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
            let result = try await SystemProcessRunner().run(harness, arguments: ["launch-journal-write", f.paths.root.path, point], environment: [:], currentDirectory: nil)
            #expect(result.exitCode == 137)
            let snapshot = try #require(try f.journal.read(game: "starrail"))
            #expect(snapshot.sessionID == f.session.sessionID)
            #expect(snapshot.state == .preparing || snapshot.state == .running)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            let records = GameRecordStore(directory: f.paths.games), lease = try await records.acquireOperationLease()
            defer { withExtendedLifetime(lease) {} }
            try await records.cleanupOrphanGameDirectory("starrail")
            #expect(try f.journal.read(game: "starrail") == snapshot)
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.games.appendingPathComponent("starrail").path) == ["launch-session.json"])
        }
    }
    @Test(arguments: LaunchFileStep.hideSteps) func processDeathAtEveryHideBoundary(point: LaunchFileStep) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath); try f.journal.write(f.session)
            try await crash(point: point, action: "hide", paths: f.paths)
            f.session = try #require(try f.journal.read(game: "starrail"))
            if point == .afterPlannedWrite || point == .beforeHideRename {
                #expect(f.session.hides.first?.status == .planned)
                #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            }
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.journal.read(game: "starrail") == nil)
        }
    }
    @Test(arguments: LaunchFileStep.restoreSteps) func processDeathAtEveryRestoreBoundary(point: LaunchFileStep) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            let direct = point == .beforeRestoreRename || point == .afterRestoreRename
            if !direct { try f.fs.writeAtomically(newBytes, to: gamePath) }
            try await crash(point: point, action: "restore", paths: f.paths)
            if let read = try f.journal.read(game: "starrail") {
                f.session = read
                let result = try HiddenFiles().restore(session: &f.session, journal: f.journal)
                #expect(result == (direct ? .clean : .conflict(movedTo: [f.recovery])))
            }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == (direct ? oldBytes : newBytes))
            if !direct { #expect(try Data(contentsOf: f.recovery) == oldBytes) }
            #expect(try f.journal.read(game: "starrail") == nil)
        }
    }
}

private final class LaunchCrashBundleToken: NSObject {}
func crash(point: LaunchFileStep, action: String, paths: AppPaths) async throws {
    let harness = Bundle(for: LaunchCrashBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    let result = try await SystemProcessRunner().run(harness, arguments: ["launch-files", paths.root.path, point.rawValue, action],
        environment: [:], currentDirectory: nil)
    #expect(result.exitCode == 137, "Crash boundary not reached: \(point) / \(result)")
}
