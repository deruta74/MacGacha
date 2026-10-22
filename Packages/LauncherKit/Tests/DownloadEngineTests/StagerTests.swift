// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).

import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["missing", "wrong-size", "no-staged-record"])
func committedBatchIsDoneForBudgetProgressAndObjectCleanup(includeCommittedInBatch: Bool, stagedState: String) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("shared", "abc")
    let a = try stagingFile("a", "abc", [stagingChunk("shared", "abc")])
    let b = try stagingFile("b", "abc", [stagingChunk("shared", "abc")])
    let plan = try stagingPlan([object], [a, b]); let journal = try stagingJournal(fs, plan)
    let cdn = MockCDN(); cdn.serve("shared", data: Data("abc".utf8))
    let stager = try stagingEngine(plan, fs, cdn, journal)
    _ = try await collectStaging(stager.stage(files: [a]))
    try fs.rename(from: stagedPath(plan, a.path), to: a.path)
    try await journal.append(.fileCommitted(path: a.path))
    if stagedState == "wrong-size" { try fs.writeAtomically(Data("x".utf8), to: stagedPath(plan, a.path)) }
    // Recovery must also tolerate a committed path whose staged record was invalidated earlier.
    if stagedState == "no-staged-record" { try await journal.append(.fileUnstaged(path: a.path)) }
    let state = try await journal.snapshot()
    let budget = try SpaceBudget.required(plan: plan, state: state, fs: fs)
    #expect(budget.disk == SpaceBudget.margin + 3)
    #expect(budget.network == 0)
    #expect(try SpaceBudget.requiredLargestFile(plan: plan, state: state, fs: fs) == SpaceBudget.margin + 3)
    let before = try fs.readFile(at: journalPath(plan), maxBytes: 16_384)
    let events = try await collectStaging(stager.stage(files: includeCommittedInBatch ? [a, b] : [b]))
    #expect(events == [.progress(downloaded: 3, totalNetwork: 3, staged: 0, totalStaged: 3),
        .fileVerified(b.path), .progress(downloaded: 3, totalNetwork: 3, staged: 3, totalStaged: 3)])
    let after = try fs.readFile(at: journalPath(plan), maxBytes: 16_384)
    let records = try after.dropFirst(before.count).split(separator: 0x0a).map {
        try JSONDecoder().decode(JournalRecord.self, from: Data($0))
    }
    #expect(records == [.fileStaged(path: b.path)])
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
    #expect(try fs.readFile(at: a.path, maxBytes: 3) == Data("abc".utf8))
    #expect(cdn.requestLog.count == 1)
    let doneState = try await journal.snapshot()
    #expect(try SpaceBudget.required(plan: plan, state: doneState, fs: fs).disk == SpaceBudget.margin)
}

@Test(.timeLimit(.minutes(1)))
func matchingLocalRangeWithFallbackNeedsNoNetwork() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let installed = try SafeRelativePath("installed")
    try fs.writeAtomically(Data("xxGOODyy".utf8), to: installed)
    let object = stagingObject("fallback", "GOOD")
    let extent = Extent(source: .local(path: installed, offset: 2), fileOffset: 0, length: 4,
        digest: object.decodedDigest, fallbackChunkID: object.id)
    let file = try stagingFile("new", "GOOD", [extent]); let plan = try stagingPlan([object], [file])
    let journal = try stagingJournal(fs, plan); let cdn = MockCDN()
    let state = try await journal.snapshot()
    let budget = try SpaceBudget.required(plan: plan, state: state, fs: fs)
    #expect(budget.disk == SpaceBudget.margin + 4)
    #expect(budget.network == 0)
    #expect(try SpaceBudget.requiredLargestFile(plan: plan, state: state, fs: fs) == SpaceBudget.margin + 4)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal,
        disk: FixedDiskSpace(bytes: SpaceBudget.margin + 4))
    let events = try await collectStaging(stager.stage(files: [file]))
    #expect(events == [.progress(downloaded: 0, totalNetwork: 0, staged: 0, totalStaged: 4),
        .fileVerified(file.path), .progress(downloaded: 0, totalNetwork: 0, staged: 4, totalStaged: 4)])
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 4) == Data("GOOD".utf8))
}

@Test(.timeLimit(.minutes(1)))
func stagesFilesFromSharedObjectOnce() async throws {
    let temp = try TempDir()
    let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("shared", "abc")
    let prefix = try SafeRelativePath("prefix")
    try fs.writeAtomically(Data("XX".utf8), to: prefix)
    let a = try stagingFile("a", "abc", [stagingChunk("shared", "abc")])
    let b = try stagingFile("b", "XXabc", [Extent(source: .local(path: prefix, offset: 0), fileOffset: 0,
        length: 2, digest: stagingDigest("XX")), stagingChunk("shared", "abc", offset: 2)])
    let plan = try stagingPlan([object], [a, b])
    let cdn = MockCDN(); cdn.serve("shared", data: Data("abc".utf8))
    let journal = try stagingJournal(fs, plan)
    let stager = try stagingEngine(plan, fs, cdn, journal)
    let events = try await collectStaging(stager.stage(files: plan.files))
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: stagedPath(plan, a.path), maxBytes: 10) == Data("abc".utf8))
    #expect(try fs.readFile(at: stagedPath(plan, b.path), maxBytes: 10) == Data("XXabc".utf8))
    #expect(try fs.readFile(at: prefix, maxBytes: 2) == Data("XX".utf8))
    #expect(events.contains(.progress(downloaded: 3, totalNetwork: 3, staged: 8, totalStaged: 8)))
    #expect(try OperationJournal.replay(fs: fs, path: journalPath(plan)).stagedFiles == [a.path, b.path])
    #expect(!(try OperationJournal.replay(fs: fs, path: journalPath(plan)).completed))
}

@Test(.timeLimit(.minutes(1)))
func localExtentReusedWhenDigestMatches() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let installed = try SafeRelativePath("installed")
    try fs.writeAtomically(Data("xxGOODyy".utf8), to: installed)
    let extent = Extent(source: .local(path: installed, offset: 2), fileOffset: 0, length: 4, digest: stagingDigest("GOOD"))
    let file = try stagingFile("new", "GOOD", [extent])
    let plan = try stagingPlan([], [file]); let cdn = MockCDN()
    let journal = try stagingJournal(fs, plan)
    _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 4) == Data("GOOD".utf8))
    #expect(try fs.readFile(at: installed, maxBytes: 8) == Data("xxGOODyy".utf8))
}

@Test(.timeLimit(.minutes(1)))
func localExtentFallsBackToChunkOnMismatch() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let installed = try SafeRelativePath("installed")
    try fs.writeAtomically(Data("xxBAD!yy".utf8), to: installed)
    let object = stagingObject("fallback", "GOOD")
    let extent = Extent(source: .local(path: installed, offset: 2), fileOffset: 0, length: 4,
        digest: object.decodedDigest, fallbackChunkID: object.id)
    let file = try stagingFile("new", "GOOD", [extent]); let plan = try stagingPlan([object], [file])
    let cdn = MockCDN(); cdn.serve("fallback", data: Data("GOOD".utf8))
    let journal = try stagingJournal(fs, plan)
    _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 4) == Data("GOOD".utf8))
    #expect(try fs.readFile(at: installed, maxBytes: 8) == Data("xxBAD!yy".utf8))
}

@Test(.timeLimit(.minutes(1)))
func stagedFileDigestMismatchRetriesOnceThenFails() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let file = try stagingFile("new", "xyz", [stagingChunk("object", "abc")])
    let plan = try stagingPlan([object], [file]); let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8))
    let journal = try stagingJournal(fs, plan)
    await #expect(throws: LauncherError.digestMismatch(path: "new", expected: stagingDigest("xyz").hex, actual: stagingDigest("abc").hex)) {
        _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    }
    let lines = try fs.readFile(at: journalPath(plan), maxBytes: 16_384).split(separator: 0x0a)
    let records = try lines.map { try JSONDecoder().decode(JournalRecord.self, from: Data($0)) }
    #expect(records.filter { $0 == .fileUnstaged(path: file.path) }.count == 2)
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.itemType(at: stagedPath(plan, file.path)) == nil)
    #expect(try fs.size(at: objectPath(plan, object)) == 3)
}

@Test(.timeLimit(.minutes(1)))
func objectPartDeletedOnlyAfterAllReferrersStaged() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let a = try stagingFile("a", "abc", [stagingChunk("object", "abc")])
    let b = try stagingFile("b", "abc", [stagingChunk("object", "abc")])
    let plan = try stagingPlan([object], [a, b]); let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8))
    let journal = try stagingJournal(fs, plan); let stager = try stagingEngine(plan, fs, cdn, journal)
    _ = try await collectStaging(stager.stage(files: [a]))
    #expect(try fs.size(at: objectPath(plan, object)) == 3)
    _ = try await collectStaging(stager.stage(files: [b]))
    #expect(try fs.itemType(at: objectPath(plan, object)) == nil)
    #expect(cdn.requestLog.count == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func staleVerifiedObjectWithMissingPartIsRefetched(wrongSize: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let file = try stagingFile("file", "abc", [stagingChunk("object", "abc")])
    let plan = try stagingPlan([object], [file]); let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8))
    let journal = try stagingJournal(fs, plan)
    try await journal.append(.objectVerified(id: object.id))
    try await journal.append(.fileStaged(path: file.path))
    if wrongSize {
        try fs.writeAtomically(Data("ab".utf8), to: objectPath(plan, object))
        try fs.writeAtomically(Data("x".utf8), to: stagedPath(plan, file.path))
    }
    _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 3) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)))
func symlinkInInstallRootRejected() async throws {
    let temp = try TempDir(); let outside = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let source = try SafeRelativePath("Data/local")
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Data"), withDestinationURL: outside.url)
    try Data("abc".utf8).write(to: outside.url.appendingPathComponent("local"))
    let file = try stagingFile("new", "abc", [Extent(source: .local(path: source, offset: 0), fileOffset: 0,
        length: 3, digest: stagingDigest("abc"))])
    let plan = try stagingPlan([], [file]); let journal = try stagingJournal(fs, plan)
    await #expect(throws: LauncherError.unsafePath(temp.url.appendingPathComponent("Data").path)) {
        _ = try await collectStaging(stagingEngine(plan, fs, MockCDN(), journal).stage(files: plan.files))
    }
    #expect(try Data(contentsOf: outside.url.appendingPathComponent("local")) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)))
func insufficientStagingSpaceFailsBeforeNetwork() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let plan = try stagingPlan([object], [stagingFile("file", "abc", [stagingChunk("object", "abc")])])
    let cdn = MockCDN(); let journal = try stagingJournal(fs, plan)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal, disk: FixedDiskSpace(bytes: 0))
    await #expect(throws: LauncherError.insufficientSpace(required: (1 << 30) + 6, available: 0)) {
        _ = try await collectStaging(stager.stage(files: plan.files))
    }
    #expect(cdn.requestLog.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func decodedObjectMismatchRefetchesAndSupportsSHA256Files() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let reference = stagingObject("object", "abc")
    let object = ChunkObject(id: reference.id, urls: reference.urls, transferSize: 3,
        decodedSize: 3, decodedDigest: reference.decodedDigest)
    var sha = StreamingHasher(.sha256); sha.update(Data("abc".utf8))
    let file = FileTask(path: try SafeRelativePath("new"), size: 3, digest: sha.finalize(), extents: [stagingChunk("object", "abc")])
    let plan = try stagingPlan([object], [file]); let journal = try stagingJournal(fs, plan)
    let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8)); cdn.enqueueFault("object", .corruptByte(at: 0))
    let events = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.count == 2)
    #expect(events.contains(.progress(downloaded: 3, totalNetwork: 3, staged: 3, totalStaged: 3)))
    #expect(try fs.readFile(at: stagedPath(plan, file.path), maxBytes: 3) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)))
func corruptPreviouslyVerifiedPartUpdatesNetworkBudgetWhenRefetched() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let file = try stagingFile("new", "abc", [stagingChunk("object", "abc")])
    let plan = try stagingPlan([object], [file]); let journal = try stagingJournal(fs, plan)
    try await journal.append(.objectVerified(id: object.id))
    try fs.writeAtomically(Data("bad".utf8), to: objectPath(plan, object))
    let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8))
    let events = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.count == 1)
    #expect(events.contains(.progress(downloaded: 3, totalNetwork: 3, staged: 3, totalStaged: 3)))
}

@Test(.timeLimit(.minutes(1)))
func stagingBoundsConcurrentObjectFetches() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let objects = (0..<12).map { stagingObject("object-\($0)", "abc") }
    let extents = objects.enumerated().map { stagingChunk($0.element.id, "abc", offset: Int64($0.offset * 3)) }
    let plan = try stagingPlan(objects, [stagingFile("file", String(repeating: "abc", count: 12), extents)])
    let journal = try stagingJournal(fs, plan); let client = ConcurrentStagingClient(objects: objects)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(client), journal: journal,
        disk: FixedDiskSpace(bytes: Int64.max), maxConcurrentObjects: 3)
    _ = try await collectStaging(stager.stage(files: plan.files))
    #expect(client.peak > 0 && client.peak <= 3)
}

@Test(.timeLimit(.minutes(1)))
func localRangeOutsideInstalledFileFallsBackWithoutReadingPastEOF() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let source = try SafeRelativePath("old")
    try fs.writeAtomically(Data("x".utf8), to: source)
    let object = stagingObject("fallback", "abc")
    let extent = Extent(source: .local(path: source, offset: 10), fileOffset: 0, length: 3,
        digest: object.decodedDigest, fallbackChunkID: object.id)
    let plan = try stagingPlan([object], [stagingFile("new", "abc", [extent])])
    let journal = try stagingJournal(fs, plan); let cdn = MockCDN(); cdn.serve("fallback", data: Data("abc".utf8))
    _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: source, maxBytes: 1) == Data("x".utf8))
    #expect(try fs.readFile(at: stagedPath(plan, plan.files[0].path), maxBytes: 3) == Data("abc".utf8))
}

@Test(.timeLimit(.minutes(1)))
func symlinkInStagingDestinationCannotRedirectWrites() async throws {
    let temp = try TempDir(); let outside = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let object = stagingObject("object", "abc")
    let plan = try stagingPlan([object], [stagingFile("new", "abc", [stagingChunk("object", "abc")])])
    let journal = try stagingJournal(fs, plan)
    let link = temp.url.appendingPathComponent(".macgacha-staging/build/files")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
    let control = outside.url.appendingPathComponent("new")
    try Data("preserved".utf8).write(to: control)
    let cdn = MockCDN(); cdn.serve("object", data: Data("abc".utf8))
    await #expect(throws: LauncherError.unsafePath(link.path)) {
        _ = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: plan.files))
    }
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
}

@Test(.timeLimit(.minutes(1)))
func pausedAndDiscardedStagingStreamKeepsBoundedWorkAndReleasesLease() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let objects = [stagingObject("a", "abc"), stagingObject("b", "def")]
    let files = try [stagingFile("a", "abc", [stagingChunk("a", "abc")]), stagingFile("b", "def", [stagingChunk("b", "def")])]
    let plan = try stagingPlan(objects, files); let journal = try stagingJournal(fs, plan)
    let cdn = MockCDN(); cdn.serve("a", data: Data("abc".utf8)); cdn.serve("b", data: Data("def".utf8))
    let stager = try stagingEngine(plan, fs, cdn, journal)
    let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    try await OperationWork.$observer.withValue({ if $0 == .stagingLeaseReleased { released.continuation.yield(()) } }) {
        do {
            var iterator = stager.stage(files: files).makeAsyncIterator()
            _ = try await iterator.next()
            #expect(cdn.requestLog.isEmpty)
            while let event = try await iterator.next() { if case .fileVerified = event { break } }
            #expect(cdn.requestLog.count <= 2) // Both fit in this bounded window.
            await #expect(throws: LauncherError.busy("staging already in use")) { _ = try await collectStaging(stager.stage(files: files)) }
            withExtendedLifetime(iterator) {}
        }
        var release = released.stream.makeAsyncIterator()
        _ = await release.next() // Discard cancels and joins owned workers.
        _ = try await collectStaging(stager.stage(files: files))
    }
    #expect(cdn.requestLog.count == 2)
}

@Test(.timeLimit(.minutes(1)))
func cancellationKeepsPartsAndStaged() async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let objects = [stagingObject("a", "abc"), stagingObject("b", "abcdef")]
    let files = try [stagingFile("a", "abc", [stagingChunk("a", "abc")]),
        stagingFile("b", "abcdef", [stagingChunk("b", "abcdef")])]
    let plan = try stagingPlan(objects, files); let client = StagingStallClient()
    let journal = try stagingJournal(fs, plan)
    let stager = try stagingEngine(plan, fs, client, journal)
    let clock = ContinuousClock(), started = clock.now, work = EngineWorkCounter()
    let firstStaged = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
        try await OperationWork.$observer.withValue({ work.record($0) }) {
            var events: [OperationEvent] = []
            for try await event in stager.stage(files: files) {
                events.append(event)
                if event == .fileVerified(files[0].path) { firstStaged.continuation.yield(()) }
            }
            return events
        }
    }
    defer { task.cancel() }
    try await client.waitUntilStalled()
    var stagedEvent = firstStaged.stream.makeAsyncIterator()
    _ = await stagedEvent.next()
    print("Stager cancellation reached stalled body after \(started.duration(to: clock.now))")
    #expect(work.snapshot[.referrerIndexBuild] == 1)
    #expect(work.snapshot[.predictionFile] == 2)
    #expect(work.snapshot[.localRangeHash] == nil)
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { _ = try await task.value }
    #expect(client.cancelled)
    #expect(try fs.size(at: objectPath(plan, objects[1])) == 3)
    #expect(try fs.readFile(at: stagedPath(plan, files[0].path), maxBytes: 3) == Data("abc".utf8))
    #expect(try OperationJournal.replay(fs: fs, path: journalPath(plan)).stagedFiles == [files[0].path])
}

func stagingDigest(_ text: String) -> Digest {
    var hasher = StreamingHasher(.md5); hasher.update(Data(text.utf8)); return hasher.finalize()
}
func stagingObject(_ id: String, _ text: String) -> ChunkObject {
    ChunkObject(id: id, urls: [URL(string: "https://cdn.test/" + id)!], transferSize: Int64(text.utf8.count),
        transferDigest: stagingDigest(text), decodedSize: Int64(text.utf8.count), decodedDigest: stagingDigest(text))
}
func stagingChunk(_ id: String, _ text: String, offset: Int64 = 0) -> Extent {
    Extent(source: .chunk(id: id), fileOffset: offset, length: Int64(text.utf8.count), digest: stagingDigest(text))
}
func stagingFile(_ path: String, _ text: String, _ extents: [Extent]) throws -> FileTask {
    FileTask(path: try SafeRelativePath(path), size: Int64(text.utf8.count), digest: stagingDigest(text), extents: extents)
}
func stagingPlan(_ objects: [ChunkObject], _ files: [FileTask]) throws -> InstallPlan {
    InstallPlan(id: try SafeIdentifier("build"), objects: Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) }), files: files)
}
func journalPath(_ plan: InstallPlan) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/journal.jsonl") }
func stagedPath(_ plan: InstallPlan, _ path: SafeRelativePath) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/files/\(path)") }
func objectPath(_ plan: InstallPlan, _ object: ChunkObject) throws -> SafeRelativePath { try SafeRelativePath(".macgacha-staging/\(plan.id)/objects/\(object.partFileName)") }
func stagingJournal(_ fs: ContainedFileSystem, _ plan: InstallPlan) throws -> OperationJournal {
    let path = try journalPath(plan)
    if try fs.itemType(at: path) == nil {
        var bytes = try JSONEncoder().encode(JournalRecord.planStored(planID: plan.id, planDigest: plan.planDigest))
        bytes.append(10)
        try fs.writeAtomically(bytes, to: path)
    }
    return try OperationJournal(fs: fs, path: path)
}
func stagingFetcher(_ http: any HTTPClient) -> ChunkFetcher { ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 2, baseDelay: .zero, maxDelay: .zero), sleeper: InstantSleeper()) }
func stagingEngine(_ plan: InstallPlan, _ fs: ContainedFileSystem, _ http: any HTTPClient, _ journal: OperationJournal) throws -> Stager {
    try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(http), journal: journal, disk: FixedDiskSpace(bytes: Int64.max))
}
func collectStaging(_ stream: AsyncThrowingStream<OperationEvent, any Error>) async throws -> [OperationEvent] {
    var events: [OperationEvent] = []; for try await event in stream { events.append(event) }; return events
}

private final class StagingStallClient: HTTPClient {
    private struct State { var calls = 0; var cancelled = false }
    private let state = Mutex(State())
    private let stalled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func waitUntilStalled() async throws {
        var iterator = stalled.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw LauncherError.cancelled }
    }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if url.lastPathComponent == "a" {
            let cdn = MockCDN(); cdn.serve("a", data: Data("abc".utf8)); return try await cdn.get(url, byteRangeFrom: offset)
        }
        return (HTTPResponseHead(status: 200, contentLength: 6), HTTPBody(next: { [self] in
            let first = state.withLock { value in value.calls += 1; return value.calls == 1 }
            if first { return Data("abc".utf8) }
            stalled.continuation.yield(())
            try await Task.sleep(for: .seconds(60)); return nil
        }, onCancel: { [self] in state.withLock { $0.cancelled = true } }))
    }
}

private final class ConcurrentStagingClient: HTTPClient {
    private let cdn = MockCDN()
    private let counts = Mutex((active: 0, peak: 0))
    var peak: Int { counts.withLock { $0.peak } }
    init(objects: [ChunkObject]) { for object in objects { cdn.serve(object.id, data: Data("abc".utf8)) } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        counts.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
        defer { counts.withLock { $0.active -= 1 } }
        try await Task.sleep(for: .milliseconds(20))
        return try await cdn.get(url, byteRangeFrom: offset)
    }
}
