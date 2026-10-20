// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func spaceBudgetCountsDecodedAndTransfer() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = ChunkObject(id: "shared", urls: [URL(string: "https://cdn.test/shared")!], transferSize: 4,
        decodedSize: 10, decodedDigest: stagingDigest("0123456789"), codec: .zstd)
    let extent = Extent(source: .chunk(id: object.id), fileOffset: 0, length: 10, digest: object.decodedDigest)
    let a = try stagingFile("a", "0123456789", [extent]); let b = try stagingFile("b", "0123456789", [extent])
    let plan = try stagingPlan([object], [a, b]); let journal = try stagingJournal(fs, plan)
    var state = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    let initial = try SpaceBudget.required(plan: plan, state: state, fs: fs)
    #expect(initial.disk == (1 << 30) + 24); #expect(initial.network == 4)
    #expect(try SpaceBudget.requiredLargestFile(plan: plan, state: state, fs: fs) == (1 << 30) + 14)
    try await journal.append(.objectVerified(id: object.id))
    state = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    #expect(try SpaceBudget.required(plan: plan, state: state, fs: fs).network == 4)
    try fs.writeAtomically(Data("part".utf8), to: objectPath(plan, object))
    #expect(try SpaceBudget.required(plan: plan, state: state, fs: fs).network == 0)
    try await journal.append(.fileStaged(path: a.path))
    try fs.writeAtomically(Data("0123456789".utf8), to: stagedPath(plan, a.path))
    state = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    #expect(try SpaceBudget.required(plan: plan, state: state, fs: fs).disk == (1 << 30) + 10)
    try fs.removeFile(at: stagedPath(plan, a.path))
    #expect(try SpaceBudget.required(plan: plan, state: state, fs: fs).disk == (1 << 30) + 20)
}

@Test
func spaceBudgetOverflowThrowsInsteadOfTrapping() throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let path = try SafeRelativePath("huge")
    let old = try SafeRelativePath("old")
    let file = FileTask(path: path, size: Int64.max, digest: stagingDigest("abc"),
        extents: [Extent(source: .local(path: old, offset: 0), fileOffset: 0,
            length: Int64.max, digest: stagingDigest("abc"))])
    let plan = try stagingPlan([], [file])
    #expect(throws: LauncherError.io("Space budget overflow")) { try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs) }
    #expect(throws: LauncherError.io("Space budget overflow")) { try SpaceBudget.requiredLargestFile(plan: plan, state: JournalState(), fs: fs) }
}
