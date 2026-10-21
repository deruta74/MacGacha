// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Suite(.serialized)
struct CrashRecoveryTests {
    @Test(arguments: [CrashPoint.afterObjectVerified, .afterFileStagedBeforeJournal, .afterRenameBeforeJournal,
        .midJournalWrite, .afterCommitStartedBeforeFirstRename, .beforeCompleted])
    func processDeathIsRecoverable(point: CrashPoint) async throws {
        let fixtures = try TempDir(); let root = try TempDir()
        let fixtureURL = fixtures.url, rootURL = root.url
        let plan = try crashFixture(fixtureURL, root: rootURL)
        let executable = try crashHarnessURL(in: Bundle(for: CrashTestBundleToken.self).bundleURL)
        let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await SystemProcessRunner().run(executable,
                    arguments: [fixtureURL.path, rootURL.path, point.rawValue], environment: [:], currentDirectory: nil)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LauncherError.io("Crash harness deadline")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LauncherError.io("No harness result") }
            return result
        }
        #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
        let fs = try ContainedFileSystem(root: root.url)
        let journal = try opJournal(plan)
        let state = try OperationJournal.replay(fs: fs, path: journal)
        #expect(!state.completed)
        switch point {
        case .afterObjectVerified:
            #expect(!state.verifiedObjects.isEmpty)
            #expect(state.stagedFiles.isEmpty)
        case .afterFileStagedBeforeJournal:
            #expect(state.stagedFiles.isEmpty)
            #expect(try fs.size(at: opStaged(plan, plan.files[0].path)) == plan.files[0].size)
        case .afterCommitStartedBeforeFirstRename:
            #expect(!state.commitStartedBatches.isEmpty)
            #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 100) == Data("old-a".utf8))
        case .afterRenameBeforeJournal, .midJournalWrite:
            #expect(!state.commitStartedBatches.isEmpty)
            #expect(state.committedFiles.isEmpty)
            #expect(try fs.size(at: opStaged(plan, plan.files[0].path)) == nil)
            if point == .midJournalWrite {
                let bytes = try fs.readFile(at: journal, maxBytes: 65_536)
                #expect(bytes.last != 0x0a)
            }
        case .beforeCompleted:
            #expect(state.committedFiles.count == plan.files.count)
            #expect(state.deletedFiles == Set(plan.deletions))
            #expect(try InstallStateMarker.load(fs: fs) != nil)
        case .afterOperationCompleted, .duringCompletionReceiptWrite, .duringGamePlanWrite, .afterCompletionReceipt, .afterEngineCleanup, .afterGamePlanSaved,
            .afterGamePendingSaved, .afterGameRecordSaved, .afterGamePlanDeleted, .afterReceiptAcknowledged,
            .afterGameFolderRemoved, .beforeGameRecordDeleted, .afterUninstallPlanDeleted, .afterUninstallManifestCacheDeleted,
            .afterUninstallBranchDeleted, .afterUninstallManagedPathsDeleted, .afterUninstallCleanupDeleted, .afterUninstallRecordDeleted:
            Issue.record("Receipt/bridge crash points have separate recovery scenarios")
        }
        if state.commitStartedBatches.isEmpty {
            #expect(try fs.readFile(at: plan.files[0].path, maxBytes: 100) == Data("old-a".utf8))
            #expect(try fs.readFile(at: SafeRelativePath("obsolete"), maxBytes: 100) == Data("old".utf8))
        }
        try await finishFixture(plan, fixtures: fixtures.url, root: root.url)
        try assertFixture(plan, root: root.url)
        // A second run must also be safe after completed cleanup.
        try await finishFixture(plan, fixtures: fixtures.url, root: root.url)
        try assertFixture(plan, root: root.url)
    }
}

private final class CrashTestBundleToken: NSObject {}

/// Resolve only beside this test image, so release and custom scratch builds cannot
/// accidentally execute a different configuration's harness. Build order may put the
/// harness timestamp before the bundle's, so timestamps are not a freshness signal.
func crashHarnessURL(in testBundle: URL) throws -> URL {
    guard testBundle.pathExtension == "xctest" else {
        throw LauncherError.io("Cannot locate current .xctest bundle: \(testBundle.path)")
    }
    let harness = testBundle.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    let files = FileManager.default
    guard files.isExecutableFile(atPath: harness.path),
          let attributes = try? files.attributesOfItem(atPath: harness.path),
          attributes[.type] as? FileAttributeType == .typeRegular else {
        throw LauncherError.io("CrashHarness is missing or not executable beside test bundle: \(harness.path)")
    }
    return harness
}

@Test(arguments: ["current", "missing", "older"])
func crashHarnessLookupUsesCurrentProductsRegardlessOfTimestamp(scenario: String) throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    let bundle = temp.url.appendingPathComponent("custom-scratch/Release/CurrentTests.xctest")
    let harness = bundle.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    try fs.createDirectory(at: SafeRelativePath("custom-scratch/Release/CurrentTests.xctest"))
    if scenario != "missing" {
        try fs.writeAtomically(Data("fixture executable".utf8), to: SafeRelativePath("custom-scratch/Release/CrashHarness"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755,
            .modificationDate: Date(timeIntervalSince1970: scenario == "older" ? 99 : 101)], ofItemAtPath: harness.path)
    }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: bundle.path)
    if scenario == "missing" {
        #expect(throws: LauncherError.io("CrashHarness is missing or not executable beside test bundle: \(harness.path)")) {
            _ = try crashHarnessURL(in: bundle)
        }
    } else {
        #expect(try crashHarnessURL(in: bundle) == harness)
    }
}

func crashFixture(_ fixtures: URL, root: URL) throws -> InstallPlan {
    let fs = try ContainedFileSystem(root: fixtures)
    let base = try opPlan("crash", [("Data/a", String(repeating: "abcd", count: 40_000)), ("Data/b", "tail")])
    // Shared object exercises refcounts across distinct output files and repeated extents.
    let a = base.files[0]
    let b = FileTask(path: base.files[1].path, size: a.size * 2,
        digest: opDigest(String(repeating: "abcd", count: 80_000)),
        extents: [a.extents[0], Extent(source: a.extents[0].source, fileOffset: a.size,
            length: a.size, digest: a.digest)])
    let plan = InstallPlan(id: base.id, objects: ["crash-0": base.objects["crash-0"]!], files: [a, b],
        deletions: [try SafeRelativePath("obsolete")])
    try plan.validate()
    try fs.writeAtomically(Data(String(repeating: "abcd", count: 40_000).utf8), to: SafeRelativePath("crash-0"))
    try fs.writeAtomically(JSONEncoder().encode(plan), to: SafeRelativePath("plan.json"))
    let installed = try ContainedFileSystem(root: root)
    try installed.writeAtomically(Data("old-a".utf8), to: a.path)
    try installed.writeAtomically(Data("old-b".utf8), to: b.path)
    try installed.writeAtomically(Data("old".utf8), to: SafeRelativePath("obsolete"))
    try installed.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("keep"))
    return plan
}

func finishFixture(_ plan: InstallPlan, fixtures: URL, root: URL, fileOps: any FileOps = SystemFileOps()) async throws {
    let operation = try InstallOperation(plan: plan, installRoot: root,
        fetcher: ChunkFetcher(http: FileBackedHTTPClient(root: fixtures), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        fileOps: fileOps)
    let events = try await opCollect(operation.run())
    #expect(events.last == .phase(.completed))
}

func assertFixture(_ plan: InstallPlan, root: URL) throws {
    let fs = try ContainedFileSystem(root: root)
    for file in plan.files {
        let bytes = try fs.readFile(at: file.path, maxBytes: 1_000_000)
        var hash = StreamingHasher(file.digest.algorithm); hash.update(bytes)
        #expect(Int64(bytes.count) == file.size)
        #expect(hash.finalize() == file.digest)
    }
    #expect(try fs.itemType(at: SafeRelativePath("obsolete")) == nil)
    #expect(try fs.readFile(at: SafeRelativePath("keep"), maxBytes: 20) == Data("untouched".utf8))
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try fs.itemType(at: opDirectory(plan)) == nil)
    #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Data")).count == 2)
}
