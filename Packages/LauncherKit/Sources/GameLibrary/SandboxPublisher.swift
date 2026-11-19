// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

package enum SandboxPublishPoint: String, CaseIterable, Sendable {
    case planned, retired, treePublished, listPublished, swapped, recordSaved, cleaned, beforeCleanupRemoval
}
package struct SandboxPublishHooks: Sendable {
    let reach: @Sendable (SandboxPublishPoint) throws -> Void
    package init(_ reach: @escaping @Sendable (SandboxPublishPoint) throws -> Void = { _ in }) { self.reach = reach }
}

/// The caller retains the operation lease and session lock throughout this transaction.
struct SandboxPublisher: Sendable {
    let store: GameRecordStore
    var fileOps: any FileOps = SystemFileOps()
    var hooks = SandboxPublishHooks()
    var log: EventLog? = nil
    static let journalName = "sandbox-journal.json"

    func publish(game: String, record: GameRecord, stage: SafeRelativePath, installation: SandboxInstallation?) async throws {
        try await BlockingIO.run {
            guard try await store.readState(Self.journalName, for: game, maxBytes: 65536) == nil else {
                throw LauncherError.busy("Sandbox recovery is required")
            }
            let fs = try filesystem(record), stageFS = try fs.pinDirectoryIfPresent(at: stage)
            guard let stageFS else { throw LauncherError.io("Sandbox staging is missing") }
            _ = try SandboxFiles.configData(setting: installation?.version, in: fs)
            let list = installation?.listPath ?? record.sandbox?.listPath ?? SandboxFiles.defaultList
            try SandboxFiles.validateListPath(list)
            guard record.sandbox == nil || record.sandbox?.listPath == list else { throw LauncherError.io("Sandbox list changed") }
            let oldTree = try fs.pinDirectoryIfPresent(at: SandboxFiles.assets)?.rootIdentity()
            if try fs.itemType(at: SandboxFiles.assets, allowingLeafSymlink: true) != nil, oldTree == nil {
                throw LauncherError.unsafePath("Invalid sandbox directory")
            }
            let newTree: FileSystemIdentity?
            var newDigest: String?
            if installation != nil {
                guard let newFS = try fs.pinDirectoryIfPresent(at: child(stage, "new/BeyondAssets")) else {
                    throw LauncherError.io("Sandbox staging is missing")
                }
                newTree = try newFS.rootIdentity()
                newDigest = try digest(fs.readFile(at: child(stage, "new/" + list.description), maxBytes: SandboxFiles.maximumListBytes))
            } else { newTree = nil }
            var oldDigest: String?
            if try fs.itemType(at: list) != nil {
                let bytes = try fs.readFile(at: list, maxBytes: SandboxFiles.maximumListBytes)
                oldDigest = digest(bytes)
                try fs.writeAtomically(bytes, to: child(stage, "previous-list"))
            }
            try fs.synchronizeTree(at: stage)
            let journal = Journal(state: .planned, rolledBack: false, root: record.installPath, rootIdentity: record.installIdentity,
                stage: stage, stageIdentity: try stageFS.rootIdentity(), list: list,
                previous: record.sandbox, desired: installation, oldTree: oldTree, newTree: newTree,
                oldListDigest: oldDigest, newListDigest: newDigest)
            try await save(journal, game: game)
            try hooks.reach(.planned)
            if let oldTree { try fs.moveDirectory(at: SandboxFiles.assets, to: child(stage, "retired"), in: fs, matching: oldTree) }
            try hooks.reach(.retired)
            if let newTree { try fs.moveDirectory(at: child(stage, "new/BeyondAssets"), to: SandboxFiles.assets, in: fs, matching: newTree) }
            try hooks.reach(.treePublished)
            try requireList(fs, journal: journal, allowed: [journal.oldListDigest])
            if installation != nil {
                try fs.writeAtomically(fs.readFile(at: child(stage, "new/" + list.description), maxBytes: SandboxFiles.maximumListBytes), to: list)
            } else { try fs.removeFile(at: list) }
            try fs.synchronizeParentDirectory(of: list)
            try hooks.reach(.listPublished)
            var swapped = journal; swapped.state = .swapped
            try await save(swapped, game: game)
            try hooks.reach(.swapped)
            // Once swapped, cancellation cannot strand half-published metadata.
            try await Task.detached { try await finish(swapped, game: game, record: record) }.value
        }
    }

    /// Returns whether recovery finished a durable swap.
    @discardableResult func recover(game: String) async throws -> Bool {
        try await BlockingIO.run {
            guard let data = try await store.readState(Self.journalName, for: game, maxBytes: 65536) else { return false }
            let journal: Journal
            do { journal = try JSONDecoder().decode(Journal.self, from: data); try journal.validate() }
            catch { throw LauncherError.journalCorrupt("Invalid sandbox journal") }
            guard let record = try await store.load(game), record.installPath == journal.root,
                record.installIdentity == journal.rootIdentity else { throw LauncherError.journalCorrupt("Sandbox installation changed") }
            let fs = try filesystem(record)
            let stageFS = try fs.pinDirectoryIfPresent(at: journal.stage)
            if let stageFS { guard try stageFS.rootIdentity() == journal.stageIdentity else { throw LauncherError.io("Sandbox staging changed") } }
            else if journal.state != .cleaned { throw LauncherError.io("Sandbox staging is missing") }
            if journal.state != .planned {
                if journal.rolledBack {
                    guard try fs.pinDirectoryIfPresent(at: SandboxFiles.assets)?.rootIdentity() == journal.newTree else {
                        throw LauncherError.io("Sandbox directory changed")
                    }
                    try requireList(fs, journal: journal, allowed: [journal.newListDigest])
                    try fs.synchronizeParentDirectory(of: SandboxFiles.assets)
                    try fs.synchronizeParentDirectory(of: journal.list)
                    try await cleanup(journal, fs: fs, game: game)
                } else { try await finish(journal, game: game, record: record) }
                return !journal.rolledBack
            }
            // Both sides of a possibly completed rename are inspected by identity.
            if let current = try fs.pinDirectoryIfPresent(at: SandboxFiles.assets) {
                let identity = try current.rootIdentity()
                if identity == journal.newTree {
                    try fs.moveDirectory(at: SandboxFiles.assets, to: child(journal.stage, "discarded"), in: fs, matching: identity)
                } else if identity != journal.oldTree { throw LauncherError.io("Sandbox directory changed") }
            } else if try fs.itemType(at: SandboxFiles.assets, allowingLeafSymlink: true) != nil { throw LauncherError.unsafePath("Invalid sandbox directory") }
            if let old = journal.oldTree {
                if let current = try fs.pinDirectoryIfPresent(at: SandboxFiles.assets) {
                    guard try current.rootIdentity() == old else { throw LauncherError.io("Sandbox directory changed") }
                } else {
                    try fs.moveDirectory(at: child(journal.stage, "retired"), to: SandboxFiles.assets, in: fs, matching: old)
                }
            }
            try fs.synchronizeParentDirectory(of: SandboxFiles.assets)
            try requireList(fs, journal: journal, allowed: [journal.oldListDigest, journal.newListDigest])
            if let old = journal.oldListDigest {
                let bytes = try fs.readFile(at: child(journal.stage, "previous-list"), maxBytes: SandboxFiles.maximumListBytes)
                guard digest(bytes) == old else { throw LauncherError.journalCorrupt("Sandbox backup changed") }
                try fs.writeAtomically(bytes, to: journal.list)
            } else { try fs.removeFile(at: journal.list) }
            try fs.synchronizeParentDirectory(of: journal.list)
            // Mark rollback durable before deleting its only recovery inputs.
            var rolledBack = journal
            rolledBack.state = .cleaned; rolledBack.rolledBack = true; rolledBack.desired = journal.previous
            rolledBack.newTree = journal.oldTree; rolledBack.newListDigest = journal.oldListDigest
            try await save(rolledBack, game: game)
            try await cleanup(rolledBack, fs: fs, game: game)
            return false
        }
    }

    private func finish(_ journal: Journal, game: String, record: GameRecord) async throws {
        try await BlockingIO.run {
            let fs = try filesystem(record)
            let current = try fs.pinDirectoryIfPresent(at: SandboxFiles.assets)?.rootIdentity()
            guard current == journal.newTree else { throw LauncherError.io("Sandbox directory changed") }
            try requireList(fs, journal: journal, allowed: [journal.newListDigest])
            try fs.synchronizeParentDirectory(of: SandboxFiles.assets)
            try fs.synchronizeParentDirectory(of: journal.list)
            // Re-load under the same lease; never overwrite an advanced game build.
            guard var updated = try await store.load(game), updated.installIdentity == journal.rootIdentity,
                updated.installPath == journal.root else { throw LauncherError.io("Sandbox installation changed") }
            updated.sandbox = journal.desired
            updated.sandboxListPath = journal.list
            if journal.state == .swapped {
                do { try SandboxFiles.writeConfigVersion(journal.desired?.version, in: fs) }
                catch { log?.post(.warning, "sandbox", "Skipped config update after sandbox swap") }
            }
            try await store.save(updated, for: game)
            try hooks.reach(.recordSaved)
            var cleaned = journal; cleaned.state = .cleaned
            try await save(cleaned, game: game)
            try hooks.reach(.cleaned)
            try await cleanup(cleaned, fs: fs, game: game)
        }
    }
    private func cleanup(_ journal: Journal, fs: ContainedFileSystem, game: String) async throws {
        if let stage = try fs.pinDirectoryIfPresent(at: journal.stage) {
            guard try stage.rootIdentity() == journal.stageIdentity else { throw LauncherError.io("Sandbox staging changed") }
            try hooks.reach(.beforeCleanupRemoval)
            try stage.removePinnedRoot(onlyIfEmpty: false)
        }
        // Retry both barriers even after an uncertain unlink/rename result.
        try fs.synchronizeParentDirectory(of: journal.stage)
        try await store.deleteState(Self.journalName, for: game)
    }
    private func requireList(_ fs: ContainedFileSystem, journal: Journal, allowed: [String?]) throws {
        let current: String?
        if try fs.itemType(at: journal.list) == nil { current = nil }
        else { current = digest(try fs.readFile(at: journal.list, maxBytes: SandboxFiles.maximumListBytes)) }
        guard allowed.contains(where: { $0 == current }) else { throw LauncherError.io("Sandbox list changed") }
    }
    private func filesystem(_ record: GameRecord) throws -> ContainedFileSystem {
        try ContainedFileSystem(root: record.installPath, fileOps: fileOps, expectedRootIdentity: record.installIdentity).pinRoot()
    }
    private func child(_ stage: SafeRelativePath, _ leaf: String) throws -> SafeRelativePath { try SafeRelativePath(stage.description + "/" + leaf) }
    private func digest(_ data: Data) -> String { var h = StreamingHasher(.sha256); h.update(data); return h.finalize().hex }
    private func save(_ journal: Journal, game: String) async throws {
        try journal.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await store.writeState(encoder.encode(journal), named: Self.journalName, for: game)
    }
    private struct Journal: Codable, Sendable {
        enum State: String, Codable { case planned, swapped, cleaned }
        var state: State
        var rolledBack: Bool
        let root: URL
        let rootIdentity: FileSystemIdentity
        let stage: SafeRelativePath
        let stageIdentity: FileSystemIdentity
        let list: SafeRelativePath
        let previous: SandboxInstallation?
        var desired: SandboxInstallation?
        let oldTree: FileSystemIdentity?
        var newTree: FileSystemIdentity?
        let oldListDigest: String?
        var newListDigest: String?
        func validate() throws {
            guard stage.components.count == 2, stage.components[0] == ".macgacha-staging",
                stage.components[1].hasPrefix("sandbox-"), root.isFileURL,
                desired == nil || desired?.listPath == list, previous == nil || previous?.listPath == list,
                (rolledBack || desired == nil || (newTree != nil && newListDigest != nil)) else {
                throw LauncherError.journalCorrupt("Invalid sandbox journal")
            }
            try SandboxFiles.validateListPath(list)
            for value in [oldListDigest, newListDigest].compactMap({ $0 }) { _ = try Digest(algorithm: .sha256, hex: value) }
        }
    }
}
