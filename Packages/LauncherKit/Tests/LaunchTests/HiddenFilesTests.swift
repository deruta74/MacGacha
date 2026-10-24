// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import Launch

let gamePath = try! SafeRelativePath("data/vulkan-1.dll")
let oldBytes = Data("original game bytes".utf8)
let newBytes = Data("updated game bytes!".utf8)
func testDigest(_ data: Data) -> Digest { var h = StreamingHasher(.sha256); h.update(data); return h.finalize() }

func testSession(root: URL) throws -> LaunchSession {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return LaunchSession(sessionID: UUID(), game: "starrail", installRoot: root,
        installIdentity: try ContainedFileSystem(root: root).rootIdentity(), prefix: root.appendingPathComponent("prefix"),
        bundleID: "test-bundle", runtimeDigest: testDigest(Data()), wineBinary: root.appendingPathComponent("wine"),
        wineserver: root.appendingPathComponent("wineserver"), componentIDs: ["wine-11", "dxmt-0.80"], recipeVersion: 1,
        settings: .defaults(for: "starrail"))
}

final class LaunchFixture {
    let temp: FixtureDirectory
    let paths: AppPaths
    var session: LaunchSession
    init() throws {
        self.temp = try FixtureDirectory()
        self.paths = AppPaths(root: self.temp.url.appendingPathComponent("store"))
        self.session = try testSession(root: self.temp.url.appendingPathComponent("game"))
    }
    var fs: ContainedFileSystem { try! ContainedFileSystem(root: session.installRoot) }
    var journal: LaunchJournal { LaunchJournal(paths: paths) }
    var hidden: SafeRelativePath { try! SafeRelativePath(gamePath.description + ".macgacha-hidden-" + session.sessionID.uuidString) }
    var recovery: URL { paths.games.appendingPathComponent("starrail/recovery/\(session.sessionID.uuidString)/\(gamePath)") }
    func entry(status: HideEntry.Status = .done) -> HideEntry {
        HideEntry(path: gamePath, hiddenName: hidden.components.last!, size: Int64(oldBytes.count), sha256: testDigest(oldBytes), status: status)
    }
}

final class FixtureDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite(.timeLimit(.minutes(1))) struct HiddenFilesTests {
    @Test(arguments: [false, true]) func cleanRestoreDoesNotPublishEmptyRecoveryReport(noHiddenFiles: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            if !noHiddenFiles {
                try f.fs.writeAtomically(oldBytes, to: f.hidden)
                f.session.hides = [f.entry()]
            }
            let metadata = try ContainedFileSystem(root: f.paths.root)
            let existing = try SafeRelativePath("Games/starrail/recovery/older-session.json")
            let sentinel = Data("existing user recovery record".utf8)
            try metadata.writeAtomically(sentinel, to: existing)
            try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try metadata.itemType(at: SafeRelativePath("Games/starrail/recovery/\(f.session.sessionID.uuidString).json")) == nil)
            #expect(try metadata.readFile(at: existing, maxBytes: 100) == sentinel)
        }
    }

    @Test func preservedCopiesStillHaveRecoveryReport() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            try f.fs.writeAtomically(newBytes, to: gamePath); try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [f.recovery]))
            let data = try ContainedFileSystem(root: f.paths.root).readFile(at: SafeRelativePath("Games/starrail/recovery/\(f.session.sessionID.uuidString).json"), maxBytes: 1 << 20)
            let report = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((report["entries"] as? [Any])?.count == 1)
            #expect(try Data(contentsOf: f.recovery) == oldBytes)
        }
    }

    @Test func cleanRestoreLeavesLegacyReportUntouched() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture()
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            let path = try SafeRelativePath("Games/starrail/recovery/\(f.session.sessionID.uuidString).json")
            let report = Data("{\"sessionID\":\"\(f.session.sessionID.uuidString)\",\"entries\":[],\"message\":\"legacy report\"}".utf8)
            let metadata = try ContainedFileSystem(root: f.paths.root)
            try metadata.writeAtomically(report, to: path)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try metadata.readFile(at: path, maxBytes: 1000) == report)
        }
    }

    // Restore-table row 1.
    @Test func missingOriginalMatchingHiddenIsRestored() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.itemType(at: f.hidden) == nil)
            #expect(try f.journal.read(game: "starrail") == nil)
        }
    }
    // Restore-table row 2. Preserve duplicate bytes under the user's no-delete rule.
    @Test func identicalOriginalDropsHiddenFromGameWithoutDeletingBytes() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath); try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.itemType(at: f.hidden) == nil)
            #expect(try Data(contentsOf: f.recovery) == oldBytes)
        }
    }
    // Restore-table row 3.
    @Test func conflictMovesHiddenToRecoveryAndAllowsNextHide() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(newBytes, to: gamePath); try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session.hides = [f.entry()]; try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [f.recovery]))
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
            #expect(try Data(contentsOf: f.recovery) == oldBytes)
            #expect(try f.journal.read(game: "starrail") == nil)
            var next = try testSession(root: f.session.installRoot)
            try HiddenFiles().hide([gamePath], session: &next, journal: f.journal)
            #expect(try HiddenFiles().restore(session: &next, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
        }
    }
    // Restore-table row 4, with and without an original.
    @Test(arguments: [false, true]) func plannedWithNoHiddenDropsEntry(original: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); if original { try f.fs.writeAtomically(oldBytes, to: gamePath) }
            f.session.hides = [f.entry(status: .planned)]; try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(f.session.hides.isEmpty)
            #expect(try f.fs.size(at: gamePath) == (original ? Int64(oldBytes.count) : nil))
        }
    }
    // Restore-table row 5.
    @Test func missingBothIsPending() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]; try f.journal.write(f.session)
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            #expect(f.session.state == .recoveryPending)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
        }
    }
    @Test(arguments: [oldBytes, newBytes]) func missingHiddenDoneRequiresMatchingRestoredOriginal(original: Data) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]; try f.fs.writeAtomically(original, to: gamePath); try f.journal.write(f.session)
            let result = try HiddenFiles().restore(session: &f.session, journal: f.journal)
            if original == oldBytes { #expect(result == .clean) }
            else { guard case .pending = result else { Issue.record("Unproven restore must stay pending"); return } }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == original)
        }
    }
    @Test(arguments: [Data("bad".utf8), Data(repeating: 7, count: oldBytes.count)]) func corruptedHiddenGoesToRecoveryNotOriginal(bytes: Data) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]; try f.fs.writeAtomically(bytes, to: f.hidden); try f.journal.write(f.session)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [f.recovery]))
            #expect(try f.fs.itemType(at: gamePath) == nil)
            #expect(try Data(contentsOf: f.recovery) == bytes)
        }
    }
    @Test func hideRefusesExistingTargetBeforeAnyChanges() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); let first = try SafeRelativePath("first.exe")
            try f.fs.writeAtomically(oldBytes, to: first); try f.fs.writeAtomically(oldBytes, to: gamePath); try f.fs.writeAtomically(newBytes, to: f.hidden)
            #expect(throws: LauncherError.self) { try HiddenFiles().hide([first, gamePath], session: &f.session, journal: f.journal) }
            #expect(try f.fs.readFile(at: first, maxBytes: 100) == oldBytes)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == newBytes)
            #expect(f.session.hides.isEmpty)
        }
    }
    @Test func foreignHiddenFileUntouched() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); let foreign = try SafeRelativePath(gamePath.description + ".macgacha-hidden-OTHER")
            try f.fs.writeAtomically(newBytes, to: foreign); try f.fs.writeAtomically(oldBytes, to: gamePath)
            try HiddenFiles().hide([gamePath], session: &f.session, journal: f.journal)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: foreign, maxBytes: 100) == newBytes)
        }
    }
    @Test(arguments: [false, true]) func volumeGoneOrReplacedIsPending(replace: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath)
            try HiddenFiles().hide([gamePath], session: &f.session, journal: f.journal)
            let oldRoot = f.temp.url.appendingPathComponent("unmounted")
            try FileManager.default.moveItem(at: f.session.installRoot, to: oldRoot)
            if replace { try FileManager.default.createDirectory(at: f.session.installRoot, withIntermediateDirectories: true) }
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            #expect(FileManager.default.fileExists(atPath: f.session.installRoot.path) == replace)
            #expect(try f.journal.read(game: "starrail") != nil)
            if replace { try FileManager.default.removeItem(at: f.session.installRoot) }
        }
    }
    @Test func journalWriteFailsBeforeAnyHide() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath)
            let journal = LaunchJournal(paths: f.paths, fileOps: LaunchFaultOps(failWrite: true))
            #expect(throws: LauncherError.insufficientSpace(required: 1, available: 0)) {
                try HiddenFiles().hide([gamePath], session: &f.session, journal: journal)
            }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.itemType(at: f.hidden) == nil)
        }
    }
    @Test func existingRecoveryTargetIsNeverOverwritten() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.fs.writeAtomically(newBytes, to: gamePath); try f.journal.write(f.session)
            try FileManager.default.createDirectory(at: f.recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newBytes.write(to: f.recovery)
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            #expect(try Data(contentsOf: f.recovery) == newBytes)
            #expect(try f.journal.read(game: "starrail") != nil)
        }
    }
    @Test func failedRecoveryMoveKeepsJournalAndBothGameFiles() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.fs.writeAtomically(newBytes, to: gamePath); try f.journal.write(f.session)
            let files = HiddenFiles(fileOps: LaunchFaultOps(failExclusive: true))
            guard case .pending = try files.restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
            #expect(try f.journal.read(game: "starrail") != nil)
        }
    }
    @Test func newOriginalAppearingAtRenameIsNeverReplaced() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.journal.write(f.session)
            let ops = RestoreRaceOps(original: gamePath.resolved(against: f.session.installRoot))
            guard case .pending = try HiddenFiles(fileOps: ops).restore(session: &f.session, journal: f.journal) else {
                Issue.record("Expected non-replacing rename to fail"); return
            }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
        }
    }
    @Test(arguments: ["data/x.macgacha-hidden-other", "data/x.MACGACHA-HIDDEN-other"]) func explicitlyRequestedForeignHiddenIsRejected(path: String) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(), path = try SafeRelativePath(path)
            try f.fs.writeAtomically(oldBytes, to: path)
            #expect(throws: LauncherError.self) { try HiddenFiles().hide([path], session: &f.session, journal: f.journal) }
            #expect(try f.fs.readFile(at: path, maxBytes: 100) == oldBytes)
        }
    }
    @Test func symlinkAncestorIsPendingAndOutsideFilesAreUntouched() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]; try f.journal.write(f.session)
            let outside = f.temp.url.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let outsideHidden = outside.appendingPathComponent(f.hidden.components.last!)
            try oldBytes.write(to: outsideHidden)
            try FileManager.default.createSymbolicLink(at: f.session.installRoot.appendingPathComponent("data"), withDestinationURL: outside)
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            #expect(try Data(contentsOf: outsideHidden) == oldBytes)
            #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("vulkan-1.dll").path))
        }
    }
    @Test func partialConflictRecoveryKeepsUnresolvedEntryAndPriorRecoveryEvidence() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(), first = try SafeRelativePath("first.exe")
            try f.fs.writeAtomically(oldBytes, to: first); try f.fs.writeAtomically(oldBytes, to: gamePath)
            try HiddenFiles().hide([first, gamePath], session: &f.session, journal: f.journal)
            try f.fs.writeAtomically(newBytes, to: first)
            try f.fs.removeFile(at: f.hidden) // Simulate a lost hidden copy, not a launcher action.
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: f.journal) else { Issue.record("Expected pending"); return }
            let read = try #require(try f.journal.read(game: "starrail"))
            #expect(read.hides.map(\.path) == [gamePath])
            #expect(try f.fs.readFile(at: first, maxBytes: 100) == newBytes)
            let previous = f.recovery.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("first.exe")
            #expect(try Data(contentsOf: previous) == oldBytes)
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            f.session = read
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [previous]))
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.journal.read(game: "starrail") == nil)
        }
    }
    @Test(arguments: [HideEntry.Status.planned, .done], [false, true])
    func replayedRenameMustHealDirectoryDurabilityBeforeResolving(status: HideEntry.Status, conflict: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry(status: status)]
            try f.fs.writeAtomically(oldBytes, to: f.hidden)
            if conflict {
                try f.fs.writeAtomically(newBytes, to: gamePath)
                try FileManager.default.createDirectory(at: f.recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try f.journal.write(f.session)
            let failing = HiddenFiles(fileOps: GameDirectorySyncFailure())
            // First attempt does the rename, then fails its directory sync.
            guard case .pending = try failing.restore(session: &f.session, journal: f.journal) else { Issue.record("Expected failed sync"); return }
            #expect(try f.fs.itemType(at: f.hidden) == nil)
            // Merely observing matching bytes must not skip the missing barrier.
            guard case .pending = try failing.restore(session: &f.session, journal: f.journal) else { Issue.record("Retry skipped directory durability"); return }
            #expect(try f.journal.read(game: "starrail") != nil)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == (conflict ? .conflict(movedTo: [f.recovery]) : .clean))
        }
    }
    @Test func observedRecoveryNoteMustBeDurableBeforeMovingGameBytes() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.fs.writeAtomically(newBytes, to: gamePath)
            try FileManager.default.createDirectory(at: f.recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
            try f.journal.write(f.session)
            let failing = LaunchJournal(paths: f.paths, fileOps: RecoveryNoteDirectorySyncFailure())
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: failing) else { Issue.record("Expected note sync failure"); return }
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            guard case .pending = try HiddenFiles().restore(session: &f.session, journal: failing) else { Issue.record("Visible note was treated as durable"); return }
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [f.recovery]))
        }
    }
    @Test func existingRecoveryAncestorsHealFailedCreationSyncOnRetry() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.fs.writeAtomically(newBytes, to: gamePath); try f.journal.write(f.session)
            let failing = HiddenFiles(fileOps: DirectoryChainSyncFailure(suffix: "/" + f.session.sessionID.uuidString))
            guard case .pending = try failing.restore(session: &f.session, journal: f.journal) else { Issue.record("Expected recovery ancestor sync failure"); return }
            #expect(FileManager.default.fileExists(atPath: f.recovery.deletingLastPathComponent().path))
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            guard case .pending = try failing.restore(session: &f.session, journal: f.journal) else { Issue.record("Retry skipped ancestor creation barrier"); return }
            #expect(try f.fs.readFile(at: f.hidden, maxBytes: 100) == oldBytes)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .conflict(movedTo: [f.recovery]))
        }
    }
    @Test func existingJournalAncestorsHealFailedCreationSyncBeforeAnyHide() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath)
            let failing = LaunchJournal(paths: f.paths, fileOps: DirectoryChainSyncFailure(suffix: "/store"))
            #expect(throws: LauncherError.self) { try HiddenFiles().hide([gamePath], session: &f.session, journal: failing) }
            #expect(throws: LauncherError.self) { try HiddenFiles().hide([gamePath], session: &f.session, journal: failing) }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
            #expect(try f.fs.itemType(at: f.hidden) == nil)
        }
    }
    @Test func staleHideRetryCannotEraseDurableOwnershipOfHiddenFiles() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); try f.fs.writeAtomically(oldBytes, to: gamePath)
            var stale = f.session
            try HiddenFiles().hide([gamePath], session: &f.session, journal: f.journal)
            #expect(throws: LauncherError.self) { try HiddenFiles().hide([gamePath], session: &stale, journal: f.journal) }
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            #expect(try HiddenFiles().restore(session: &f.session, journal: f.journal) == .clean)
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == oldBytes)
        }
    }
}

private struct DirectoryChainSyncFailure: FileOps {
    let suffix: String
    private let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        try #require(bytes.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) } == 0)
        let path = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if path.hasSuffix(suffix) { throw LauncherError.io("Injected ancestor sync failure") }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private final class RecoveryNoteDirectorySyncFailure: FileOps {
    private let base = SystemFileOps()
    private let renamed = Mutex(false)
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        try #require(bytes.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) } == 0)
        let path = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if renamed.withLock({ $0 }) && path.hasSuffix("/recovery") { throw LauncherError.io("Injected recovery-note parent sync failure") }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
        let publicNote = target.hasSuffix(".json") && UUID(uuidString: String(target.dropLast(5))) != nil
        let privateState = target.hasPrefix(".") && target.hasSuffix(".state") && UUID(uuidString: String(target.dropFirst().dropLast(6))) != nil
        if publicNote || privateState { renamed.withLock { $0 = true } }
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private final class GameDirectorySyncFailure: FileOps {
    private let base = SystemFileOps()
    private let renamed = Mutex(false)
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        if renamed.withLock({ $0 }) { throw LauncherError.io("Injected directory sync failure") }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
        renamed.withLock { $0 = true }
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}

private struct RestoreRaceOps: FileOps {
    let original: URL
    private let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        #expect(exclusive, "Every game-file rename must be non-replacing")
        try newBytes.write(to: original)
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws {
        Issue.record("Game files must never be deleted")
        try base.unlink(name, in: dir, isDirectory: isDirectory)
    }
}

struct LaunchFaultOps: FileOps {
    var failWrite = false
    var failExclusive = false
    var failJournalRename = false
    private let base = SystemFileOps()
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if failWrite { throw LauncherError.insufficientSpace(required: 1, available: 0) }
        return try base.write(fd, bytes: bytes)
    }
    func synchronize(_ fd: Int32, durable: Bool) throws { try base.synchronize(fd, durable: durable) }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        if failExclusive && exclusive { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
        if failJournalRename && target == "launch-session.json" { throw LauncherError.io("Injected journal rename failure") }
        try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
    }
    func unlink(_ name: String, in dir: Int32, isDirectory: Bool) throws { try base.unlink(name, in: dir, isDirectory: isDirectory) }
}
