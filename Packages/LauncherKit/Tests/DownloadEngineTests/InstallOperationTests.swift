// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test
func installsTwoFilesFromZstdObjects() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url); let cdn = MockCDN()
    let a = compressedObject(try zstdVector("good"), id: "a")
    let b = compressedObject(try zstdVector("wrong"), mirrors: ["https://cdn.test/b"], id: "b", byte: 66)
    cdn.serve("object", data: try zstdVector("good")); cdn.serve("b", data: try zstdVector("wrong"))
    let files = try [compressedFile(a, path: "a.bin"), compressedFile(b, path: "nested/b.bin")]
    let plan = try stagingPlan([a, b], files)
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: FixedDiskSpace(bytes: Int64.max))
    let events = try await collectStaging(operation.run())
    #expect(events.filter { $0 == .phase(.completed) }.count == 1)
    #expect(try fs.readFile(at: files[0].path, maxBytes: 4096) == Data(repeating: 65, count: 4096))
    #expect(try fs.readFile(at: files[1].path, maxBytes: 4096) == Data(repeating: 66, count: 4096))
    #expect(cdn.requestLog.count == 2)
}

@Test(arguments: ["fresh", "lock"])
func freshInstall(id: String) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan(id, [("Data/a", "abc"), ("Data/b", "def")]); let cdn = MockCDN()
    opServe(cdn, plan, ["abc", "def"])
    let events = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(events.last == .phase(.completed)); #expect(cdn.requestLog.count == 2)
    #expect(try fs.readFile(at: SafeRelativePath("Data/a"), maxBytes: 3) == Data("abc".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("Data/b"), maxBytes: 3) == Data("def".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.itemType(at: opDirectory(plan)) == nil)
}

@Test(arguments: [false, true])
func orphanedCompletedCleanupIsDiscardedBeforeStartingNewPlan(sameID: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let old = try opPlan("orphan", [("a", "old")]); let next = try opPlan(sameID ? "orphan" : "next", [("a", "new")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, old, commit: true)
    try await journal.append(.fileCommitted(path: old.files[0].path)); try await journal.append(.operationCompleted)
    try InstallStateMarker.clear(fs: fs, matching: old.id)
    // Simulates cancellation during recursive completed-staging cleanup, with retained data.
    let retained = try SafeRelativePath(".macgacha-staging/orphan/files/retained")
    try fs.writeAtomically(Data(repeating: 0x61, count: 2 << 20), to: retained)
    try fs.removeFile(at: opPlanPath(old))
    opServe(cdn, next, ["new"])
    _ = try await opCollect(opEngine(next, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.checkingSpace) {
            #expect(try fs.size(at: retained) == nil)
            if !sameID { #expect(try fs.itemType(at: opDirectory(old)) == nil) }
        }
    })
    #expect(try fs.size(at: retained) == nil)
    if !sameID { #expect(try fs.itemType(at: opDirectory(old)) == nil) }
    #expect(try fs.readFile(at: next.files[0].path, maxBytes: 3) == Data("new".utf8))
    #expect(cdn.requestLog.count == 1)
}

@Test
func updateTouchesNothingBeforeCommit() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("update", [("a", "new"), ("b", "new")]); let cdn = MockCDN()
    cdn.serve("update-0", data: Data("new".utf8))
    try fs.writeAtomically(Data("old-a".utf8), to: SafeRelativePath("a"))
    try fs.writeAtomically(Data("old-b".utf8), to: SafeRelativePath("b"))
    await #expect(throws: LauncherError.http(status: 404, url: plan.objects["update-1"]!.urls[0])) {
        _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    }
    #expect(try fs.readFile(at: SafeRelativePath("a"), maxBytes: 10) == Data("old-a".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("b"), maxBytes: 10) == Data("old-b".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches.isEmpty)
}

@Test
func committedRecoveryRowSkipsAlreadyCommittedFiles() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("skip", [("a", "abc")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, plan, commit: true)
    try await journal.append(.fileCommitted(path: plan.files[0].path))
    try fs.writeAtomically(Data("changed".utf8), to: plan.files[0].path)
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 10) == Data("changed".utf8))
}

@Test
func stagedRecoveryRowRenamesBeforeJournaling() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("staged", [("a", "abc")]); let cdn = MockCDN()
    _ = try await opSeed(fs, plan, commit: true)
    try fs.writeAtomically(Data("abc".utf8), to: opStaged(plan, plan.files[0].path))
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.cleaningUp) {
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).committedFiles == [plan.files[0].path])
            #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("abc".utf8))
        }
    })
    #expect(cdn.requestLog.isEmpty)
}

@Test
func crashBetweenRenameAndJournalRecovers() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("renamed", [("a", "abc")]); let cdn = MockCDN()
    _ = try await opSeed(fs, plan, commit: true)
    try fs.writeAtomically(Data("abc".utf8), to: opStaged(plan, plan.files[0].path))
    try fs.rename(from: opStaged(plan, plan.files[0].path), to: plan.files[0].path)
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.cleaningUp) {
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).committedFiles == [plan.files[0].path])
        }
    })
    #expect(cdn.requestLog.isEmpty)
}

@Test(arguments: ["missing", "wrong-digest", "wrong-size", "unstaged-before-restart", "bad-staged", "unstaged-full-file", "bad-staged-good-destination"])
func stagedMissingDestinationWrongRefetches(scenario: String) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("repair", [("a", "abc")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    let journal = try await opSeed(fs, plan, commit: true)
    if scenario != "missing" {
        let body = scenario == "wrong-size" ? "x" : scenario == "bad-staged-good-destination" ? "abc" : "bad"
        try fs.writeAtomically(Data(body.utf8), to: plan.files[0].path)
    }
    if scenario.hasPrefix("unstaged") { try await journal.append(.fileUnstaged(path: plan.files[0].path)) }
    if scenario.hasPrefix("bad-staged") { try fs.writeAtomically(Data("x".utf8), to: opStaged(plan, plan.files[0].path)) }
    if scenario == "unstaged-full-file" { try fs.writeAtomically(Data("bad".utf8), to: opStaged(plan, plan.files[0].path)) }
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("abc".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test(arguments: [false, true])
func planChangeAfterCommitFinishesOldPlanFirst(sameID: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let old = try opPlan("old", [("a", "old"), ("b", "old-b")])
    let next = try opPlan(sameID ? "old" : "next", [("a", "new")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, old, commit: true)
    try await journal.append(.fileCommitted(path: old.files[0].path))
    try fs.writeAtomically(Data("old".utf8), to: old.files[0].path)
    opServe(cdn, old, ["old", "old-b"]); opServe(cdn, next, ["new"])
    _ = try await opCollect(opEngine(next, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.checkingSpace), try fs.itemType(at: opPlanPath(next)) != nil {
            let stored = try JSONDecoder().decode(InstallPlan.self, from: fs.readFile(at: opPlanPath(next), maxBytes: 65_536))
            if stored.planDigest == next.planDigest {
                #expect(try fs.readFile(at: old.files[1].path, maxBytes: 5) == Data("old-b".utf8))
                if !sameID { #expect(try fs.itemType(at: opDirectory(old)) == nil) }
            }
        }
    })
    #expect(cdn.requestLog.map(\.path) == ["old-1", "\(next.id)-0"])
    #expect(try fs.readFile(at: next.files[0].path, maxBytes: 3) == Data("new".utf8))
}

@Test(arguments: [false, true])
func planChangeBeforeCommitDiscardsStaging(sameID: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let old = try opPlan("old", [("a", "old")]); let next = try opPlan(sameID ? "old" : "next", [("a", "new")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, old, commit: false)
    if sameID {
        try await journal.append(.batchStarted(index: 0))
        try InstallStateMarker(planID: old.id).write(fs: fs)
    }
    try fs.writeAtomically(Data("old".utf8), to: opStaged(old, old.files[0].path))
    opServe(cdn, next, ["new"])
    _ = try await opCollect(opEngine(next, temp.url, cdn).run())
    #expect(cdn.requestLog.map(\.path) == ["\(next.id)-0"])
    #expect(try fs.itemType(at: opDirectory(old)) == nil)
    #expect(try fs.readFile(at: next.files[0].path, maxBytes: 3) == Data("new".utf8))
}

@Test(arguments: [false, true])
func batchedModeRequiresApproval(denied: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("batch", [("a", "abc"), ("b", "def")]); let cdn = MockCDN()
    let available: Int64 = (1 << 30) + 6; var events: [OperationEvent] = []
    let operation = try opEngine(plan, temp.url, cdn, bytes: available, mode: denied ? .batched(approved: false) : .automatic)
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 12, available: available)) {
        _ = try await opCollect(operation.run(), onEvent: { events.append($0) })
    }
    #expect(events.contains(.needsBatchApproval(required: (1 << 30) + 12, available: available)))
    #expect(cdn.requestLog.isEmpty); #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test
func batchedModeCommitsInBatchesAndBlocksViaMarker() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("batch", [("a", "abc"), ("b", "def")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc", "def"])
    var sawIntermediate = false
    let operation = try opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true))
    let events = try await opCollect(operation.run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.checkingSpace), try InstallStateMarker.load(fs: fs) != nil,
           try fs.size(at: plan.files[0].path) == 3, try fs.size(at: plan.files[1].path) == nil {
            sawIntermediate = true
            #expect(throws: LauncherError.busy("install is updating")) { try InstallStateMarker.requireIdle(fs: fs) }
        }
        if event == .phase(.cleaningUp) {
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches == [0, 1])
        }
    })
    #expect(sawIntermediate); #expect(events.last == .phase(.completed))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test(arguments: ["regular", "missing", "directory", "symlink"])
func deletionsOnlyRegularFiles(kind: String) async throws {
    let temp = try TempDir(); let outside = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let target = try SafeRelativePath("old")
    let plan = InstallPlan(id: try SafeIdentifier("delete"), objects: [:], files: [], deletions: [target])
    let control = outside.url.appendingPathComponent("control"); try Data("preserved".utf8).write(to: control)
    if kind == "regular" { try fs.writeAtomically(Data("old".utf8), to: target) }
    if kind == "directory" { try fs.createDirectory(at: target) }
    if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target.resolved(against: temp.url), withDestinationURL: control) }
    if kind == "directory" || kind == "symlink" {
        let rejectedPath = kind == "directory" ? target.description : target.resolved(against: temp.url).path
        await #expect(throws: LauncherError.unsafePath(rejectedPath)) {
            _ = try await opCollect(opEngine(plan, temp.url, MockCDN()).run())
        }
    } else {
        _ = try await opCollect(opEngine(plan, temp.url, MockCDN()).run(), onEvent: { (event: OperationEvent) throws in
            if event == .phase(.cleaningUp) { #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).deletedFiles == [target]) }
        })
        #expect(try fs.itemType(at: target) == nil)
    }
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
}

@Test
func batchedModePreservesLocalSourcesNeededByLaterFilesWithoutFallback() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let a = try opPlan("dependency", [("a", "new")])
    let b = FileTask(path: try SafeRelativePath("b"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: a.files[0].path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old")),
    ])
    let plan = InstallPlan(id: a.id, objects: a.objects, files: a.files + [b])
    try fs.writeAtomically(Data("old".utf8), to: a.files[0].path)
    let cdn = MockCDN(); opServe(cdn, a, ["new"])
    let operation = try opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true))
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 9, available: (1 << 30) + 6)) {
        _ = try await opCollect(operation.run())
    }
    #expect(try fs.readFile(at: a.files[0].path, maxBytes: 3) == Data("old".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(cdn.requestLog.isEmpty)
}

@Test(arguments: [false, true], [false, true])
func batchedModeUsesFallbackForOverwrittenLocalSource(resume: Bool, batched: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let a = try opPlan("fallback", [("a", "new")])
    let fallback = ChunkObject(id: "fallback-old", urls: [URL(string: "https://cdn.test/fallback-old")!],
        transferSize: 3, transferDigest: opDigest("old"), decodedSize: 3, decodedDigest: opDigest("old"))
    var objects = a.objects; objects[fallback.id] = fallback
    let b = FileTask(path: try SafeRelativePath("b"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: a.files[0].path, offset: 0), fileOffset: 0, length: 3,
            digest: opDigest("old"), fallbackChunkID: fallback.id),
    ])
    let plan = InstallPlan(id: a.id, objects: objects, files: a.files + [b])
    try fs.writeAtomically(Data("old".utf8), to: a.files[0].path)
    let cdn = MockCDN(); opServe(cdn, a, ["new"]); cdn.serve(fallback.id, data: Data("old".utf8))
    let bytes = batched ? (1 << 30) + 6 : Int64.max
    var events: [OperationEvent] = []
    for try await event in try opEngine(plan, temp.url, cdn, bytes: bytes, mode: .batched(approved: true)).run() {
        events.append(event)
        if resume, event == .phase(.checkingSpace), try OperationJournal.replay(fs: fs, path: opJournal(plan)).committedFiles.contains(a.files[0].path) { break }
    }
    if resume {
        let resumed = try await opCollect(opEngine(plan, temp.url, cdn, bytes: bytes, mode: .batched(approved: true)).run())
        if batched {
            let initial = resumed.first { if case .progress = $0 { true } else { false } }
            #expect(initial == .progress(downloaded: 3, totalNetwork: 6, staged: 0, totalStaged: 3))
        }
        events.append(contentsOf: resumed)
    }
    let progress = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let done, let total, _, _) = event { return (done, total) }; return nil
    }
    #expect(!progress.isEmpty && progress.allSatisfy { $0.0 <= $0.1 })
    #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    #expect(progress.last?.0 == progress.last?.1)
    #expect(try fs.readFile(at: b.path, maxBytes: 3) == Data("old".utf8))
    #expect(cdn.requestLog.map(\.path) == (batched ? ["fallback-0", "fallback-old"] : ["fallback-0"]))
}

@Test
func sharedObjectIsNotDownloadedAgainAcrossCommittedBatches() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try retainedSpacePlan(); let cdn = MockCDN(); serveRetainedSpacePlan(cdn, plan)
    var batches = 0
    _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 13, mode: .batched(approved: true)).run(),
        onEvent: { event in if event == .phase(.committing) { batches += 1 } })
    #expect(batches == 4)
    #expect(cdn.requestLog.count == 3)
    #expect(try fs.readFile(at: plan.files[2].path, maxBytes: 3) == Data("abc".utf8))
}

@Test
func completedJournalOnlyNeedsCleanup() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("completed", [("a", "abc")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, plan, commit: true)
    try fs.writeAtomically(Data("abc".utf8), to: plan.files[0].path)
    try await journal.append(.fileCommitted(path: plan.files[0].path))
    try await journal.append(.operationCompleted)
    let events = try await opCollect(opEngine(plan, temp.url, cdn, bytes: 0).run())
    #expect(cdn.requestLog.isEmpty); #expect(events.last == .phase(.completed))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test
func preCommitMissingStagedFileIsRefetchedBeforeChangingInstalledFiles() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("precommit", [("a", "abc")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    _ = try await opSeed(fs, plan, commit: false)
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    var verified = false
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .fileVerified(plan.files[0].path) {
            verified = true
            #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("old".utf8))
            #expect(try InstallStateMarker.load(fs: fs) == nil)
        }
    })
    #expect(verified && cdn.requestLog.count == 1)
}

@Test
func crashAfterBatchStartedReusesTheUncommittedBatchIndex() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("batch-gap", [("a", "abc")]); let cdn = MockCDN()
    let journal = try await opSeed(fs, plan, commit: false)
    try fs.writeAtomically(Data("abc".utf8), to: opStaged(plan, plan.files[0].path))
    try await journal.append(.batchStarted(index: 0))
    try InstallStateMarker(planID: plan.id).write(fs: fs)
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.cleaningUp) {
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches == [0])
        }
    })
    #expect(cdn.requestLog.isEmpty)
}

@Test
func markerRemovedOnlyAfterCompleted() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("marker", [("a", "abc")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    var checked = false
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.cleaningUp) {
            checked = true
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).completed)
            #expect(try InstallStateMarker.load(fs: fs)?.planID == plan.id)
        }
        if event == .phase(.completed) { #expect(try InstallStateMarker.load(fs: fs) == nil) }
    })
    #expect(checked)
}

@Test
func uppercaseDigestInPlanAccepted() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let original = try opPlan("uppercase", [("a", "abc")])
    let encoder = JSONEncoder(); let text = String(decoding: try encoder.encode(original), as: UTF8.self)
        .replacingOccurrences(of: opDigest("abc").hex, with: opDigest("abc").hex.uppercased())
    let plan = try JSONDecoder().decode(InstallPlan.self, from: Data(text.utf8))
    let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("abc".utf8))
}

@Test
func unicodeAndSpacesInPaths() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("unicode", [("Data with spaces/日本語 é.bin", "hello")]); let cdn = MockCDN(); opServe(cdn, plan, ["hello"])
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 5) == Data("hello".utf8))
}

@Test
func cancellationAfterCommitStartedKeepsMarkerAndResumesWithoutDownload() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("cancel", [("a", "abc")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    let operation = try opEngine(plan, temp.url, cdn)
    let task = Task {
        var completed = false
        do {
            for try await event in operation.run() {
                if event == .phase(.committing) { withUnsafeCurrentTask { $0?.cancel() } }
                if event == .phase(.completed) { completed = true }
            }
        } catch LauncherError.cancelled {
            // Cancellation during an active pull throws; between pulls AsyncThrowingStream may end.
        }
        return (cancelled: Task.isCancelled, completed: completed)
    }
    let outcome = try await task.value
    #expect(outcome.cancelled && !outcome.completed)
    #expect(!(try OperationJournal.replay(fs: fs, path: opJournal(plan)).completed))
    #expect(try InstallStateMarker.load(fs: fs)?.planID == plan.id)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("old".utf8))
    _ = try await opCollect(opEngine(plan, temp.url, cdn).run())
    #expect(cdn.requestLog.count == 1)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test
func concurrentInstallOperationsShareTheRootLockAndReleaseOnDiscard() async throws {
    let temp = try TempDir(); let plan = try opPlan("concurrent", [("a", "abc")]); let cdn = MockCDN(); opServe(cdn, plan, ["abc"])
    let operation = try opEngine(plan, temp.url, cdn)
    do {
        var iterator = operation.run().makeAsyncIterator()
        #expect(try await iterator.next() == .phase(.checkingSpace))
        await #expect(throws: LauncherError.busy("install root in use")) { _ = try await opCollect(operation.run()) }
        withExtendedLifetime(iterator) {}
    }
    _ = try await opCollect(operation.run())
    #expect(cdn.requestLog.count == 1)
}

@Test
func laterBatchLocalDependencyIsRejectedBeforeAnyCommit() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let remote = try opPlan("late-dependency", [("independent", "one"), ("source", "new")])
    let local = FileTask(path: try SafeRelativePath("consumer"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: remote.files[1].path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old")),
    ])
    let plan = InstallPlan(id: remote.id, objects: remote.objects, files: remote.files + [local])
    try fs.writeAtomically(Data("untouched".utf8), to: remote.files[0].path)
    try fs.writeAtomically(Data("old".utf8), to: remote.files[1].path)
    try fs.writeAtomically(Data("consumer-old".utf8), to: local.path)
    let cdn = MockCDN(); opServe(cdn, remote, ["one", "new"])
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 15, available: (1 << 30) + 6)) {
        _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true)).run())
    }
    #expect(try fs.readFile(at: remote.files[0].path, maxBytes: 20) == Data("untouched".utf8))
    #expect(try fs.readFile(at: remote.files[1].path, maxBytes: 20) == Data("old".utf8))
    #expect(try fs.readFile(at: local.path, maxBytes: 20) == Data("consumer-old".utf8))
    #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches.isEmpty)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(cdn.requestLog.isEmpty)
}

@Test(arguments: [false, true])
func stagedFilesCostNothingAndBatchMembershipSurvivesRestart(restart: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let large = String(repeating: "large", count: 4_000)
    let plan = try opPlan("staged-batches", [("large-first", large), ("small-a", "abc"), ("small-b", "def"), ("large-last", large)])
    let journal = try await opSeed(fs, plan, commit: false)
    for index in [1, 2] { try await journal.append(.fileUnstaged(path: plan.files[index].path)) }
    for index in [0, 3] {
        try fs.writeAtomically(Data(large.utf8), to: opStaged(plan, plan.files[index].path))
        let object = try #require(plan.objects["staged-batches-\(index)"])
        try await journal.append(.objectVerified(id: object.id))
        try fs.writeAtomically(Data(large.utf8), to: SafeRelativePath(".macgacha-staging/\(plan.id)/objects/\(object.partFileName)"))
        try fs.removeFile(at: SafeRelativePath(".macgacha-staging/\(plan.id)/objects/\(object.partFileName)"))
    }
    let first: Set<SafeRelativePath> = [plan.files[0].path, plan.files[1].path, plan.files[3].path]
    let cdn = MockCDN(); cdn.serve("staged-batches-1", data: Data("abc".utf8)); cdn.serve("staged-batches-2", data: Data("def".utf8))
    let operation = try opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true))
    if restart {
        do {
            var iterator = operation.run().makeAsyncIterator()
            var reachedCommit = false
            while let event = try await iterator.next() {
                if event == .phase(.committing) { reachedCommit = true; break }
            }
            #expect(reachedCommit)
            #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).batchFiles == first)
            withExtendedLifetime(iterator) {}
        }
    }
    var batches: [Set<SafeRelativePath>] = []
    _ = try await opCollect(operation.run(), onEvent: { (event: OperationEvent) throws in
        if event == .phase(.committing) {
            let replay = try OperationJournal.replay(fs: fs, path: opJournal(plan))
            #expect(replay.batchFiles == replay.stagedFiles.subtracting(replay.committedFiles))
            batches.append(replay.batchFiles)
        }
    })
    #expect(batches == [first, [plan.files[2].path]])
    #expect(cdn.requestLog.map(\.path) == ["staged-batches-1", "staged-batches-2"])
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 20_000) == Data(large.utf8))
    #expect(try fs.readFile(at: plan.files[3].path, maxBytes: 20_000) == Data(large.utf8))
    #expect(try fs.readFile(at: plan.files[1].path, maxBytes: 3) == Data("abc".utf8))
    #expect(try fs.readFile(at: plan.files[2].path, maxBytes: 3) == Data("def".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
}

@Test
func batchMembershipMismatchThrowsBeforeCommitStarts() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("membership", [("a", "abc"), ("b", "def")])
    let cdn = MockCDN(); opServe(cdn, plan, ["abc", "def"])
    try fs.writeAtomically(Data("old".utf8), to: plan.files[0].path)
    let operation = try opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true))
    await #expect(throws: LauncherError.journalCorrupt("Staged batch membership mismatch")) {
        for try await event in operation.run() {
            if event == .fileVerified(plan.files[0].path) {
                // Simulate a programming mistake: a writer records a file outside the selected batch.
                let journal = try OperationJournal(fs: fs, path: opJournal(plan))
                try await journal.append(.fileStaged(path: plan.files[1].path))
            }
        }
    }
    #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches.isEmpty)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("old".utf8))
}

@Test
func conservativePartitionRejectsUnsafeSharedLocalBoundary() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let first = try opPlan("partition-shared", [("independent", "new")])
    let source = FileTask(path: try SafeRelativePath("source"), size: 3,
        digest: first.files[0].digest, extents: first.files[0].extents)
    let consumer = FileTask(path: try SafeRelativePath("consumer"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: source.path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old")),
    ])
    let plan = InstallPlan(id: first.id, objects: first.objects, files: first.files + [source, consumer])
    try fs.writeAtomically(Data("old".utf8), to: source.path)
    let cdn = MockCDN(); opServe(cdn, first, ["new"])
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 12, available: (1 << 30) + 6)) {
        _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true)).run())
    }
    #expect(try fs.readFile(at: source.path, maxBytes: 3) == Data("old".utf8))
    #expect(try fs.size(at: consumer.path) == nil)
    #expect(cdn.requestLog.isEmpty)
}

@Test
func sharedBatchPartsRequireConservativeSpaceReserveBeforeCommit() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try retainedSpacePlan(); let cdn = MockCDN(); serveRetainedSpacePlan(cdn, plan)
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 13, available: (1 << 30) + 12)) {
        _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 12, mode: .batched(approved: true)).run())
    }
    #expect(cdn.requestLog.isEmpty)
    #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).commitStartedBatches.isEmpty)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.size(at: plan.files[0].path) == nil)
}

@Test
func retainedPartsAndInstalledGrowthCauseResumableExactShortfall() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try retainedSpacePlan(); let cdn = MockCDN(); serveRetainedSpacePlan(cdn, plan)
    let operation = try InstallOperation(plan: plan, installRoot: temp.url,
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        disk: RetainedPartsDisk(plan: plan), mode: .batched(approved: true))
    var stagingEvents = 0
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 10, available: (1 << 30) + 7)) {
        _ = try await opCollect(operation.run(), onEvent: { event in
            if event == .phase(.staging) { stagingEvents += 1 }
        })
    }
    #expect(stagingEvents == 1)
    let state = try OperationJournal.replay(fs: fs, path: opJournal(plan))
    #expect(state.committedFiles == [plan.files[0].path])
    #expect(!state.completed)
    #expect(try InstallStateMarker.load(fs: fs)?.planID == plan.id)
    #expect(throws: LauncherError.busy("install is updating")) { try InstallStateMarker.requireIdle(fs: fs) }
    #expect(cdn.requestLog.map(\.path) == ["retained-0"])
    #expect(try fs.size(at: plan.files[1].path) == nil)
    _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 40, mode: .batched(approved: true)).run())
    for (file, body) in zip(plan.files, ["abc", "12345", "abc", "67890"]) {
        #expect(try fs.readFile(at: file.path, maxBytes: 5) == Data(body.utf8))
    }
    #expect(cdn.requestLog.count == 3)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.itemType(at: opDirectory(plan)) == nil)
}

@Test(arguments: [false, true])
func staleStagedRecordsAreInvalidatedBeforePartitioning(wrongSize: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("stale-before-partition", [("a", "abc"), ("b", "def")])
    let journal = try await opSeed(fs, plan, commit: false)
    try await journal.append(.fileUnstaged(path: plan.files[0].path))
    if wrongSize { try fs.writeAtomically(Data("x".utf8), to: opStaged(plan, plan.files[1].path)) }
    let cdn = MockCDN(); opServe(cdn, plan, ["abc", "def"])
    var checked = false
    _ = try await opCollect(opEngine(plan, temp.url, cdn, bytes: (1 << 30) + 6, mode: .batched(approved: true)).run(),
        onEvent: { (event: OperationEvent) throws in
            if event == .phase(.staging), !checked {
                checked = true
                #expect(try OperationJournal.replay(fs: fs, path: opJournal(plan)).stagedFiles.isEmpty)
            }
        })
    #expect(checked)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 3) == Data("abc".utf8))
    #expect(try fs.readFile(at: plan.files[1].path, maxBytes: 3) == Data("def".utf8))
}

@Test
func interruptedCleanupRetiresPlanBeforeJournalCanDisappear() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let remote = try opPlan("cleanup-local", [("source", "new")])
    let copied = FileTask(path: try SafeRelativePath("copied"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: remote.files[0].path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old")),
    ])
    let plan = InstallPlan(id: remote.id, objects: remote.objects, files: remote.files + [copied])
    try fs.writeAtomically(Data("old".utf8), to: remote.files[0].path)
    let cdn = MockCDN(); opServe(cdn, remote, ["new"])
    var fixtureDirectory: Int32 = -1
    var fixtureFiles = 0
    defer {
        if fixtureDirectory >= 0 {
            for index in 0..<fixtureFiles { _ = Darwin.unlinkat(fixtureDirectory, "retained-\(index)", 0) }
            Darwin.close(fixtureDirectory)
        }
    }
    await #expect(throws: LauncherError.io("Directory entry limit exceeded")) {
        for try await event in try opEngine(plan, temp.url, cdn).run() {
            if event == .phase(.cleaningUp) {
                // Exceed the bounded directory snapshot so cleanup fails before unlinking
                // any child, independently of readdir order. Empty files avoid large data.
                fixtureDirectory = Darwin.open(try opDirectory(plan).resolved(against: temp.url).path, O_RDONLY | O_DIRECTORY)
                try #require(fixtureDirectory >= 0)
                for index in 0..<100_001 {
                    let fd = Darwin.openat(fixtureDirectory, "retained-\(index)", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    try #require(fd >= 0); Darwin.close(fd); fixtureFiles += 1
                }
            }
        }
    }
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.itemType(at: opPlanPath(plan)) == nil)
    // Simulate a crash after recursive cleanup has removed the journal too.
    try fs.removeFile(at: opJournal(plan))
    for index in 0..<fixtureFiles { #expect(Darwin.unlinkat(fixtureDirectory, "retained-\(index)", 0) == 0) }
    fixtureFiles = 0
    let next = InstallPlan(id: try SafeIdentifier("after-cleanup"), objects: [:], files: [])
    _ = try await opCollect(opEngine(next, temp.url, cdn).run())
    #expect(try fs.itemType(at: opDirectory(plan)) == nil)
    #expect(try fs.readFile(at: remote.files[0].path, maxBytes: 3) == Data("new".utf8))
    #expect(try fs.readFile(at: copied.path, maxBytes: 3) == Data("old".utf8))
    #expect(cdn.requestLog.count == 1)
}

func retainedSpacePlan() throws -> InstallPlan {
    let base = try opPlan("retained", [("a", "abc"), ("b", "12345"), ("d", "67890")])
    let shared = FileTask(path: try SafeRelativePath("c"), size: 3, digest: base.files[0].digest, extents: base.files[0].extents)
    return InstallPlan(id: base.id, objects: base.objects, files: [base.files[0], base.files[1], shared, base.files[2]])
}
func serveRetainedSpacePlan(_ cdn: MockCDN, _ plan: InstallPlan) { opServe(cdn, plan, ["abc", "12345", "67890"]) }
struct RetainedPartsDisk: DiskSpaceProbe {
    let plan: InstallPlan
    func availableBytes(at url: URL) throws -> Int64 {
        let fs = try ContainedFileSystem(root: url)
        let object = plan.objects["retained-0"]!
        let retained = try fs.size(at: SafeRelativePath(".macgacha-staging/\(plan.id)/objects/\(object.partFileName)")) ?? 0
        let state = try OperationJournal.replay(fs: fs, path: opJournal(plan))
        let installed = try state.committedFiles.contains(plan.files[0].path) ? fs.size(at: plan.files[0].path) ?? 0 : 0
        return (1 << 30) + 13 - retained - installed
    }
}

func opDigest(_ text: String) -> Digest { var h = StreamingHasher(.md5); h.update(Data(text.utf8)); return h.finalize() }
func opPlan(_ id: String, _ entries: [(String, String)]) throws -> InstallPlan {
    var objects: [String: ChunkObject] = [:]; var files: [FileTask] = []
    for (i, entry) in entries.enumerated() {
        let objectID = "\(id)-\(i)"; let size = Int64(entry.1.utf8.count); let digest = opDigest(entry.1)
        objects[objectID] = ChunkObject(id: objectID, urls: [URL(string: "https://cdn.test/\(objectID)")!],
            transferSize: size, transferDigest: digest, decodedSize: size, decodedDigest: digest)
        files.append(FileTask(path: try SafeRelativePath(entry.0), size: size, digest: digest,
            extents: [Extent(source: .chunk(id: objectID), fileOffset: 0, length: size, digest: digest)]))
    }
    return InstallPlan(id: try SafeIdentifier(id), objects: objects, files: files)
}
func opServe(_ cdn: MockCDN, _ plan: InstallPlan, _ bodies: [String]) {
    for (i, body) in bodies.enumerated() { cdn.serve("\(plan.id)-\(i)", data: Data(body.utf8)) }
}
func opDirectory(_ plan: InstallPlan) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)") }
func opPlanPath(_ plan: InstallPlan) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/plan.json") }
func opJournal(_ plan: InstallPlan) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/journal.jsonl") }
func opStaged(_ plan: InstallPlan, _ file: SafeRelativePath) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/files/\(file)") }
func opSeed(_ fs: ContainedFileSystem, _ plan: InstallPlan, commit: Bool) async throws -> OperationJournal {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try fs.writeAtomically(encoder.encode(plan), to: opPlanPath(plan))
    let journal = try OperationJournal(fs: fs, path: opJournal(plan))
    try await journal.append(.planStored(planID: plan.id, planDigest: plan.planDigest))
    try await journal.append(.operationStarted)
    for file in plan.files { try await journal.append(.fileStaged(path: file.path)) }
    if commit {
        try await journal.append(.batchStarted(index: 0))
        try InstallStateMarker(planID: plan.id).write(fs: fs)
        try await journal.append(.commitStarted(batch: 0))
    }
    return journal
}
func opEngine(_ plan: InstallPlan, _ root: URL, _ http: any HTTPClient, bytes: Int64 = Int64.max,
    mode: InstallOperation.Mode = .automatic) throws -> InstallOperation {
    try InstallOperation(plan: plan, installRoot: root,
        fetcher: ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        disk: FixedDiskSpace(bytes: bytes), mode: mode)
}
func opCollect(_ stream: AsyncThrowingStream<OperationEvent, any Error>, onEvent: (OperationEvent) throws -> Void = { _ in }) async throws -> [OperationEvent] {
    var events: [OperationEvent] = []
    for try await event in stream { try onEvent(event); events.append(event) }
    return events
}

@Test
func constructingZstdInstallDoesNotRequestOrWrite() throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let object = compressedObject(try zstdVector("good"))
    let file = try compressedFile(object)
    let plan = try stagingPlan([object], [file])
    _ = try opEngine(plan, temp.url, cdn)
    #expect(cdn.requestLog.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
}

@Test(arguments: [Int64(29), 30, 32])
func minimumPartitionSurvivesNonMonotonicGreedyBudget(extra: Int64) async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    var objects: [String: ChunkObject] = [:]
    for (id, body) in [("shared", "aa"), ("other", "bb")] {
        let bytes = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0, 2, 0, 0, 0, 0x11, 0, 0]) + Data(body.utf8)
        objects[id] = ChunkObject(id: id, urls: [URL(string: "https://cdn.hoyoverse.com/\(id)")!],
            transferSize: 14, decodedSize: 2, decodedDigest: opDigest(body), codec: .zstd)
        cdn.serve(id, data: bytes)
    }
    let files = try [("a", "shared", "aa"), ("b", "other", "bb"), ("c", "shared", "aa")].map { name, id, body in
        FileTask(path: try SafeRelativePath(name), size: 2, digest: opDigest(body), extents: [
            Extent(source: .chunk(id: id), fileOffset: 0, length: 2, digest: opDigest(body)),
        ])
    }
    let plan = InstallPlan(id: try SafeIdentifier("nonmonotonic"), objects: objects, files: files)
    let operation = try opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + extra, mode: .batched(approved: true))
    if extra == 29 {
        await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + 30, available: SpaceBudget.margin + 29)) {
            _ = try await opCollect(operation.run())
        }
        #expect(cdn.requestLog.isEmpty)
    } else {
        let events = try await opCollect(operation.run())
        #expect(events.last == .phase(.completed))
        for file in files { #expect(try ContainedFileSystem(root: temp.url).size(at: file.path) == 2) }
    }
}

@Test(arguments: [Int64(20), 36])
func minimumPartitionHandlesGreedyDependencyFailure(extra: Int64) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let base = try opPlan("dependency-fallback", [("a", "aaaaaaaaaa"), ("b", "bbbbbbbb")])
    let c = FileTask(path: try SafeRelativePath("c"), size: 2, digest: opDigest("xx"), extents: [
        Extent(source: .local(path: base.files[1].path, offset: 0), fileOffset: 0, length: 2, digest: opDigest("xx")),
    ])
    let plan = InstallPlan(id: base.id, objects: base.objects, files: base.files + [c])
    try fs.writeAtomically(Data("xx......".utf8), to: base.files[1].path)
    let cdn = MockCDN(); opServe(cdn, base, ["aaaaaaaaaa", "bbbbbbbb"])
    let events = try await opCollect(opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + extra, mode: .batched(approved: true)).run())
    #expect(events.last == .phase(.completed))
    #expect(try fs.readFile(at: base.files[0].path, maxBytes: 100) == Data("aaaaaaaaaa".utf8))
    #expect(try fs.readFile(at: base.files[1].path, maxBytes: 100) == Data("bbbbbbbb".utf8))
    #expect(try fs.readFile(at: c.path, maxBytes: 100) == Data("xx".utf8))
}
