// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import Sophon
import TestSupport
@testable import DownloadEngine

@Suite(.timeLimit(.minutes(1))) struct PatchOperationTests {
    @Test func positionalWritesPreserveCursorAndAccountForOutputAllocation() async throws {
        let temp = try TempDir(), gate = PipelineIOGate()
        let path = try SafeRelativePath("scratch")
        let fs = try ContainedFileSystem(root: temp.url, fileOps: PipelineFileOps(base: SystemFileOps(), gate: gate))
        try await BlockingIO.run {
            try PipelineIOGate.$output.withValue(path) {
                let output = try fs.openForWriting(at: path, truncate: true)
                defer { try? output.close() }
                try output.seek(toOffset: 1)
                let count = try Data("abc".utf8).withUnsafeBytes {
                    try fs.fileOps.write(output.fileDescriptor, bytes: $0, at: 0)
                }
                #expect(count == 3)
                #expect(try output.offset() == 1)
                #expect(gate.snapshot { gate.allocations().outputs[path] } == 3)
                _ = try Data("z".utf8).withUnsafeBytes {
                    try fs.fileOps.write(output.fileDescriptor, bytes: $0, at: 0)
                }
                #expect(gate.allocations().outputs[path] == 3)
            }
        }
        #expect(try fs.readFile(at: path, maxBytes: 3) == Data("zbc".utf8))
    }

    @Test func actualHDiffCommitsAndRetainsContainerThroughRename() async throws {
        let fixture = try PatchOperationFixture()
        let retained = Mutex(false), fs = fixture.fs
        let path = try StagingLayout(id: fixture.plan.id).object(try #require(fixture.plan.objects["container"]))
        let hooks = CrashHooks(at: .afterRenameBeforeJournal, action: { retained.withLock { $0 = (try? fs.size(at: path)) != nil } })
        let events = try await fixture.run(hooks: hooks)
        #expect(events.last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(fixture.cdn.requestLog.map(\.path) == ["container"])
        #expect(retained.withLock { $0 })
    }

    @Test func rawCopyCommitsWithoutFallbackChunks() async throws {
        let fixture = try PatchOperationFixture(copy: true)
        #expect(try await fixture.run().last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(fixture.cdn.requestLog.map(\.path) == ["container"])
    }

    @Test func modifiedSourceUsesChunkFallback() async throws {
        let fixture = try PatchOperationFixture()
        try fixture.fs.writeAtomically(Data("bad".utf8), to: SafeRelativePath("game.bin"))
        #expect(try await fixture.run().last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(fixture.cdn.requestLog.map(\.path) == ["chunk"])
    }

    @Test func malformedPatchUsesChunkFallback() async throws {
        let fixture = try PatchOperationFixture(malformed: true)
        #expect(try await fixture.run().last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(Set(fixture.cdn.requestLog.map(\.path)) == ["container", "chunk"])
    }

    @Test func corruptContainerIsRefetchedBeforeChunkFallback() async throws {
        let fixture = try PatchOperationFixture()
        fixture.cdn.enqueueFault("container", .corruptByte(at: 0)); fixture.cdn.enqueueFault("container", .corruptByte(at: 0))
        #expect(try await fixture.run().last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(fixture.cdn.requestLog.filter { $0.path == "container" }.count == 2)
        #expect(fixture.cdn.requestLog.last?.path == "chunk")
    }

    @Test func missingPrimarySpaceRefusesBeforeAnyTransfer() async throws {
        let fixture = try PatchOperationFixture()
        await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + Int64(fixture.container.count) + 3,
            available: SpaceBudget.margin + 2)) { try await fixture.run(disk: FixedDiskSpace(bytes: SpaceBudget.margin + 2)) }
        #expect(fixture.cdn.requestLog.isEmpty)
        #expect(try fixture.output() == Data("old".utf8))
    }

    @Test(arguments: [false, true]) func unsupportedCodecAndWrongOutputUseChunkFallback(wrongOutput: Bool) async throws {
        let fixture = try PatchOperationFixture()
        #expect(try await fixture.run(applier: FailingPatchApplier(wrongOutput: wrongOutput)).last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(Set(fixture.cdn.requestLog.map(\.path)) == ["container", "chunk"])
    }

    @Test func admittedFallbackRequiresItsOwnRemainingAllocation() async throws {
        let fixture = try PatchOperationFixture(), disk = PatchBudgetProbe()
        do {
            _ = try await fixture.run(disk: disk, applier: FailingPatchApplier(wrongOutput: false, disk: disk))
            Issue.record("Fallback must refuse an insufficient reservation")
        } catch let error as LauncherError {
            guard case .insufficientSpace = error else { Issue.record("Expected fallback capacity refusal"); return }
        }
        #expect(fixture.cdn.requestLog.map(\.path) == ["container"])
        #expect(try fixture.output() == Data("old".utf8))
    }

    @Test func batchPartitionPreservesPatchSourcesUntilDependentsStage() throws {
        let fixture = try PatchOperationFixture(), first = fixture.plan.files[0]
        let second = FileTask(path: try SafeRelativePath("dependent"), size: first.size, digest: first.digest,
            extents: first.extents, recipe: first.recipe)
        let plan = InstallPlan(id: fixture.plan.id, objects: fixture.plan.objects, files: [first, second])
        let result = try SpaceBudget.batchedPreflight(plan: plan, state: JournalState(), fs: fixture.fs, available: Int64.max)
        #expect(result.batches.count == 1)
        #expect(result.batches[0].map(\.path) == [first.path, second.path])
    }

    @Test func crashAfterContainerFetchResumesTheSavedDualRecipe() async throws {
        let fixture = try PatchOperationFixture(), archive = try TempDir()
        let stored = try ContainedFileSystem(root: archive.url)
        try stored.writeAtomically(JSONEncoder().encode(fixture.plan), to: SafeRelativePath("plan.json"))
        try stored.writeAtomically(fixture.container, to: SafeRelativePath("container"))
        try stored.writeAtomically(Data("ol!".utf8), to: SafeRelativePath("chunk"))
        let executable = try crashHarnessURL(in: Bundle(for: PatchCrashBundle.self).bundleURL)
        let result = try await SystemProcessRunner().run(executable,
            arguments: [archive.url.path, fixture.temp.url.path, CrashPoint.afterObjectVerified.rawValue], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 137)
        #expect(try fixture.output() == Data("old".utf8))
        #expect(try await fixture.run().last == .phase(.completed))
        #expect(try fixture.output() == Data("ol!".utf8))
        #expect(fixture.cdn.requestLog.isEmpty)
    }

    @Test func retentionReservesAllBatchContainersBeyondThePrefetchWindow() throws {
        let fixture = try PatchOperationFixture(copy: true)
        let object = try #require(fixture.plan.objects["container"])
        let other = ChunkObject(id: "other", urls: object.urls, transferSize: object.transferSize, transferDigest: object.transferDigest,
            decodedSize: object.decodedSize, decodedDigest: object.decodedDigest)
        let first = fixture.plan.files[0]
        let second = FileTask(path: try SafeRelativePath("second"), size: first.size, digest: first.digest, extents: first.extents,
            recipe: .copy(container: other.id, offset: 3, length: 3))
        var objects = fixture.plan.objects; objects[other.id] = other
        let plan = InstallPlan(id: fixture.plan.id, objects: objects, files: [first, second])
        let budget = try SpaceBudget.required(plan: plan, state: JournalState(), fs: fixture.fs,
            pipeline: PipelineConfiguration(prefetchBytes: 1, prefetchObjects: 1, assemblies: 1))
        #expect(budget.disk == SpaceBudget.margin + 6 + object.transferSize * 2)
        #expect(budget.network == object.transferSize * 2)
    }
}

private final class PatchCrashBundle: NSObject {}
private final class PatchOperationFixture {
    let temp: TempDir
    let fs: ContainedFileSystem
    let plan: InstallPlan
    let container: Data
    let cdn = MockCDN()
    init(copy: Bool = false, malformed: Bool = false) throws {
        temp = try TempDir(); fs = try ContainedFileSystem(root: temp.url)
        let old = Data("old".utf8), target = Data("ol!".utf8)
        let patch = malformed ? Data("malformed".utf8) : Data("HDIFF13&\0".utf8)
            + Data([3, 3, 1, 3, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 2, 33])
        let body = copy ? target : patch
        container = Data("pad".utf8) + body + Data("end".utf8)
        let chunk = ChunkObject(id: "chunk", urls: [URL(string: "https://cdn.test/chunk")!], transferSize: 3, transferDigest: patchDigest(target),
            decodedSize: 3, decodedDigest: patchDigest(target))
        let object = ChunkObject(id: "container", urls: [URL(string: "https://cdn.test/container")!], transferSize: Int64(container.count),
            transferDigest: patchDigest(container), decodedSize: Int64(container.count), decodedDigest: patchDigest(container))
        let recipe: FileRecipe = copy ? .copy(container: object.id, offset: 3, length: 3)
            : .patch(source: try SafeRelativePath("game.bin"), sourceSize: 3, sourceDigest: patchDigest(old), container: object.id, offset: 3, length: Int64(body.count))
        let file = FileTask(path: try SafeRelativePath("game.bin"), size: 3, digest: patchDigest(target),
            extents: [Extent(source: .chunk(id: chunk.id), fileOffset: 0, length: 3, digest: patchDigest(target))], recipe: recipe)
        plan = InstallPlan(id: try SafeIdentifier("patch-operation"), objects: [object.id: object, chunk.id: chunk], files: [file])
        try fs.writeAtomically(old, to: file.path)
        cdn.serve(object.id, data: container); cdn.serve(chunk.id, data: target)
    }
    func output() throws -> Data { try fs.readFile(at: plan.files[0].path, maxBytes: 100) }
    func run(disk: any DiskSpaceProbe = FixedDiskSpace(bytes: Int64.max), hooks: CrashHooks = .none, applier: any WholeFilePatchApplier = HDiff13PatchApplier()) async throws -> [OperationEvent] {
        let operation = try InstallOperation(plan: plan, installRoot: temp.url, fetcher: stagingFetcher(cdn), disk: disk,
            crashHooks: hooks, patchApplier: applier)
        var events: [OperationEvent] = []
        for try await event in operation.run() { events.append(event) }
        return events
    }
}
private func patchDigest(_ data: Data) -> Digest { var hash = StreamingHasher(.md5); hash.update(data); return hash.finalize() }

private final class PatchBudgetProbe: DiskSpaceProbe, Sendable {
    let remaining = Mutex(Int64.max)
    func availableBytes(at url: URL) throws -> Int64 { remaining.withLock { $0 } }
}
private struct FailingPatchApplier: WholeFilePatchApplier {
    let wrongOutput: Bool
    var disk: PatchBudgetProbe? = nil
    func apply(source: SafeRelativePath, sourceSize: Int64, container: SafeRelativePath, offset: Int64, length: Int64,
        expectedSize: Int64, fs: ContainedFileSystem, output: FileHandle) async throws {
        if let disk { disk.remaining.withLock { $0 = SpaceBudget.margin + 5 } }
        if wrongOutput { try fs.fileOps.writeAll(Data("bad".utf8), to: output.fileDescriptor) }
        else { throw LauncherError.unsupportedCompressor }
    }
}
