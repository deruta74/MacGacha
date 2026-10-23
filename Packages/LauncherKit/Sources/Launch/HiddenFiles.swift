// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum RestoreOutcome: Equatable, Sendable {
    case clean, conflict(movedTo: [URL]), pending(reason: String)
}

/// Synchronous I/O: async callers must use BlockingIO.run and hold session ownership.
public struct HiddenFiles: Sendable {
    private let fileOps: any FileOps
    private let hooks: LaunchFileHooks
    public init() { self.init(fileOps: SystemFileOps(), hooks: .none) }
    package init(fileOps: any FileOps = SystemFileOps(), hooks: LaunchFileHooks = .none) { self.fileOps = fileOps; self.hooks = hooks }
    public func hide(_ paths: [SafeRelativePath], session: inout LaunchSession, journal: LaunchJournal) throws {
        try session.validate()
        guard session.state == .preparing, session.hides.isEmpty, paths.count <= 256,
            Set(paths.map(LaunchSession.pathKey)).count == paths.count,
            !paths.contains(where: { LaunchSession.pathKey($0).contains(".macgacha-hidden") }) else {
            throw LauncherError.io("Invalid hide request or unfinished session")
        }
        if let prior = try journal.read(game: session.game) {
            guard prior.sessionID == session.sessionID, prior.hides.isEmpty, prior.state == .preparing else {
                throw LauncherError.busy("Restore the unfinished launch before hiding files again")
            }
        }
        // The caller's snapshot stage ends only after this durable write. Errors
        // propagate unchanged so the launch manager can label that stage.
        hooks.reach(.beforeSnapshotWrite)
        try journal.write(session)
        hooks.reach(.afterSnapshotWrite)
        let fs = try installFileSystem(session).pinRoot()
        var prepared: [(entry: HideEntry, hidden: SafeRelativePath)] = []
        // Validate every selected target before moving any file.
        for path in paths {
            let name = path.components.last! + ".macgacha-hidden-" + session.sessionID.uuidString
            let hidden = try SafeRelativePath((Array(path.components.dropLast()) + [name]).joined(separator: "/"))
            guard try fs.itemType(at: hidden, allowingLeafSymlink: true) == nil else { throw LauncherError.io("Hide target already exists") }
            guard let fingerprint = try fingerprint(path, in: fs) else { continue } // Optional game file.
            prepared.append((HideEntry(path: path, hiddenName: name, size: fingerprint.size, sha256: fingerprint.sha256, status: .planned), hidden))
        }
        for item in prepared {
            session.hides.append(item.entry)
            hooks.reach(.beforePlannedWrite)
            try journal.write(session)
            hooks.reach(.afterPlannedWrite)
            hooks.reach(.beforeHideRename)
            try fs.moveRegularFile(at: item.entry.path, to: item.hidden, in: fs)
            hooks.reach(.afterHideRename)
            session.hides[session.hides.count - 1].status = .done
            hooks.reach(.beforeDoneWrite)
            try journal.write(session)
            hooks.reach(.afterDoneWrite)
        }
    }
    public func restore(session: inout LaunchSession, journal: LaunchJournal) throws -> RestoreOutcome {
        // Never turn caller-supplied or stale entries into ownership of files.
        guard let persisted = try journal.read(game: session.game), persisted.sessionID == session.sessionID else {
            return .pending(reason: "The launch journal is missing or belongs to another session")
        }
        session = persisted
        do {
            let fs = try installFileSystem(session).pinRoot()
            let recoveryFS = try ContainedFileSystem(root: journal.paths.root, fileOps: fileOps).pinRoot()
            session.state = .restoring
            hooks.reach(.beforeRestoreStateWrite)
            try journal.write(session)
            hooks.reach(.afterRestoreStateWrite)
            var note = try readNote(session, journal: journal)
            while let entry = session.hides.first {
                try restoreEntry(entry, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note)
                session.hides.removeFirst()
                hooks.reach(.beforeResolvedWrite)
                try journal.write(session)
                hooks.reach(.afterResolvedWrite)
                // Only the durable resolved-entry write permits forgetting the
                // inode claim. A crash before it replays the claim and rehashes.
                note.intents?.removeAll { $0.entry.path == entry.path }
                try writeNote(note, session: session, journal: journal)
            }
            // Validate earlier recovery moves as well as entries still in the
            // journal: a crash can happen after the last resolved-entry write.
            for record in note.entries {
                let path = try recoveryPath(record.entry.path, session: session, journal: journal)
                guard try fingerprint(path, in: recoveryFS) == record.actual else {
                    throw LauncherError.io("A recovery copy is missing or changed")
                }
            }
            let conflicts = try note.entries.filter { $0.reason != .duplicate }.map {
                try recoveryPath($0.entry.path, session: session, journal: journal).resolved(against: journal.paths.root)
            }
            session.state = conflicts.isEmpty ? .done : .recoveryConflict
            hooks.reach(.beforeFinalWrite)
            try journal.write(session)
            hooks.reach(.afterFinalWrite)
            hooks.reach(.beforeJournalDelete)
            try journal.delete(game: session.game)
            hooks.reach(.afterJournalDelete)
            return conflicts.isEmpty ? .clean : .conflict(movedTo: conflicts)
        } catch let changed as ChangedSource {
            session.state = .recoveryConflict
            try? journal.write(session)
            return .conflict(movedTo: changed.locations)
        } catch {
            session.state = .recoveryPending
            // A failed metadata write never authorizes deletion. The previous
            // durable snapshot remains sufficient to retry all idempotent moves.
            try? journal.write(session)
            return .pending(reason: "Launch files could not be fully restored: \(error)")
        }
    }

    private func installFileSystem(_ session: LaunchSession) throws -> ContainedFileSystem {
        try ContainedFileSystem(root: session.installRoot, fileOps: fileOps, expectedRootIdentity: session.installIdentity)
    }

    private func restoreEntry(_ entry: HideEntry, session: LaunchSession, fs: ContainedFileSystem,
        recoveryFS: ContainedFileSystem, journal: LaunchJournal, note: inout RecoveryNote) throws {
        let hidden = try session.hiddenPath(entry)
        if let intent = note.intents?.first(where: { $0.entry.path == entry.path }) {
            try replay(intent, entry: entry, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note)
            // Replay resolves only a post-checked moved inode. If the source is
            // still in place, it clears the prepared intent and retries below.
            if note.intents?.contains(where: { $0.entry.path == entry.path }) == true { return }
        }
        let prior = note.entries.first { $0.entry.path == entry.path }
        if let prior, !sameEntry(prior.entry, entry) { throw LauncherError.journalCorrupt("Recovery entry does not match snapshot") }
        guard try fs.itemType(at: hidden, allowingLeafSymlink: true) != nil else {
            if let prior {
                let recovered = try recoveryPath(entry.path, session: session, journal: journal)
                guard try fingerprint(recovered, in: recoveryFS) == prior.actual else {
                    throw LauncherError.io("The recorded recovery move cannot be verified")
                }
                try fs.synchronizeAncestors(of: hidden)
                try recoveryFS.synchronizeAncestors(of: recovered)
            } else if entry.status == .done {
                guard try fingerprint(entry.path, in: fs) == Fingerprint(entry) else {
                    throw LauncherError.io("Both the hidden file and a verified restored original are missing")
                }
                try fs.synchronizeAncestors(of: entry.path)
            } else if try fs.itemType(at: entry.path, allowingLeafSymlink: true) != nil {
                try fs.synchronizeAncestors(of: entry.path)
            }
            return
        }
        try fs.withClaimedFile(at: hidden, permitHardLinks: true) { claim in
            let actual = Fingerprint(size: claim.stamp.size, sha256: claim.sha256)
            let hardLinked = claim.stamp.links != 1
            let direct = try !hardLinked && prior == nil && actual == Fingerprint(entry)
                && fs.itemType(at: entry.path, allowingLeafSymlink: true) == nil
            let destination = direct ? entry.path : try recoveryPath(entry.path, session: session, journal: journal)
            let targetFS = direct ? fs : recoveryFS
            guard try targetFS.itemType(at: destination, allowingLeafSymlink: true) == nil else {
                throw LauncherError.io("Recovery destination already exists")
            }
            if !direct && !hardLinked {
                if let prior {
                    guard prior.actual == actual else { throw LauncherError.io("Hidden copy changed during interrupted recovery") }
                } else {
                    let reason: RecoveryReason = actual != Fingerprint(entry) ? .invalidHidden
                        : (try fingerprint(entry.path, in: fs) == actual ? .duplicate : .differentOriginal)
                    note.entries.append(RecoveryRecord(entry: entry, actual: actual, reason: reason))
                }
            }
            let intent = MoveIntent(entry: entry, stamp: claim.stamp, actual: actual, original: direct, reviewRequired: hardLinked)
            note.intents = (note.intents ?? []) + [intent]
            hooks.reach(.beforeClaimWrite)
            if !direct { hooks.reach(.beforeRecoveryNoteWrite) }
            try writeNote(note, session: session, journal: journal)
            if !direct { hooks.reach(.afterRecoveryNoteWrite) }
            hooks.reach(.afterClaimWrite)
            hooks.reach(direct ? .beforeRestoreRename : .beforeRecoveryRename)
            let verified = try claim.move(to: destination, in: targetFS) {
                hooks.reach(.afterClaimRename)
            }
            hooks.reach(.afterClaimPostcheck)
            if !verified || hardLinked {
                try markChanged(intent, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note,
                    quarantine: !hardLinked)
            }
            hooks.reach(direct ? .afterRestoreRename : .afterRecoveryRename)
        }
    }

    private func replay(_ intent: MoveIntent, entry: HideEntry, session: LaunchSession, fs: ContainedFileSystem,
        recoveryFS: ContainedFileSystem, journal: LaunchJournal, note: inout RecoveryNote) throws {
        guard sameEntry(intent.entry, entry) else { throw LauncherError.journalCorrupt("Move intent does not match snapshot") }
        if intent.reviewRequired {
            if intent.quarantineRequired == true {
                try markChanged(intent, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note)
            }
            throw ChangedSource(locations: [try recoveryPath(entry.path, session: session, journal: journal).resolved(against: journal.paths.root)])
        }
        let hidden = try session.hiddenPath(entry)
        if try fs.itemType(at: hidden, allowingLeafSymlink: true) != nil {
            try fs.withClaimedFile(at: hidden) { claim in
                guard claim.stamp == intent.stamp, claim.sha256 == intent.actual.sha256 else {
                    throw LauncherError.io("Prepared move source changed")
                }
            }
            note.intents?.removeAll { $0.entry.path == entry.path }
            try writeNote(note, session: session, journal: journal)
            return
        }
        let destination = intent.original ? entry.path : try recoveryPath(entry.path, session: session, journal: journal)
        let targetFS = intent.original ? fs : recoveryFS
        guard try targetFS.itemType(at: destination, allowingLeafSymlink: true) != nil else { throw LauncherError.io("Claimed move is missing") }
        guard let current = try targetFS.entryStamp(at: destination), intent.stamp.sameObject(as: current) else {
            throw LauncherError.io("original replaced by another file")
        }
        let verified: Bool
        do {
            verified = try targetFS.withClaimedFile(at: destination) { claim in
                guard intent.stamp.sameContentMetadata(as: claim.stamp), claim.sha256 == intent.actual.sha256 else { return false }
                return try claim.verifiesPublication(at: destination, in: targetFS)
            }
        } catch LauncherError.cancelled { throw LauncherError.cancelled }
        catch { try markChanged(intent, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note); return }
        guard verified else {
            try markChanged(intent, session: session, fs: fs, recoveryFS: recoveryFS, journal: journal, note: &note)
            return
        }
        try fs.synchronizeAncestors(of: hidden)
        try targetFS.synchronizeAncestors(of: destination)
    }

    private func markChanged(_ intent: MoveIntent, session: LaunchSession, fs: ContainedFileSystem,
        recoveryFS: ContainedFileSystem, journal: LaunchJournal, note: inout RecoveryNote, quarantine: Bool = true) throws {
        guard let index = note.intents?.firstIndex(where: { $0.entry.path == intent.entry.path }) else { throw LauncherError.io("Move intent missing") }
        let destination = intent.original ? intent.entry.path : try recoveryPath(intent.entry.path, session: session, journal: journal)
        let sourceFS = intent.original ? fs : recoveryFS
        guard quarantine else {
            note.intents?[index].reviewRequired = true
            note.intents?[index].quarantineRequired = false
            try writeNote(note, session: session, journal: journal)
            throw ChangedSource(locations: [destination.resolved(against: journal.paths.root)])
        }
        let unverified = try SafeRelativePath(recoveryPath(intent.entry.path, session: session, journal: journal).description + ".unverified")
        var operation: QuarantineIntent
        if let existing = note.intents?[index].quarantine {
            operation = existing
        } else {
            guard let current = try sourceFS.entryStamp(at: destination), intent.stamp.sameObject(as: current) else {
                throw LauncherError.io("original replaced by another file")
            }
            operation = QuarantineIntent(expected: intent.stamp, destination: unverified, state: .prepared)
            note.intents?[index].reviewRequired = true
            note.intents?[index].quarantineRequired = true
            note.intents?[index].quarantine = operation
            // The claimed dev/ino and exact target are durable before the
            // quarantine syscall. A pathname alone never establishes ownership.
            try writeNote(note, session: session, journal: journal)
        }
        switch operation.state {
        case .returned:
            throw LauncherError.io("original replaced by another file")
        case .conflict, .quarantined:
            let expected = operation.state == .conflict ? operation.displaced : operation.expected
            guard let expected, let current = try recoveryFS.entryStamp(at: unverified), expected.sameObject(as: current) else {
                throw LauncherError.io("Recorded quarantine changed; manual recovery needed")
            }
            throw ChangedSource(locations: [unverified.resolved(against: journal.paths.root)])
        case .returning:
            try returnDisplaced(operation, index: index, original: destination, sourceFS: sourceFS,
                recoveryFS: recoveryFS, session: session, journal: journal, note: &note)
        case .prepared:
            if let recovered = try recoveryFS.entryStamp(at: unverified) {
                // A crash may precede the post-rename evidence write. Only a
                // matching claimed inode is ours. Keep any other recovery entry
                // in place and record its location; never guess at a rollback.
                if operation.expected.sameObject(as: recovered) { operation.state = .quarantined }
                else { throw LauncherError.io("Quarantine destination identity is uncertain; manual recovery needed") }
                note.intents?[index].quarantine = operation
                try writeNote(note, session: session, journal: journal)
                throw ChangedSource(locations: [unverified.resolved(against: journal.paths.root)])
            }
            hooks.reach(.beforeQuarantineRename)
            let moved = try sourceFS.quarantineEntry(at: destination, to: unverified, in: recoveryFS,
                matching: operation.expected, afterRename: { hooks.reach(.afterQuarantineRename) }) { actual in
                if operation.expected.sameObject(as: actual) { operation.state = .quarantined }
                else { operation.displaced = actual; operation.state = .returning }
                note.intents?[index].quarantine = operation
                try writeNote(note, session: session, journal: journal)
                hooks.reach(.afterQuarantineEvidence)
            }
            guard moved else { throw LauncherError.io("original replaced by another file") }
            if operation.state == .returning {
                try returnDisplaced(operation, index: index, original: destination, sourceFS: sourceFS,
                    recoveryFS: recoveryFS, session: session, journal: journal, note: &note)
            }
            throw ChangedSource(locations: [unverified.resolved(against: journal.paths.root)])
        }
    }

    private func returnDisplaced(_ operation: QuarantineIntent, index: Int, original: SafeRelativePath,
        sourceFS: ContainedFileSystem, recoveryFS: ContainedFileSystem, session: LaunchSession,
        journal: LaunchJournal, note: inout RecoveryNote) throws {
        guard let displaced = operation.displaced else { throw LauncherError.journalCorrupt("Missing displaced identity") }
        var operation = operation
        if try recoveryFS.entryStamp(at: operation.destination) == nil {
            guard let current = try sourceFS.entryStamp(at: original), displaced.sameObject(as: current) else {
                throw LauncherError.io("Displaced file location is uncertain")
            }
            operation.state = .returned
            note.intents?[index].quarantine = operation
            try writeNote(note, session: session, journal: journal)
            throw LauncherError.io("original replaced by another file")
        }
        guard let current = try recoveryFS.entryStamp(at: operation.destination), displaced.sameObject(as: current) else {
            throw LauncherError.io("Displaced recovery file was replaced")
        }
        if try sourceFS.entryStamp(at: original) == nil {
            do {
                // The returning intent already durably contains this inode.
                hooks.reach(.beforeQuarantineReturn)
                let moved = try recoveryFS.quarantineEntry(at: operation.destination, to: original, in: sourceFS,
                    matching: displaced, afterRename: { hooks.reach(.afterQuarantineReturn) }) { actual in
                    operation.returned = actual
                    operation.state = .returned
                    note.intents?[index].quarantine = operation
                    try writeNote(note, session: session, journal: journal)
                }
                guard moved else { throw LauncherError.io("Displaced recovery file was replaced") }
            } catch {
                // A raced-in original wins. Only report the recovery location
                // if the displaced inode is still there; otherwise stay pending.
                guard let recovered = try recoveryFS.entryStamp(at: operation.destination), displaced.sameObject(as: recovered),
                    try sourceFS.entryStamp(at: original) != nil else { throw error }
                operation.state = .conflict
                note.intents?[index].quarantine = operation
                try writeNote(note, session: session, journal: journal)
                throw ChangedSource(locations: [operation.destination.resolved(against: journal.paths.root)])
            }
            throw LauncherError.io("original replaced by another file")
        }
        operation.state = .conflict
        note.intents?[index].quarantine = operation
        try writeNote(note, session: session, journal: journal)
        throw ChangedSource(locations: [operation.destination.resolved(against: journal.paths.root)])
    }

    private func writeNote(_ note: RecoveryNote, session: LaunchSession, journal: LaunchJournal) throws {
        try journal.withOwnership { metadata in
            try journal.writeMetadata(journal.encode(note), to: notePath(session, journal: journal), in: metadata)
        }
    }

    private func readNote(_ session: LaunchSession, journal: LaunchJournal) throws -> RecoveryNote {
        guard let data = try journal.readData(at: notePath(session, journal: journal)) else { return RecoveryNote(sessionID: session.sessionID) }
        let note = try JSONDecoder().decode(RecoveryNote.self, from: data)
        guard note.sessionID == session.sessionID, note.entries.count <= 256,
            Set(note.entries.map { LaunchSession.pathKey($0.entry.path) }).count == note.entries.count else {
            throw LauncherError.journalCorrupt("Invalid recovery note")
        }
        for record in note.entries {
            guard record.actual.size >= 0, record.actual.sha256.algorithm == .sha256,
                record.entry.hiddenName == record.entry.path.components.last! + ".macgacha-hidden-" + session.sessionID.uuidString else {
                throw LauncherError.journalCorrupt("Invalid recovery note entry")
            }
        }
        let intents = note.intents ?? []
        guard intents.count <= 256, Set(intents.map { LaunchSession.pathKey($0.entry.path) }).count == intents.count else {
            throw LauncherError.journalCorrupt("Invalid move intents")
        }
        for intent in intents {
            guard intent.actual.size == intent.stamp.size, intent.actual.size >= 0,
                intent.actual.sha256.algorithm == .sha256, intent.stamp.links > 0,
                intent.entry.hiddenName == intent.entry.path.components.last! + ".macgacha-hidden-" + session.sessionID.uuidString,
                !LaunchSession.pathKey(intent.entry.path).contains(".macgacha-hidden") else {
                throw LauncherError.journalCorrupt("Invalid move intent")
            }
        }
        for intent in intents {
            if let operation = intent.quarantine {
                let target = try SafeRelativePath(recoveryPath(intent.entry.path, session: session, journal: journal).description + ".unverified")
                guard operation.expected.sameObject(as: intent.stamp), operation.destination == target,
                    (operation.state != .returning && operation.state != .conflict) || operation.displaced != nil else {
                    throw LauncherError.journalCorrupt("Invalid quarantine intent")
                }
            }
        }
        // A previous atomic note rename may have become visible before its
        // directory sync failed. Heal that barrier before relying on the note
        // as durable ownership evidence for any game-file move.
        try journal.withOwnership { metadata in
            try metadata.synchronizeAncestors(of: notePath(session, journal: journal))
        }
        return note
    }
    private func sameEntry(_ lhs: HideEntry, _ rhs: HideEntry) -> Bool {
        lhs.path == rhs.path && lhs.hiddenName == rhs.hiddenName && lhs.size == rhs.size && lhs.sha256 == rhs.sha256
    }
    private func recoveryPath(_ path: SafeRelativePath, session: LaunchSession, journal: LaunchJournal) throws -> SafeRelativePath {
        try journal.relative(session.game, "recovery/\(session.sessionID.uuidString)/\(path)")
    }
    private func notePath(_ session: LaunchSession, journal: LaunchJournal) throws -> SafeRelativePath {
        try journal.relative(session.game, "recovery/\(session.sessionID.uuidString).json")
    }
    private func fingerprint(_ path: SafeRelativePath, in fs: ContainedFileSystem) throws -> Fingerprint? {
        guard let size = try fs.size(at: path) else { return nil }
        return try fs.withClaimedFile(at: path) { claim in
            guard claim.stamp.size == size else { throw LauncherError.io("File changed while hashing") }
            return Fingerprint(size: size, sha256: claim.sha256)
        }
    }
}

private struct Fingerprint: Codable, Equatable {
    let size: Int64
    let sha256: Digest
    init(size: Int64, sha256: Digest) { self.size = size; self.sha256 = sha256 }
    init(_ entry: HideEntry) { size = entry.size; sha256 = entry.sha256 }
}
private enum RecoveryReason: String, Codable { case duplicate, differentOriginal, invalidHidden }
private struct RecoveryRecord: Codable {
    let entry: HideEntry
    let actual: Fingerprint
    let reason: RecoveryReason
}
private struct ChangedSource: Error {
    let locations: [URL]
}
private struct MoveIntent: Codable {
    let entry: HideEntry
    let stamp: ContainedFileSystem.ClaimStamp
    let actual: Fingerprint
    let original: Bool
    var reviewRequired: Bool
    var quarantineRequired: Bool?
    var quarantine: QuarantineIntent?
}
private struct QuarantineIntent: Codable {
    enum State: String, Codable { case prepared, quarantined, returning, returned, conflict }
    let expected: ContainedFileSystem.ClaimStamp
    let destination: SafeRelativePath
    var state: State
    var displaced: ContainedFileSystem.ClaimStamp?
    var returned: ContainedFileSystem.ClaimStamp?
}
private struct RecoveryNote: Codable {
    let sessionID: UUID
    var entries: [RecoveryRecord] = []
    var intents: [MoveIntent]?
    var message = "Copies preserved during launch recovery; changed or unverified files were never put over the current game files."
}

/// Explicit process-death seams only; no production environment switches.
package enum LaunchFileStep: String, Sendable {
    case beforeSnapshotWrite, afterSnapshotWrite, beforePlannedWrite, afterPlannedWrite
    case beforeHideRename, afterHideRename, beforeDoneWrite, afterDoneWrite
    case beforeRestoreStateWrite, afterRestoreStateWrite, beforeRestoreRename, afterRestoreRename
    case beforeRecoveryNoteWrite, afterRecoveryNoteWrite, beforeRecoveryRename, afterRecoveryRename
    case beforeClaimWrite, afterClaimWrite, afterClaimRename, afterClaimPostcheck
    case beforeQuarantineRename, afterQuarantineRename, afterQuarantineEvidence, beforeQuarantineReturn, afterQuarantineReturn
    case beforeResolvedWrite, afterResolvedWrite, beforeFinalWrite, afterFinalWrite, beforeJournalDelete, afterJournalDelete
    package static let hideSteps: [Self] = [.beforeSnapshotWrite, .afterSnapshotWrite, .beforePlannedWrite, .afterPlannedWrite,
        .beforeHideRename, .afterHideRename, .beforeDoneWrite, .afterDoneWrite]
    package static let restoreSteps: [Self] = [.beforeRestoreStateWrite, .afterRestoreStateWrite, .beforeRestoreRename, .afterRestoreRename,
        .beforeRecoveryNoteWrite, .afterRecoveryNoteWrite, .beforeRecoveryRename, .afterRecoveryRename,
        .beforeResolvedWrite, .afterResolvedWrite, .beforeFinalWrite, .afterFinalWrite, .beforeJournalDelete, .afterJournalDelete]
}

package struct LaunchFileHooks: Sendable {
    private let point: LaunchFileStep?
    private let action: (@Sendable () -> Void)?
    package static let none = LaunchFileHooks()
    private init() { point = nil; action = nil }
    package init(at point: LaunchFileStep, action: @escaping @Sendable () -> Void) { self.point = point; self.action = action }
    func reach(_ point: LaunchFileStep) { if self.point == point { action?() } }
}
