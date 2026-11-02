// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine

/// Caller owns the operation lease and drained game exclusion for every mutation.
struct PreDownloadStore: Sendable {
    static let maximumBytes = 64 << 20
    static let directory = try! SafeRelativePath(".macgacha-predownload")
    static let statePath = try! SafeRelativePath(".macgacha-predownload/state.json")
    private static let deleting = try! SafeRelativePath(".macgacha-predownload/deleting")
    private static let objects = try! SafeRelativePath(".macgacha-predownload/objects")
    let fs: ContainedFileSystem
    init(fs: ContainedFileSystem) throws { self.fs = try fs.pinRoot() }
    func part(_ object: ChunkObject) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-predownload/objects/\(object.partFileName)") }

    func load() throws -> PreDownloadState? {
        if try fs.size(at: Self.deleting) != nil { return nil }
        guard try fs.itemType(at: Self.statePath) != nil else { return nil }
        let state: PreDownloadState
        do { state = try JSONDecoder().decode(PreDownloadState.self, from: fs.readFile(at: Self.statePath, maxBytes: Self.maximumBytes)) }
        catch { throw LauncherError.journalCorrupt("invalid pre-download state") }
        try state.validate()
        guard state.plan.installation == (try fs.rootIdentity()) else { throw LauncherError.journalCorrupt("pre-download installation changed") }
        return state
    }
    func save(_ state: PreDownloadState) throws {
        try state.validate()
        guard state.plan.installation == (try fs.rootIdentity()) else { throw LauncherError.journalCorrupt("pre-download installation changed") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else { throw LauncherError.io("pre-download state size limit") }
        try fs.createDirectoryDurably(at: Self.objects)
        try fs.writeAtomically(data, to: Self.statePath)
    }
    @discardableResult func replace(_ plan: PreDownloadPlan) throws -> PreDownloadState {
        if try fs.size(at: Self.deleting) != nil { try remove() }
        let old = try load()
        var state = try PreDownloadState(plan: plan)
        if let old, old.plan.edition == plan.edition, old.plan.sourceTag == plan.sourceTag, old.plan.targetTag == plan.targetTag {
            state.verified = Set(old.verified.filter { id in
                guard let a = old.plan.containers[id]?.object, let b = plan.containers[id]?.object else { return false }
                return a.transferSize == b.transferSize && a.decodedDigest == b.decodedDigest
            })
            state.completed = old.completed && state.verified == Set(plan.containers.keys)
        }
        // Publication precedes pruning: a crash leaves harmless extra parts,
        // never a resumable plan whose required parts were removed first.
        try save(state)
        let keep = try Set(plan.containers.values.map { try part($0.object) })
        for path in try fs.contentsOfDirectory(at: Self.objects) where !keep.contains(path) { try fs.removeItem(at: path) }
        return state
    }
    func remove() throws {
        guard try fs.itemType(at: Self.directory) != nil else { return }
        try fs.writeAtomically(Data([1]), to: Self.deleting)
        try fs.removeItem(at: Self.directory)
        try fs.synchronizeParentDirectory(of: Self.directory)
    }
    func finishDeletion() throws {
        if try fs.size(at: Self.deleting) != nil { try remove() }
    }
}
