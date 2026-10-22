// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Test func unsharedPartsBudgetUsesPeakInsteadOfWholeDownload() throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
    let plan = try opPlan("unshared-peak", (0..<24).map { ("file-\($0)", String(repeating: "x", count: 1024)) })
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs)
    #expect(budget.network == 24 * 1024)
    #expect(budget.disk == SpaceBudget.margin + 24 * 1024 + 24 * 1024)
    #expect(try SpaceBudget.requiredLargestFile(plan: plan, state: JournalState(), fs: fs) == SpaceBudget.margin + 2048)
}

@Test(arguments: ["bytes", "objects", "wide"]) func configuredWindowFitsEnforcedCapacityWith32Transfers(bound: String) async throws {
    let temp = try TempDir(), initial = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "W", count: 4096)
    let plan = try opPlan("bounded-window", (0..<40).map { ("out\($0)", body) })
    opServe(cdn, plan, Array(repeating: body, count: 40))
    let pipeline = PipelineConfiguration(prefetchBytes: bound == "objects" ? 1 << 30 : bound == "bytes" ? 16_384 : 262_144,
        prefetchObjects: bound == "objects" ? 4 : 64, assemblies: 4)
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: initial,
        maxConcurrentObjects: 32, pipeline: pipeline).disk - SpaceBudget.margin
    #expect(budget == 40 * 4096 + (bound == "wide" ? 163_840 : 16_384))
    let ops = try PeakDiskOps(root: temp.url), disk = PayloadCapacityDisk(ops: ops, capacity: budget)
    ops.setPayloadLimit(ops.baseline.payload + budget)
    let events = try await opCollect(InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: disk, fileOps: ops, maxConcurrentObjects: 32, pipeline: pipeline).run())
    #expect(events.last == .phase(.completed) && ops.deniedWrites == 0)
    #expect(ops.peak.parts <= (bound == "wide" ? 163_840 : 16_384))
    #expect(ops.peak.payload - ops.baseline.payload <= budget)
    #expect(cdn.requestLog.count == 40)
}

@Test func resumeReclaimsConsumedPartsBeforeItsSpacePreflight() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "R", count: 4096)
    let plan = try opPlan("consumed-resume", (0..<16).map { ("out\($0)", body) })
    opServe(cdn, plan, Array(repeating: body, count: 16))
    let pipeline = PipelineConfiguration(prefetchBytes: 16_384, prefetchObjects: 4, assemblies: 4)
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs, pipeline: pipeline).disk - SpaceBudget.margin
    #expect(budget == 81_920)
    let ops = try PeakDiskOps(root: temp.url), fault = ConsumedPartUnlinkFailure(base: ops)
    ops.setPayloadLimit(ops.baseline.payload + budget)
    let disk = PayloadCapacityDisk(ops: ops, capacity: budget)
    let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: disk, fileOps: fault, pipeline: pipeline)
    await #expect(throws: LauncherError.io("part cleanup interrupted")) { _ = try await opCollect(engine.run()) }
    let paused = try OperationJournal.replay(fs: fs, path: opJournal(plan))
    #expect(!paused.stagedFiles.isEmpty)
    let consumed = plan.files.filter { paused.stagedFiles.contains($0.path) }.flatMap { SpaceBudget.references($0) }
    let hasConsumedPart = try consumed.contains { try fs.size(at: objectPath(plan, plan.objects[$0]!)) != nil }
    #expect(hasConsumedPart)
    // Interrupted workers can leave needed cached parts as well as consumed
    // parts. Reserve the conservative window without spending their unlink.
    disk.capacity.withLock { $0 += pipeline.prefetchBytes }
    ops.setPayloadLimit(ops.baseline.payload + budget + pipeline.prefetchBytes)
    let resumed = try await opCollect(engine.run()) { event in
        if event == .phase(.staging) {
            // This event precedes Stager.prepare: the engine itself must have
            // removed consumed parts before consulting free space.
            for id in consumed {
                let size = try fs.size(at: objectPath(plan, plan.objects[id]!))
                #expect(size == nil)
            }
        }
    }
    #expect(resumed.last == .phase(.completed))
    #expect(ops.deniedWrites == 0)
    for file in plan.files { #expect(try fs.readFile(at: file.path, maxBytes: 4096) == Data(body.utf8)) }
}

@Test func snapshotPinnedCachedPartsDoNotSpendFutureReclamationOnResume() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "P", count: 4096)
    let plan = try opPlan("snapshot-resume", (0..<64).map { ("out\($0)", body) })
    opServe(cdn, plan, Array(repeating: body, count: 64))
    let pipeline = PipelineConfiguration(prefetchBytes: 65_536, prefetchObjects: 16, assemblies: 4)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try fs.writeAtomically(encoder.encode(plan), to: opPlanPath(plan))
    let journal = try OperationJournal(fs: fs, path: opJournal(plan))
    try await journal.append(.planStored(planID: plan.id, planDigest: plan.planDigest))
    try await journal.append(.operationStarted)
    var pinned = Set<String>()
    for file in plan.files.prefix(32) {
        guard case .chunk(let id) = file.extents[0].source else { throw LauncherError.io("test object reference") }
        let object = plan.objects[id]!
        try fs.writeAtomically(Data(body.utf8), to: objectPath(plan, object))
        try await journal.append(.objectVerified(id: object.id))
        pinned.insert(object.partFileName)
    }
    let budget = try SpaceBudget.required(plan: plan, state: await journal.snapshot(), fs: fs, pipeline: pipeline)
    // Cached blocks already reduce free space. Their later unlink may free nothing.
    #expect(budget.disk == SpaceBudget.margin + 64 * 4096 + 65_536)
    #expect(budget.network == 32 * 4096)
    let ops = try SnapshotPinnedParts(root: temp.url, pinned: pinned, capacity: budget.disk - SpaceBudget.margin)
    let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: ops, fileOps: ops, pipeline: pipeline)
    #expect(try await opCollect(engine.run()).last == .phase(.completed))
    #expect(ops.denied.withLock { $0 } == 0)
    #expect(ops.unlinked.withLock { $0 } == 32 * 4096)
    #expect(cdn.requestLog.count == 32)
}

/// Simulates snapshot-pinned cached extents: unlink succeeds but consumes the
/// same capacity forever. All new writes are capacity-enforced, not just probed.
private final class SnapshotPinnedParts: FileOps, DiskSpaceProbe {
    let base: PeakDiskOps
    let pinned: Set<String>
    let capacity: Int64
    let unlinked = Mutex<Int64>(0)
    let denied = Mutex(0)
    private let mutations = Mutex(())
    init(root: URL, pinned: Set<String>, capacity: Int64) throws {
        base = try PeakDiskOps(root: root); self.pinned = pinned; self.capacity = capacity
    }
    private func growth() throws -> Int64 { try base.currentPayload - base.baseline.payload + unlinked.withLock { $0 } }
    func availableBytes(at url: URL) throws -> Int64 { max(0, SpaceBudget.margin + capacity - (try growth())) }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try mutations.withLock { _ in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN)), info = stat()
            guard fcntl(descriptor, F_GETPATH, &path) == 0, fstat(descriptor, &info) == 0 else {
                throw LauncherError.io("test descriptor")
            }
            let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !name.contains("/.macgacha-") || name.contains("/files/") || name.contains("/objects/") {
                let added = max(0, lseek(descriptor, 0, SEEK_CUR) + Int64(bytes.count) - info.st_size)
                guard try growth() + added <= capacity else {
                    denied.withLock { $0 += 1 }; throw LauncherError.io("test pinned capacity exhausted")
                }
            }
            return try base.write(descriptor, bytes: bytes)
        }
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try mutations.withLock { _ in
            var info = stat()
            let retained = pinned.contains(name) && fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info.st_size : 0
            try base.unlink(name, in: directory, isDirectory: isDirectory)
            unlinked.withLock { $0 += retained }
        }
    }
}

@Test func oversizedFileKeepsResidentSlotsUntilItsAssemblyFinishes() throws {
    let digest = opDigest("x")
    let objects = ["a", "b"].map { ChunkObject(id: $0, urls: [URL(string: "https://cdn.test/\($0)")!],
        transferSize: 1024, decodedSize: 1, decodedDigest: digest, codec: .zstd) }
    let file = FileTask(path: try SafeRelativePath("out"), size: 2, digest: opDigest("xx"),
        extents: objects.enumerated().map { Extent(source: .chunk(id: $0.element.id), fileOffset: Int64($0.offset), length: 1, digest: digest) })
    var allocation = try RemainingAllocation(files: [file], costs: ["a": 1024, "b": 1024], retainedObjects: [], limit: 32,
        pipeline: PipelineConfiguration(prefetchBytes: 1024, prefetchObjects: 1))
    #expect(try allocation.disk() == SpaceBudget.margin + 2050)
    try allocation.setCost("a", to: 0)
    #expect(try allocation.disk() == SpaceBudget.margin + 1026)
}

@Test func residentPartsNeverReduceOversizedFileMissingParts() throws {
    let digest = opDigest("x")
    let file = FileTask(path: try SafeRelativePath("out"), size: 2, digest: opDigest("xx"), extents: [
        Extent(source: .chunk(id: "a"), fileOffset: 0, length: 1, digest: digest),
        Extent(source: .chunk(id: "b"), fileOffset: 1, length: 1, digest: digest)
    ])
    var allocation = try RemainingAllocation(files: [file], costs: ["b": 1024], retainedObjects: [], limit: 32,
        pipeline: PipelineConfiguration(prefetchBytes: 1024, prefetchObjects: 1))
    #expect(try allocation.disk() == SpaceBudget.margin + 1026)
}

private final class ConsumedPartUnlinkFailure: FileOps {
    let base: any FileOps
    private let fired = Mutex(false)
    init(base: any FileOps) { self.base = base }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if name.hasSuffix(".part"), fired.withLock({ if $0 { return false }; $0 = true; return true }) {
            throw LauncherError.io("part cleanup interrupted")
        }
        try base.unlink(name, in: directory, isDirectory: isDirectory)
    }
}

@Test func syntheticGenshinShapedBudgetIsCloseToDecodedSize() throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
    var objects: [String: ChunkObject] = [:], files: [FileTask] = []
    let digest = opDigest("synthetic metadata only")
    for i in 0..<20_000 {
        var extents: [Extent] = []
        for j in 0..<2 {
            let id = "o-\(i)-\(j)"
            objects[id] = ChunkObject(id: id, urls: [URL(string: "https://cdn.test/\(id)")!], transferSize: 3_650_000,
                decodedSize: 3_750_000, decodedDigest: digest, codec: .zstd)
            extents.append(Extent(source: .chunk(id: id), fileOffset: Int64(j) * 3_750_000, length: 3_750_000, digest: digest))
        }
        files.append(FileTask(path: try SafeRelativePath("data/\(i)"), size: 7_500_000, digest: digest, extents: extents))
    }
    let plan = InstallPlan(id: try SafeIdentifier("synthetic-genshin"), objects: objects, files: files)
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs)
    let minimum = try SpaceBudget.minimumBatchedPreflight(plan: plan, state: JournalState(), fs: fs)
    let old: Int64 = 150_000_000_000 + 146_000_000_000 + SpaceBudget.margin
    print("Synthetic Genshin: decoded=150000000000 network=\(budget.network) old=\(old) new=\(budget.disk) minimum=\(minimum) bytes")
    #expect(budget.network == 146_000_000_000)
    #expect(budget.disk == 152_008_141_824)
    #expect(minimum == 151_081_041_824)
}

@Test(arguments: [false, true], [false, true])
func completeInstallFitsMinimumWithDecreasingSpace(update: Bool, batched: Bool) async throws {
    let temp = try TempDir(), initial = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "N", count: 4096)
    let plan = try opPlan("complete-peak", (0..<4).map { ("file-\($0)", body) })
    if update { for file in plan.files { try initial.writeAtomically(Data(repeating: 0x4f, count: 4096), to: file.path) } }
    opServe(cdn, plan, Array(repeating: body, count: 4))
    let whole = try SpaceBudget.required(plan: plan, state: JournalState(), fs: initial).disk
    let minimum = try SpaceBudget.minimumBatchedPreflight(plan: plan, state: JournalState(), fs: initial)
    #expect(minimum == SpaceBudget.margin + 20_480)
    let budget = (batched ? minimum : whole) - SpaceBudget.margin
    let ops = try PeakDiskOps(root: temp.url), disk = PayloadCapacityDisk(ops: ops, capacity: budget)
    ops.setPayloadLimit(ops.baseline.payload + budget)
    let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk,
        mode: .batched(approved: true), fileOps: ops)
    let events = try await opCollect(engine.run())
    #expect(events.last == .phase(.completed))
    #expect(ops.deniedWrites == 0 && ops.peak.payload <= ops.baseline.payload + budget)
    if batched { #expect(events.filter { $0 == .phase(.staging) }.count > 1) }
    for file in plan.files { #expect(try initial.readFile(at: file.path, maxBytes: 4096) == Data(body.utf8)) }
}

@Test func clonedInstallationGetsNoReclamationCreditBeforeAnyBatchStarts() async throws {
    let temp = try TempDir(), backup = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let size = 65_536, old = Data(repeating: 0x4f, count: size), body = String(repeating: "N", count: size)
    let plan = try opPlan("cloned-update", (0..<4).map { ("file-\($0)", body) })
    for file in plan.files {
        try fs.writeAtomically(old, to: file.path)
        let source = file.path.resolved(against: temp.url), clone = file.path.resolved(against: backup.url)
        try #require(clonefile(source.path, clone.path, 0) == 0, "APFS clonefile failed: \(errno)")
        var originalInfo = stat(), cloneInfo = stat()
        try #require(lstat(source.path, &originalInfo) == 0 && lstat(clone.path, &cloneInfo) == 0)
        #expect(originalInfo.st_ino != cloneInfo.st_ino && originalInfo.st_nlink == 1 && cloneInfo.st_nlink == 1)
    }
    opServe(cdn, plan, Array(repeating: body, count: 4))
    let quota = CloneAllocationQuota(root: temp.url, originals: Set(plan.files.map { $0.path.resolved(against: temp.url).path }), capacity: Int64(2 * size))
    #expect(try quota.availableBytes(at: temp.url) == SpaceBudget.margin + Int64(2 * size))
    let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: quota,
        mode: .batched(approved: true), fileOps: quota)
    var stagingEvents = 0
    await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + Int64(5 * size), available: SpaceBudget.margin + Int64(2 * size))) {
        _ = try await opCollect(engine.run(), onEvent: { if $0 == .phase(.staging) { stagingEvents += 1 } })
    }
    #expect(stagingEvents == 0 && cdn.requestLog.isEmpty && quota.deniedWrites == 0)
    #expect(try OperationJournal.replay(fs: fs, path: journalPath(plan)).committedFiles.isEmpty)
    for file in plan.files { #expect(try fs.readFile(at: file.path, maxBytes: size) == old) }
    quota.capacity.withLock { $0 = Int64(5 * size) }
    let events = try await opCollect(engine.run())
    #expect(events.last == .phase(.completed) && events.filter { $0 == .phase(.staging) }.count == 4)
    #expect(quota.deniedWrites == 0 && quota.peak <= Int64(5 * size))
    for file in plan.files {
        #expect(try fs.readFile(at: file.path, maxBytes: size) == Data(body.utf8))
        #expect(try Data(contentsOf: file.path.resolved(against: backup.url)) == old)
    }
}

/// The backup retains every old clone extent throughout the test, so deleting
/// an original inode cannot release those blocks. Measure additional allocation
/// of new inodes using st_blocks (not logical file lengths), including parts and
/// output across renames. The separate retained clone group is already baseline.
private final class CloneAllocationQuota: FileOps, DiskSpaceProbe {
    let capacity: Mutex<Int64>
    private let root: URL
    private let originals: Set<String>
    private let replaced = Mutex<Set<String>>([])
    private let usage = Mutex((peak: Int64(0), denied: 0))
    init(root: URL, originals: Set<String>, capacity: Int64) {
        self.root = root
        // All fixture originals are direct children. Relative names avoid the
        // /var versus /private/var spelling used by Foundation's URL enumerator.
        self.originals = Set(originals.map { URL(fileURLWithPath: $0).lastPathComponent })
        self.capacity = Mutex(capacity)
    }
    var peak: Int64 { usage.withLock { $0.peak } }
    var deniedWrites: Int { usage.withLock { $0.denied } }
    private func allocated() throws -> Int64 {
        var bytes: Int64 = 0
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw LauncherError.io("cannot inspect allocation") }
            guard info.st_mode & S_IFMT == S_IFREG else { continue }
            if url.deletingLastPathComponent().lastPathComponent == root.lastPathComponent,
                originals.contains(url.lastPathComponent), !replaced.withLock({ $0.contains(url.lastPathComponent) }) { continue }
            let path = url.path
            if path.contains("/.macgacha-") && !path.contains("/files/") && !path.contains("/objects/") { continue }
            bytes += info.st_blocks * 512
        }
        return bytes
    }
    func availableBytes(at url: URL) throws -> Int64 { max(0, SpaceBudget.margin + capacity.withLock { $0 } - (try allocated())) }
    private func sample() throws {
        let bytes = try allocated(), limit = capacity.withLock { $0 }
        usage.withLock { $0.peak = max($0.peak, bytes); if bytes > limit { $0.denied += 1 } }
        guard bytes <= limit else { throw LauncherError.io("test allocation capacity exhausted") }
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let count = try SystemFileOps().write(descriptor, bytes: bytes); try sample(); return count
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable); try sample() }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
        if originals.contains(destination) { _ = replaced.withLock { $0.insert(destination) } }
        try sample()
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory); try sample() }
}

@Test(arguments: ["fresh", "update", "batched", "shared", "shared-batched", "update-batched"])
func measuredInstallPeakIsWithinBudget(scenario: String) async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let update = scenario.contains("update"), shared = scenario.contains("shared"), batched = scenario.contains("batched")
    let plan = try peakPlan(fs: fs, cdn: cdn, update: update, shared: shared)
    let tracker = try PeakDiskOps(root: temp.url)
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fs)
    let minimum = try SpaceBudget.minimumBatchedPreflight(plan: plan, state: JournalState(), fs: fs)
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: FixedDiskSpace(bytes: batched ? minimum : budget.disk), mode: .batched(approved: true), fileOps: tracker)
    let events = try await opCollect(operation.run())
    #expect(events.last == .phase(.completed))
    #expect(tracker.peak.total <= tracker.baseline.total + budget.disk)
    // Check payload separately so the 1 GiB metadata/filesystem margin cannot mask a bad part bound.
    #expect(tracker.peak.payload <= tracker.baseline.payload + budget.disk - SpaceBudget.margin)
    print("Peak \(scenario): total=\(tracker.peak.total) payloadGrowth=\(tracker.peak.payload - tracker.baseline.payload) bound=\(budget.disk - SpaceBudget.margin) parts=\(tracker.peak.parts) bytes")
    #expect(tracker.peak.parts >= 12 * 512) // The current file retains more than eight completed parts.
    if batched && minimum < budget.disk { #expect(events.filter { $0 == .phase(.staging) }.count > 1) }
    for file in plan.files {
        let data = try fs.readFile(at: file.path, maxBytes: Int(file.size))
        #expect(opDataDigest(data) == file.digest)
    }
}

@Test(arguments: [false, true]) func resumeProgressKeepsWholePlanTransferTotals(batched: Bool) async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let plan = try opPlan("cumulative", (0..<12).map { ("file-\($0)", "abc") })
    opServe(cdn, plan, Array(repeating: "abc", count: 12))
    let bytes = batched ? SpaceBudget.margin + 39 : Int64.max
    // Stop at a durable verified-file boundary. A non-batched run uses one
    // look-ahead slot so unrelated in-flight requests cannot race cancellation;
    // the batched variant keeps its production window and real batch sequence.
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
        disk: FixedDiskSpace(bytes: bytes), mode: .batched(approved: true),
        pipeline: batched ? .default : PipelineConfiguration(prefetchObjects: 1))
    let first = Task {
        var samples: [(Int64, Int64)] = [], verified = false
        do {
            for try await event in operation.run() {
                if case .fileVerified = event { verified = true }
                if case .progress(let done, let total, _, _) = event {
                    samples.append((done, total))
                    if done > 0 && verified { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        } catch LauncherError.cancelled {}
        return samples
    }
    let previous = try await first.value
    #expect(previous.first?.1 == 36)
    #expect((previous.last?.0 ?? 0) >= 3)
    let events = try await opCollect(operation.run())
    let resumed = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let done, let total, _, _) = event { return (done, total) }; return nil
    }
    #expect((resumed.first?.0 ?? 0) >= (previous.last?.0 ?? 0))
    #expect(resumed.allSatisfy { $0.1 == 36 })
    #expect(resumed.last?.0 == 36)
    #expect(zip(resumed, resumed.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    #expect(events.last == .phase(.completed))
    if batched { #expect(events.filter { $0 == .phase(.staging) }.count > 1) }
    #expect(cdn.requestLog.count == 12)
    #expect(try fs.size(at: plan.files[0].path) == 3)
}

@Test func verifiedUnconsumedPartCountsTowardResumedPlanProgress() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let plan = try opPlan("verified-resume", [("a", "abc"), ("b", "def")])
    try fs.writeAtomically(JSONEncoder().encode(plan), to: opPlanPath(plan))
    let journal = try stagingJournal(fs, plan)
    let object = try #require(plan.objects["verified-resume-0"])
    try fs.writeAtomically(Data("abc".utf8), to: objectPath(plan, object))
    try await journal.append(.objectVerified(id: object.id))
    opServe(cdn, plan, ["abc", "def"])
    let events = try await opCollect(opEngine(plan, temp.url, cdn).run())
    let progress = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let done, let total, _, _) = event { return (done, total) }; return nil
    }
    #expect(progress.first?.0 == 3 && progress.first?.1 == 6)
    #expect(progress.last?.0 == 6 && progress.last?.1 == 6)
    #expect(cdn.requestLog.map(\.path) == ["verified-resume-1"])
}

private func peakPlan(fs: ContainedFileSystem, cdn: MockCDN, update: Bool, shared: Bool) throws -> InstallPlan {
    var objects: [String: ChunkObject] = [:], files: [FileTask] = []
    let good = Data(repeating: 0x71, count: 512), bad = Data(repeating: 0x72, count: 512)
    if update {
        try fs.writeAtomically(good, to: SafeRelativePath("source-good"))
        try fs.writeAtomically(bad, to: SafeRelativePath("source-bad"))
    }
    for i in 0..<12 {
        var body = Data(), extents: [Extent] = []
        for j in 0..<12 {
            let id = shared && j == 0 ? "shared" : "object-\(i)-\(j)"
            let data = Data(repeating: UInt8(j + 1), count: 512), digest = opDataDigest(data)
            objects[id] = ChunkObject(id: id, urls: [URL(string: "https://cdn.test/\(id)")!], transferSize: 512,
                decodedSize: 512, decodedDigest: digest)
            cdn.serve(id, data: data)
            extents.append(Extent(source: .chunk(id: id), fileOffset: Int64(body.count), length: 512, digest: digest))
            body.append(data)
        }
        if update {
            extents.append(Extent(source: .local(path: try SafeRelativePath("source-good"), offset: 0),
                fileOffset: Int64(body.count), length: 512, digest: opDataDigest(good)))
            body.append(good)
            let id = "fallback-\(i)", digest = opDataDigest(good)
            objects[id] = ChunkObject(id: id, urls: [URL(string: "https://cdn.test/\(id)")!], transferSize: 512,
                decodedSize: 512, decodedDigest: digest)
            cdn.serve(id, data: good)
            extents.append(Extent(source: .local(path: try SafeRelativePath("source-bad"), offset: 0),
                fileOffset: Int64(body.count), length: 512, digest: digest, fallbackChunkID: id))
            body.append(good)
            try fs.writeAtomically(bad, to: SafeRelativePath("files/\(i)"))
        }
        files.append(FileTask(path: try SafeRelativePath("files/\(i)"), size: Int64(body.count), digest: opDataDigest(body), extents: extents))
    }
    return InstallPlan(id: try SafeIdentifier("peak"), objects: objects, files: files)
}
private func opDataDigest(_ data: Data) -> Digest { var h = StreamingHasher(.sha256); h.update(data); return h.finalize() }

@Test func subsetRetainsPartsForOutstandingExternalReferrersWithinEnforcedCapacity() async throws {
    let temp = try TempDir(), cdn = MockCDN(), unit: Int64 = 1024
    let plan = try externalReferrerPlan(cdn)
    let ops = try PeakDiskOps(root: temp.url, payloadLimit: 28 * unit)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops), journal = try stagingJournal(fs, plan)
    let files = Array(plan.files.prefix(20))
    let low = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal,
        disk: FixedDiskSpace(bytes: SpaceBudget.margin + 28 * unit))
    await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + 40 * unit, available: SpaceBudget.margin + 28 * unit)) {
        _ = try await collectStaging(low.stage(files: files))
    }
    #expect(cdn.requestLog.isEmpty)
    // The exact sufficient capacity must also work, including the retained parts.
    ops.setPayloadLimit(40 * unit)
    let sufficient = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal,
        disk: FixedDiskSpace(bytes: SpaceBudget.margin + 40 * unit))
    _ = try await collectStaging(sufficient.stage(files: files))
    #expect(ops.peak.payload == 40 * unit)
    #expect(ops.peak.parts == 20 * unit)
    #expect(try await journal.snapshot().stagedFiles == Set(files.map(\.path)))
}

@Test func partitionBatchesPassFullPlanStagerCheckOnSameFreeSpace() async throws {
    let temp = try TempDir(), cdn = MockCDN()
    let ops = try PeakDiskOps(root: temp.url)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    let plan = try externalReferrerPlan(cdn), journal = try stagingJournal(fs, plan)
    let available = SpaceBudget.margin + 28 * 1024
    let result = try SpaceBudget.batchedPreflight(plan: plan, state: JournalState(), fs: fs, available: available)
    #expect(result.batches.count > 1)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal,
        disk: FixedDiskSpace(bytes: available))
    for batch in result.batches {
        ops.setPayloadLimit(try ops.currentPayload + available - SpaceBudget.margin)
        _ = try await collectStaging(stager.stage(files: batch))
        for file in batch {
            try fs.rename(from: stagedPath(plan, file.path), to: file.path)
            try await journal.append(.fileCommitted(path: file.path))
        }
    }
    #expect(try await journal.snapshot().committedFiles.count == 40)
    #expect(cdn.requestLog.count == 20)
}

private func externalReferrerPlan(_ cdn: MockCDN) throws -> InstallPlan {
    let original = try opPlan("external-refs", (0..<20).map { ("a-\($0)", String(repeating: "x", count: 1024)) })
    opServe(cdn, original, Array(repeating: String(repeating: "x", count: 1024), count: 20))
    let later = try original.files.enumerated().map { i, file in
        FileTask(path: try SafeRelativePath("later-\(i)"), size: file.size, digest: file.digest, extents: file.extents)
    }
    return InstallPlan(id: original.id, objects: original.objects, files: original.files + later)
}

@Test(arguments: [false, true]) func reuseOfEarlierReplacementCompletesProgressWithoutFallback(partialRange: Bool) async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let initial = try opPlan("preserved", partialRange ? [("a", "old"), ("suffix", "NEW")] : [("a", "old")])
    var extents = initial.files[0].extents
    if partialRange {
        extents.append(Extent(source: .chunk(id: "preserved-1"), fileOffset: 3, length: 3, digest: opDigest("NEW")))
    }
    let a = FileTask(path: initial.files[0].path, size: partialRange ? 6 : 3,
        digest: opDigest(partialRange ? "oldNEW" : "old"), extents: extents)
    let fallback = stagingObject("preserved-fallback", "old")
    let independentObject = stagingObject("preserved-independent", "xyz")
    let independent = try stagingFile("independent", "xyz", [Extent(source: .chunk(id: independentObject.id), fileOffset: 0,
        length: 3, digest: independentObject.decodedDigest)])
    var objects = initial.objects; objects[fallback.id] = fallback; objects[independentObject.id] = independentObject
    let b = FileTask(path: try SafeRelativePath("b"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: a.path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old"), fallbackChunkID: fallback.id),
    ])
    let plan = InstallPlan(id: initial.id, objects: objects, files: [a, independent, b])
    // Initially unusable; committing a makes this range reusable by the next batch.
    try fs.writeAtomically(Data((partialRange ? "badBAD" : "bad").utf8), to: a.path)
    opServe(cdn, initial, partialRange ? ["old", "NEW"] : ["old"])
    cdn.serve(fallback.id, data: Data("old".utf8)); cdn.serve(independentObject.id, data: Data("xyz".utf8))
    let events = try await opCollect(opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + (partialRange ? 18 : 12), mode: .batched(approved: true)).run())
    #expect(events.last == .phase(.completed))
    let progress = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let done, let total, _, _) = event { return (done, total) }; return nil
    }
    #expect(!progress.isEmpty && progress.allSatisfy { $0.0 <= $0.1 })
    #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 })
    #expect(progress.last?.0 == progress.last?.1)
    #expect(!cdn.requestLog.contains { $0.path == fallback.id })
    #expect(try fs.readFile(at: b.path, maxBytes: 3) == Data("old".utf8))
}

@Test func resumeFetchesFallbackForLocalRangeInvalidatedAfterEarlierCommit() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let a = try opPlan("changed-local", [("a", "new"), ("independent", "xyz")]), fallback = stagingObject("changed-fallback", "old")
    var objects = a.objects; objects[fallback.id] = fallback
    let source = try SafeRelativePath("source")
    let b = FileTask(path: try SafeRelativePath("b"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: source, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old"), fallbackChunkID: fallback.id),
    ])
    let plan = InstallPlan(id: a.id, objects: objects, files: a.files + [b])
    try fs.writeAtomically(Data("old".utf8), to: source)
    try fs.writeAtomically(Data("old".utf8), to: a.files[0].path)
    opServe(cdn, a, ["new", "xyz"]); cdn.serve(fallback.id, data: Data("old".utf8))
    for try await event in try opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + 12, mode: .batched(approved: true)).run() {
        if event == .phase(.checkingSpace), try OperationJournal.replay(fs: fs, path: opJournal(plan)).committedFiles.contains(a.files[0].path) { break }
    }
    try fs.writeAtomically(Data("bad".utf8), to: source)
    let events = try await opCollect(opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + 12, mode: .batched(approved: true)).run())
    #expect(events.last == .phase(.completed))
    let progress = events.compactMap { event -> (Int64, Int64)? in
        if case .progress(let done, let total, _, _) = event { return (done, total) }; return nil
    }
    #expect(progress.first?.0 == 3 && progress.first?.1 == 9)
    #expect(progress.allSatisfy { $0.0 <= $0.1 })
    #expect(progress.last?.0 == 9 && progress.last?.1 == 9)
    #expect(try fs.readFile(at: b.path, maxBytes: 3) == Data("old".utf8))
    #expect(cdn.requestLog.map(\.path).sorted() == ["changed-local-0", "changed-local-1", fallback.id].sorted())
}

@Test func preStagingResumeCanRepartitionWithLocalReuse() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let a = try opPlan("repartition-local", [("a", "new"), ("independent", "xyz")]), fallback = stagingObject("repartition-fallback", "old")
    var objects = a.objects; objects[fallback.id] = fallback
    let b = FileTask(path: try SafeRelativePath("b"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: a.files[0].path, offset: 0), fileOffset: 0, length: 3, digest: opDigest("old"), fallbackChunkID: fallback.id),
    ])
    let plan = InstallPlan(id: a.id, objects: objects, files: a.files + [b])
    try fs.writeAtomically(Data("old".utf8), to: a.files[0].path)
    opServe(cdn, a, ["new", "xyz"]); cdn.serve(fallback.id, data: Data("old".utf8))
    for try await event in try opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + 12, mode: .batched(approved: true)).run() {
        if event == .phase(.staging) { break }
    }
    #expect(cdn.requestLog.isEmpty)
    let events = try await opCollect(opEngine(plan, temp.url, cdn, bytes: SpaceBudget.margin + 15, mode: .batched(approved: true)).run())
    #expect(events.last == .phase(.completed))
    #expect(try fs.readFile(at: b.path, maxBytes: 3) == Data("old".utf8))
    #expect(cdn.requestLog.map(\.path) == ["repartition-local-0", "repartition-local-1"])
    #expect(events.contains(.progress(downloaded: 6, totalNetwork: 6, staged: 9, totalStaged: 9)))
}

@Test(arguments: [false, true]) func localRangeChangesAfterPredictionDoNotConstrainFetching(initiallyReusable: Bool) async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let object = stagingObject("dynamic-fallback", "GOOD"), source = try SafeRelativePath("source")
    let file = try stagingFile("output", "GOOD", [Extent(source: .local(path: source, offset: 0), fileOffset: 0,
        length: 4, digest: object.decodedDigest, fallbackChunkID: object.id)])
    let plan = try stagingPlan([object], [file])
    try fs.writeAtomically(Data((initiallyReusable ? "GOOD" : "BAD!").utf8), to: source)
    cdn.serve(object.id, data: Data("GOOD".utf8))
    var progress: [(Int64, Int64)] = [], changed = false, completed = false
    for try await event in try opEngine(plan, temp.url, cdn).run() {
        if case .progress(let done, let total, _, _) = event {
            progress.append((done, total))
            if !changed {
                changed = true
                try fs.writeAtomically(Data((initiallyReusable ? "BAD!" : "GOOD").utf8), to: source)
            }
        }
        if event == .phase(.completed) { completed = true }
    }
    #expect(completed && changed)
    #expect(progress.first?.0 == 0 && progress.first?.1 == (initiallyReusable ? 0 : 4))
    #expect(progress.allSatisfy { $0.0 <= $0.1 })
    #expect(progress.last?.0 == (initiallyReusable ? 4 : 0) && progress.last?.0 == progress.last?.1)
    #expect(cdn.requestLog.count == (initiallyReusable ? 1 : 0))
    #expect(try fs.readFile(at: file.path, maxBytes: 4) == Data("GOOD".utf8))
}

@Test func progressPredictionCannotBlockAnUnrelatedStagingSubset() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let first = try opPlan("prediction-io", [("first", "abc")]), fallback = stagingObject("future-fallback", "old")
    var objects = first.objects; objects[fallback.id] = fallback
    let later = FileTask(path: try SafeRelativePath("later"), size: 3, digest: opDigest("old"), extents: [
        Extent(source: .local(path: try SafeRelativePath("blocked/old"), offset: 0), fileOffset: 0,
            length: 3, digest: opDigest("old"), fallbackChunkID: fallback.id),
    ])
    let plan = InstallPlan(id: first.id, objects: objects, files: first.files + [later])
    try fs.writeAtomically(Data("regular file, not a directory".utf8), to: SafeRelativePath("blocked"))
    opServe(cdn, first, ["abc"])
    let journal = try stagingJournal(fs, plan)
    let events = try await collectStaging(stagingEngine(plan, fs, cdn, journal).stage(files: first.files))
    #expect(events.contains(.fileVerified(first.files[0].path)))
    #expect(cdn.requestLog.map(\.path) == ["prediction-io-0"])
    #expect(try fs.readFile(at: stagedPath(plan, first.files[0].path), maxBytes: 3) == Data("abc".utf8))
}

@Test(arguments: [false, true]) func unexpectedFallbackPausesBeforeExhaustingCapacityAndResumes(partialPart: Bool) async throws {
    let temp = try TempDir(), initialFS = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let good = String(repeating: "G", count: 4096), bad = String(repeating: "B", count: 4096)
    let object = stagingObject("capacity-fallback", good), source = try SafeRelativePath("source")
    let file = try stagingFile("output", good, [Extent(source: .local(path: source, offset: 0), fileOffset: 0,
        length: 4096, digest: object.decodedDigest, fallbackChunkID: object.id)])
    let plan = try stagingPlan([object], [file])
    try initialFS.writeAtomically(Data(good.utf8), to: source)
    if partialPart {
        // A partial part must belong to a stored plan; startup reclaims orphans.
        try initialFS.writeAtomically(JSONEncoder().encode(plan), to: opPlanPath(plan))
        _ = try stagingJournal(initialFS, plan)
        try initialFS.writeAtomically(Data(good.prefix(512).utf8), to: objectPath(plan, object))
    }
    let ops = try PeakDiskOps(root: temp.url)
    let disk = PayloadCapacityDisk(ops: ops, capacity: 4096)
    ops.setPayloadLimit(ops.baseline.payload + 4096)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    cdn.serve(object.id, data: Data(good.utf8))
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk, fileOps: ops)
    var changed = false
    await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + (partialPart ? 3584 : 4096), available: SpaceBudget.margin)) {
        for try await event in operation.run() {
            if !changed, case .progress(let done, let total, _, _) = event {
                #expect(done == 0 && total == 0)
                changed = true
                try fs.writeAtomically(Data(bad.utf8), to: source)
            }
        }
    }
    #expect(changed && ops.deniedWrites == 0)
    #expect(cdn.requestLog.isEmpty)
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
    #expect(try fs.size(at: file.path) == nil)
    let state = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    #expect(state.verifiedObjects.isEmpty && state.stagedFiles.isEmpty && state.committedFiles.isEmpty)
    #expect(state.commitStartedBatches.isEmpty && !state.completed)
    // The copied output prefix is unverified and may be discarded/rebuilt on resume.
    #expect(try fs.size(at: stagedPath(plan, file.path)) == 4096)
    disk.capacity.withLock { $0 = 12_288 }
    ops.setPayloadLimit(ops.baseline.payload + 12_288)
    let events = try await opCollect(operation.run())
    #expect(events.last == .phase(.completed))
    #expect(ops.deniedWrites == 0)
    #expect(try fs.readFile(at: file.path, maxBytes: 4096) == Data(good.utf8))
    #expect(cdn.requestLog.count == 1 && cdn.requestLog.first?.rangeFrom == nil)
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
}

@Test(arguments: [false, true]) func unexpectedFallbackReservesLaterOutputAndMissingParts(laterFallback: Bool) async throws {
    let temp = try TempDir(), initialFS = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let first = String(repeating: "G", count: 4096), later = String(repeating: "L", count: 8192)
    let firstObject = stagingObject("first-capacity-fallback", first)
    let laterObject = stagingObject("later-capacity-fallback", later)
    let source = try SafeRelativePath("source"), laterSource = try SafeRelativePath("later-source")
    let file = try stagingFile("output", first + later, [
        Extent(source: .local(path: source, offset: 0), fileOffset: 0, length: 4096,
            digest: firstObject.decodedDigest, fallbackChunkID: firstObject.id),
        Extent(source: .local(path: laterSource, offset: 0), fileOffset: 4096, length: 8192,
            digest: laterObject.decodedDigest, fallbackChunkID: laterFallback ? laterObject.id : nil),
    ])
    let plan = try stagingPlan(laterFallback ? [firstObject, laterObject] : [firstObject], [file])
    try initialFS.writeAtomically(Data(first.utf8), to: source)
    try initialFS.writeAtomically(Data(later.utf8), to: laterSource)
    let ops = try PeakDiskOps(root: temp.url)
    let disk = PayloadCapacityDisk(ops: ops, capacity: 12_288)
    ops.setPayloadLimit(ops.baseline.payload + 12_288)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    cdn.serve(firstObject.id, data: Data(first.utf8)); cdn.serve(laterObject.id, data: Data(later.utf8))
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk, fileOps: ops)
    var changed = false
    // The first failed copy occupies 4 KiB, leaving 8 KiB. Its fallback
    // needs 4 KiB alongside 8 KiB more output. That alone must pause;
    // any later invalid fallback is admitted only when actually encountered.
    let required = SpaceBudget.margin + 12_288
    await #expect(throws: LauncherError.insufficientSpace(required: required, available: SpaceBudget.margin + 8192)) {
        for try await event in operation.run() {
            if !changed, case .progress(let done, let total, _, _) = event {
                #expect(done == 0 && total == 0)
                changed = true
                try fs.writeAtomically(Data(repeating: 0x42, count: 4096), to: source)
                if laterFallback { try fs.writeAtomically(Data(repeating: 0x42, count: 8192), to: laterSource) }
            }
        }
    }
    #expect(changed && ops.deniedWrites == 0 && cdn.requestLog.isEmpty)
    #expect(try fs.size(at: objectPath(plan, firstObject)) == nil)
    #expect(try fs.size(at: objectPath(plan, laterObject)) == nil)
    #expect(try fs.size(at: file.path) == nil)
    #expect(try fs.size(at: stagedPath(plan, file.path)) == 4096)
    let state = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    #expect(state.verifiedObjects.isEmpty && state.stagedFiles.isEmpty && state.committedFiles.isEmpty)
    #expect(state.commitStartedBatches.isEmpty && !state.completed)
    disk.capacity.withLock { $0 = 32_768 }
    ops.setPayloadLimit(ops.baseline.payload + 32_768)
    let events = try await opCollect(operation.run())
    #expect(events.last == .phase(.completed))
    #expect(ops.deniedWrites == 0)
    #expect(try fs.readFile(at: file.path, maxBytes: 12_288) == Data((first + later).utf8))
    #expect(cdn.requestLog.count == (laterFallback ? 2 : 1))
    #expect(try fs.size(at: objectPath(plan, firstObject)) == nil)
    #expect(try fs.size(at: objectPath(plan, laterObject)) == nil)
}

@Test func unexpectedSharedFallbackReservesRemainingSessionAndResumes() async throws {
    let temp = try TempDir(), initialFS = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let small = String(repeating: "G", count: 4096), large = String(repeating: "L", count: 8192)
    let object = stagingObject("shared-surprise", small)
    let source = try SafeRelativePath("source"), largeSource = try SafeRelativePath("large-source")
    let extent = Extent(source: .local(path: source, offset: 0), fileOffset: 0, length: 4096,
        digest: object.decodedDigest, fallbackChunkID: object.id)
    let files = try [stagingFile("a", small, [extent]),
        stagingFile("b", large, [Extent(source: .local(path: largeSource, offset: 0), fileOffset: 0,
            length: 8192, digest: opDigest(large))]), stagingFile("c", small, [extent])]
    let plan = try stagingPlan([object], files)
    try initialFS.writeAtomically(Data(small.utf8), to: source)
    try initialFS.writeAtomically(Data(large.utf8), to: largeSource)
    let ops = try PeakDiskOps(root: temp.url), disk = PayloadCapacityDisk(ops: ops, capacity: 16_384)
    ops.setPayloadLimit(ops.baseline.payload + 16_384)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops)
    cdn.serve(object.id, data: Data(small.utf8))
    let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk, fileOps: ops)
    var changed = false
    await #expect {
        for try await event in operation.run() {
            if !changed, case .progress = event {
                changed = true
                try fs.writeAtomically(Data(repeating: 0x42, count: 4096), to: source)
            }
        }
     } throws: { error in
        guard case LauncherError.insufficientSpace(let required, let available) = error else { return false }
        return required > available
    }
    #expect(changed && ops.deniedWrites == 0 && cdn.requestLog.isEmpty)
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
    let paused = try OperationJournal.replay(fs: fs, path: journalPath(plan))
    #expect(paused.verifiedObjects.isEmpty && !paused.completed)
    disk.capacity.withLock { $0 = 24_576 }
    ops.setPayloadLimit(ops.baseline.payload + 24_576)
    #expect(try await opCollect(operation.run()).last == .phase(.completed))
    #expect(ops.deniedWrites == 0 && cdn.requestLog.count == 1)
    for file in files {
        #expect(try fs.readFile(at: file.path, maxBytes: 8192) == Data((file.path == files[1].path ? large : small).utf8))
    }
    #expect(try fs.size(at: objectPath(plan, object)) == nil)
}

@Test func operationStagesOneThousandBatchesWithLinearWork() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let local = String(repeating: "L", count: 1024), remote = String(repeating: "N", count: 1024)
    let source = try SafeRelativePath("source"), fallback = stagingObject("scale-local", local)
    try fs.writeAtomically(Data(local.utf8), to: source)
    var files: [FileTask] = [], objects: [ChunkObject] = [fallback]
    for index in 0..<1000 {
        let object = stagingObject("scale-\(index)", remote)
        let file = try stagingFile("file-\(index)", local + remote, [
            Extent(source: .local(path: source, offset: 0), fileOffset: 0, length: 1024,
                digest: fallback.decodedDigest, fallbackChunkID: fallback.id),
            Extent(source: .chunk(id: object.id), fileOffset: 1024, length: 1024, digest: object.decodedDigest),
        ])
        files.append(file); objects.append(object); cdn.serve(object.id, data: Data(remote.utf8))
        try fs.writeAtomically(Data(repeating: 0x4f, count: 2048), to: file.path)
    }
    let plan = try stagingPlan(objects, files), clock = ContinuousClock(), start = clock.now
    let work = EngineWorkCounter()
    let events = try await OperationWork.$observer.withValue({ work.record($0) }) {
        let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn),
            disk: FixedDiskSpace(bytes: SpaceBudget.margin + 2_050_048), mode: .batched(approved: true), fileOps: ScaleFileOps())
        var events: [OperationEvent] = [], batches = 0
        for try await event in engine.run() {
            events.append(event)
            if event == .phase(.staging) {
                batches += 1
                // Fail early if operation-wide setup regresses to per-batch
                // work, without running the entire quadratic mutant first.
                if batches == 2 { try #require(work.snapshot[.referrerIndexBuild] == 1) }
            }
        }
        return events
    }
    let elapsed = start.duration(to: clock.now)
    print("InstallOperation scale: 1000 batches, 1000 reusable ranges with fallbacks, \(elapsed); work: \(work.snapshot)")
    // Constant operation-wide setup and linear local checks, independent of
    // runner speed. The fallback makes repeated prediction actually rehash data.
    #expect(work.snapshot[.referrerIndexBuild] == 1)
    #expect((work.snapshot[.planValidation] ?? 0) <= 5)
    #expect(work.snapshot[.predictionFile] == files.count)
    #expect((work.snapshot[.localRangeHash] ?? 0) <= 5 * files.count)
    #expect(events.filter { $0 == .phase(.staging) }.count == 1000 && events.last == .phase(.completed))
    #expect(cdn.requestLog.count == 1000)
    for file in files { #expect(try fs.size(at: file.path) == 2048) }
}

final class EngineWorkCounter: Sendable {
    private let counts = Mutex<[OperationWork: Int]>([:])
    func record(_ work: OperationWork) { counts.withLock { $0[work, default: 0] += 1 } }
    var snapshot: [OperationWork: Int] { counts.withLock { $0 } }
}

/// Keep the execution-scale test about indexes and range reads, not storage latency.
private struct ScaleFileOps: FileOps {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {}
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

@Test func cancelledPartialDecodeResumesWithoutAddingSpace() async throws {
    let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "N", count: 131_072), plan = try opPlan("partial-resume", [("output", body)])
    opServe(cdn, plan, [body])
    let tracker = try PeakDiskOps(root: temp.url), ops = CancelOutputOps(tracker: tracker)
    let disk = PayloadCapacityDisk(ops: tracker, capacity: 262_144)
    tracker.setPayloadLimit(tracker.baseline.payload + 262_144)
    let engine = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk, fileOps: ops)
    let first = Task {
        await #expect(throws: LauncherError.cancelled) { _ = try await opCollect(engine.run()) }
        return ()
    }
    await first.value
    #expect(try fs.size(at: stagedPath(plan, plan.files[0].path)) == 65_536)
    #expect(try OperationJournal.replay(fs: fs, path: journalPath(plan)).stagedFiles.isEmpty)
    let events = try await opCollect(engine.run())
    #expect(events.last == .phase(.completed) && tracker.deniedWrites == 0)
    #expect(cdn.requestLog.count == 1)
    #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 131_072) == Data(body.utf8))
}

private final class CancelOutputOps: FileOps {
    let tracker: PeakDiskOps
    private let armed = Mutex(true)
    init(tracker: PeakDiskOps) { self.tracker = tracker }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        let count = try tracker.write(descriptor, bytes: bytes)
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(descriptor, F_GETPATH, &path) == 0,
            String(decoding: path.prefix { $0 != 0 }, as: UTF8.self).contains("/files/"),
            armed.withLock({ value in let old = value; value = false; return old }) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw LauncherError.cancelled
        }
        return count
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try tracker.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try tracker.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try tracker.unlink(name, in: directory, isDirectory: isDirectory) }
}

/// Available payload bytes above the engine's safety margin, tied to actual writes.
private final class PayloadCapacityDisk: DiskSpaceProbe {
    let ops: PeakDiskOps
    let capacity: Mutex<Int64>
    init(ops: PeakDiskOps, capacity: Int64) { self.ops = ops; self.capacity = Mutex(capacity) }
    func availableBytes(at url: URL) throws -> Int64 {
        let growth = try ops.currentPayload - ops.baseline.payload
        return max(0, SpaceBudget.margin + capacity.withLock { $0 } - growth)
    }
}

/// Samples logical file bytes after every write/sync/rename/unlink, including control files.
/// A serialized syscall+sample prevents concurrent object writes from hiding a peak.
private final class PeakDiskOps: FileOps, Sendable {
    struct Usage { var total: Int64 = 0, payload: Int64 = 0, parts: Int64 = 0 }
    let baseline: Usage
    private let root: URL
    private let lock = Mutex(Usage())
    private let payloadLimit: Mutex<Int64?>
    private let failures = Mutex(0)
    private let system = SystemFileOps()
    init(root: URL, payloadLimit: Int64? = nil) throws {
        self.root = root; baseline = try Self.usage(root); self.payloadLimit = Mutex(payloadLimit)
    }
    func setPayloadLimit(_ value: Int64) { payloadLimit.withLock { $0 = value } }
    var peak: Usage { lock.withLock { $0 } }
    var deniedWrites: Int { failures.withLock { $0 } }
    var currentPayload: Int64 { get throws { try Self.usage(root).payload } }
    private static func usage(_ root: URL) throws -> Usage {
        var result = Usage()
        let values: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(values))!
        for case let url as URL in walker {
            let info = try url.resourceValues(forKeys: values)
            if info.isRegularFile == true {
                let size = Int64(info.fileSize ?? 0); result.total += size
                let path = url.path
                if !path.contains("/.macgacha-") || path.contains("/files/") || path.contains("/objects/") { result.payload += size }
                if path.contains("/objects/") { result.parts += size }
            }
        }
        return result
    }
    private func sample(_ max: inout Usage) throws {
        let now = try Self.usage(root)
        max.total = Swift.max(max.total, now.total); max.payload = Swift.max(max.payload, now.payload); max.parts = Swift.max(max.parts, now.parts)
    }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        try lock.withLock { peak in
            if let limit = payloadLimit.withLock({ $0 }) {
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw LauncherError.io("test descriptor path") }
                let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !name.contains("/.macgacha-") || name.contains("/files/") || name.contains("/objects/") {
                    var info = stat()
                    guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("test descriptor size") }
                    let offset = lseek(descriptor, 0, SEEK_CUR)
                    let growth = max(0, offset + Int64(bytes.count) - info.st_size)
                    guard try Self.usage(root).payload + growth <= limit else {
                        failures.withLock { $0 += 1 }
                        throw LauncherError.io("test capacity exhausted")
                    }
                }
            }
            let n = try system.write(descriptor, bytes: bytes); try sample(&peak); return n
        }
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        try lock.withLock { peak in try system.synchronize(descriptor, durable: durable); try sample(&peak) }
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try lock.withLock { peak in
            try system.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive); try sample(&peak)
        }
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try lock.withLock { peak in try system.unlink(name, in: directory, isDirectory: isDirectory); try sample(&peak) }
    }
}

@Test func remainingAllocationHandlesGameScaleWithinTimeBudget() throws {
    let digest = opDigest("metadata"), clock = ContinuousClock()
    var files: [FileTask] = [], costs: [String: Int64] = [:]
    for i in 0..<32_250 {
        let extents = (0..<4).map { j in
            let id = "part-\(i)-\(j)"
            costs[id] = 1024
            return Extent(source: .chunk(id: id), fileOffset: Int64(j * 1024), length: 1024, digest: digest)
        }
        files.append(FileTask(path: try SafeRelativePath("file-\(i)"), size: 4096, digest: digest, extents: extents))
    }
    let start = clock.now
    var allocation = try RemainingAllocation(files: files, costs: costs, retainedObjects: [], limit: 8)
    for file in files {
        #expect(try allocation.disk() >= SpaceBudget.margin + file.size)
        for id in SpaceBudget.references(file) { try allocation.setCost(id, to: 0) }
        try allocation.finish(file)
    }
    let duration = start.duration(to: clock.now)
    print("Remaining allocation: 129000 objects / 32250 files: \(duration)")
    #expect(duration < .seconds(10))
    #expect(try allocation.disk() == SpaceBudget.margin)
}

@Test func incrementalAllocationMatchesLifetimeOracleAfterAdmissionsFetchesAndCompletion() throws {
    let digest = opDigest("metadata")
    let files = try (0..<40).map { i in
        FileTask(path: try SafeRelativePath("oracle-\(i)"), size: 2048, digest: digest, extents: [
            Extent(source: .chunk(id: "direct-\(i)"), fileOffset: 0, length: 1024, digest: digest),
            Extent(source: .local(path: try SafeRelativePath("source"), offset: 0), fileOffset: 1024,
                length: 1024, digest: digest, fallbackChunkID: "fallback-\(i % 5)"),
        ])
    }
    let external: Set<String> = ["direct-39", "fallback-1"]
    var costs = Dictionary(uniqueKeysWithValues: (0..<40).map { ("direct-\($0)", Int64(1024)) })
    var allocation = try RemainingAllocation(files: files, costs: costs, retainedObjects: external, limit: 8)
    var resident = Set<String>()
    // All forty tiny parts fit in one window. An independent oracle reserves
    // every remaining decoded byte plus every missing referenced part. Already
    // resident parts occupy real disk and are excluded from additional cost.
    func reference(_ start: Int, written: Int64 = 0) throws -> Int64 {
        let remaining = files.dropFirst(start)
        let refs = remaining.reduce(into: Set<String>()) { $0.formUnion(SpaceBudget.references($1)) }
        let missing = refs.subtracting(resident).reduce(Int64(0)) { $0 + costs[$1, default: 0] }
        let decoded = remaining.reduce(Int64(0)) { $0 + $1.size }
        return SpaceBudget.margin + max(0, decoded - written) + missing
    }
    for (index, file) in files.enumerated() {
        #expect(try allocation.disk() == reference(index))
        let fallback = "fallback-\(index % 5)"
        costs[fallback] = 2048
        resident.remove(fallback) // Also exercise deletion/re-admission for retry.
        try allocation.setCost(fallback, to: 2048)
        #expect(try allocation.disk(written: 512) == reference(index, written: 512))
        for id in SpaceBudget.references(file) {
            resident.insert(id)
            try allocation.setCost(id, to: 0)
        }
        #expect(try allocation.disk() == reference(index))
        try allocation.finish(file)
        let later = files.dropFirst(index + 1).reduce(into: external) { $0.formUnion(SpaceBudget.references($1)) }
        resident.formIntersection(later)
        #expect(try allocation.disk() == reference(index + 1))
    }
}

@Test(arguments: [false, true])
func plannedFallbacksFitExactPreflightWithDecreasingSpace(batched: Bool) async throws {
    let temp = try TempDir(), initialFS = try ContainedFileSystem(root: temp.url), cdn = MockCDN()
    let body = String(repeating: "G", count: 4096)
    let source = try SafeRelativePath("invalid-source")
    try initialFS.writeAtomically(Data(repeating: 0x42, count: 4096), to: source)
    var objects: [ChunkObject] = [], files: [FileTask] = []
    for i in 0..<10 {
        let direct = stagingObject("direct-budget-\(i)", body)
        let fallback = stagingObject("fallback-budget-\(i)", body)
        objects += [direct, fallback]
        cdn.serve(direct.id, data: Data(body.utf8)); cdn.serve(fallback.id, data: Data(body.utf8))
        files.append(try stagingFile("output-\(i)", body + body, [
            Extent(source: .chunk(id: direct.id), fileOffset: 0, length: 4096, digest: direct.decodedDigest),
            Extent(source: .local(path: source, offset: 0), fileOffset: 4096, length: 4096,
                digest: fallback.decodedDigest, fallbackChunkID: fallback.id),
        ]))
    }
    let plan = try stagingPlan(objects, files)
    let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: initialFS)
    #expect(budget.disk == SpaceBudget.margin + 160 * 1024)
    let ops = try PeakDiskOps(root: temp.url)
    let disk = PayloadCapacityDisk(ops: ops, capacity: budget.disk - SpaceBudget.margin)
    ops.setPayloadLimit(ops.baseline.payload + budget.disk - SpaceBudget.margin)
    let fs = try ContainedFileSystem(root: temp.url, fileOps: ops), journal = try stagingJournal(fs, plan)
    let stager = try Stager(plan: plan, fs: fs, fetcher: stagingFetcher(cdn), journal: journal, disk: disk)
    let batches = batched ? [Array(files.prefix(5)), Array(files.suffix(5))] : [files]
    for batch in batches {
        let preflight = try SpaceBudget.estimate(plan: plan, files: batch, state: await journal.snapshot(), fs: fs)
        let available = try fs.availableBytes(using: disk)
        #expect(available >= preflight.disk)
        // The whole plan starts at the accepted window-aware budget.
        if !batched { #expect(available == preflight.disk) }
        _ = try await collectStaging(stager.stage(files: batch))
        if batched {
            for file in batch {
                try fs.rename(from: stagedPath(plan, file.path), to: file.path)
                try await journal.append(.fileCommitted(path: file.path))
            }
        }
    }
    #expect(ops.deniedWrites == 0)
    #expect(ops.peak.payload - ops.baseline.payload <= budget.disk - SpaceBudget.margin)
    #expect(cdn.requestLog.count == 20)
    for file in files {
        let path = batched ? file.path : try stagedPath(plan, file.path)
        #expect(try fs.readFile(at: path, maxBytes: 8192) == Data((body + body).utf8))
    }
}
