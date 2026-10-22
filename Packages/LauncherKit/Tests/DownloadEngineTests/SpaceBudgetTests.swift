// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "short", "digest"])
func fallbackBudgetVerifiesLocalRangesAndDeduplicatesObjects(failure: String) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let good = try SafeRelativePath("good"); let bad = try SafeRelativePath("bad")
    try fs.writeAtomically(Data("xxGOODyy".utf8), to: good)
    if failure != "missing" {
        try fs.writeAtomically(Data((failure == "short" ? "xxGOO" : "xxBAD!yy").utf8), to: bad)
    }
    let object = stagingObject("shared", "GOOD")
    let files = try [good, bad, bad].enumerated().map { index, path in
        try stagingFile("new-\(index)", "GOOD", [Extent(source: .local(path: path, offset: 2),
            fileOffset: 0, length: 4, digest: object.decodedDigest, fallbackChunkID: object.id)])
    }
    let plan = try stagingPlan([object], files); let journal = try stagingJournal(fs, plan)
    let state = try await journal.snapshot()
    let budget = try SpaceBudget.required(plan: plan, state: state, fs: fs)
    #expect(budget.disk == SpaceBudget.margin + 16)
    #expect(budget.network == 4)
    #expect(try SpaceBudget.requiredLargestFile(plan: plan, state: state, fs: fs) == SpaceBudget.margin + 8)
    let cdn = MockCDN(); cdn.serve("shared", data: Data("GOOD".utf8))
    let events = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: files))
    #expect(cdn.requestLog.count == 1)
    #expect(events.last == .progress(downloaded: 4, totalNetwork: 4, staged: 12, totalStaged: 12))
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
}

@Test(.timeLimit(.minutes(1)))
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
