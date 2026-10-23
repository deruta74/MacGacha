// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct QuarantineOwnershipTests {
    @Test func crashReplayLeavesReplacementOriginalInPlace() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.journal.write(f.session)
            try await crash(point: .afterClaimRename, action: "restore", paths: f.paths)
            let original = gamePath.resolved(against: f.session.installRoot)
            let backup = f.temp.url.appendingPathComponent("updater-backup")
            try FileManager.default.moveItem(at: original, to: backup)
            try newBytes.write(to: original)
            for _ in 0..<2 {
                let outcome = try HiddenFiles().restore(session: &f.session, journal: f.journal)
                guard case .pending(let reason) = outcome else { Issue.record("Expected pending, got \(outcome)"); return }
                #expect(reason.contains("original replaced by another file"))
                #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
                #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            }
            #expect(try Data(contentsOf: backup) == oldBytes)
        }
    }

    @Test func livePostcheckLeavesReplacementOriginalInPlace() async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.journal.write(f.session)
            let original = gamePath.resolved(against: f.session.installRoot)
            let backup = f.temp.url.appendingPathComponent("updater-backup")
            let hooks = LaunchFileHooks(at: .afterClaimRename) {
                do {
                    try FileManager.default.moveItem(at: original, to: backup)
                    try newBytes.write(to: original)
                } catch { Issue.record(error) }
            }
            let outcome = try HiddenFiles(hooks: hooks).restore(session: &f.session, journal: f.journal)
            guard case .pending = outcome else { Issue.record("Expected pending, got \(outcome)"); return }
            #expect(try f.fs.readFile(at: gamePath, maxBytes: 100) == newBytes)
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            #expect(try Data(contentsOf: backup) == oldBytes)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func quarantineSwapRestoresOrRecordsEveryFile(occupyOriginal: Bool, interruptAfterEvidence: Bool) async throws {
        try await BlockingIO.run {
            let f = try LaunchFixture(); f.session.hides = [f.entry()]
            try f.fs.writeAtomically(oldBytes, to: f.hidden); try f.journal.write(f.session)
            let original = gamePath.resolved(against: f.session.installRoot)
            let backup = f.temp.url.appendingPathComponent("replaced-claimed-inode")
            let ops = QuarantineSwapOps(original: original, backup: backup, occupyOriginal: occupyOriginal,
                interruptAfterEvidence: interruptAfterEvidence)
            var outcome = try HiddenFiles(fileOps: ops).restore(session: &f.session, journal: f.journal)
            if interruptAfterEvidence {
                guard case .pending = outcome else { Issue.record("Expected interrupted sync"); return }
                // The displaced identity is already durable even though the
                // directory barrier failed. Replay can safely return that inode.
                outcome = try HiddenFiles().restore(session: &f.session, journal: f.journal)
            }
            #expect(ops.quarantineReached.withLock { $0 })
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
            let recovered = URL(fileURLWithPath: f.recovery.path + ".unverified")
            if occupyOriginal {
                #expect(outcome == .conflict(movedTo: [recovered]))
                #expect(try Data(contentsOf: recovered) == newBytes)
                #expect(try Data(contentsOf: original) == latestBytes)
                let note = try #require(try f.journal.readData(at: f.journal.relative("starrail", "recovery/\(f.session.sessionID.uuidString).json")))
                let decoded = try JSONSerialization.jsonObject(with: note) as? [String: Any]
                let intent = try #require((decoded?["intents"] as? [[String: Any]])?.first)
                let quarantine = try #require(intent["quarantine"] as? [String: Any])
                #expect(quarantine["destination"] as? String == "Games/starrail/recovery/\(f.session.sessionID.uuidString)/\(gamePath).unverified")
                let displaced = try #require(quarantine["displaced"] as? [String: Any])
                var info = stat(); try #require(lstat(recovered.path, &info) == 0)
                #expect((displaced["inode"] as? NSNumber)?.uint64Value == UInt64(info.st_ino))
            } else {
                guard case .pending = outcome else { Issue.record("Expected pending, got \(outcome)"); return }
                #expect(try Data(contentsOf: original) == newBytes)
                #expect(!FileManager.default.fileExists(atPath: recovered.path))
            }
            #expect(try Data(contentsOf: backup) == corruptBytes)
            let retry = try HiddenFiles().restore(session: &f.session, journal: f.journal)
            #expect(retry != .clean)
            #expect(try Data(contentsOf: original) == (occupyOriginal ? latestBytes : newBytes))
            #expect(try f.journal.read(game: "starrail")?.hides.count == 1)
        }
    }
}

private let corruptBytes = Data(repeating: 0x58, count: oldBytes.count)
private let latestBytes = Data("another newer original".utf8)
private final class QuarantineSwapOps: FileOps {
    let original: URL
    let backup: URL
    let occupyOriginal: Bool
    let interruptAfterEvidence: Bool
    let quarantineReached = Mutex(false)
    private let base = SystemFileOps()
    init(original: URL, backup: URL, occupyOriginal: Bool, interruptAfterEvidence: Bool) {
        self.original = original; self.backup = backup; self.occupyOriginal = occupyOriginal
        self.interruptAfterEvidence = interruptAfterEvidence
    }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(fd, bytes: bytes) }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        if interruptAfterEvidence && quarantineReached.withLock({ $0 }) { throw LauncherError.io("Interrupted after displaced evidence") }
        try base.synchronize(fd, durable: durable)
    }
    func rename(from source: String, in src: Int32, to target: String, in dst: Int32, exclusive: Bool) throws {
        if target.hasSuffix(".unverified"), quarantineReached.withLock({ value in
            if value { return false }; value = true; return true
        }) {
            // This seam runs after CFS's source lstat but before its syscall.
            try FileManager.default.moveItem(at: original, to: backup)
            try newBytes.write(to: original)
            try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
            if occupyOriginal { try latestBytes.write(to: original) }
        } else {
            try base.rename(from: source, in: src, to: target, in: dst, exclusive: exclusive)
            if source.contains(".macgacha-hidden-") {
                let writer = try FileHandle(forWritingTo: original)
                defer { try? writer.close() }
                try writer.write(contentsOf: corruptBytes)
            }
        }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try base.unlink(name, in: directory, isDirectory: isDirectory) }
}
