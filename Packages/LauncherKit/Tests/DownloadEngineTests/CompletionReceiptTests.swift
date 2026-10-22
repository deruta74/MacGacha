// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1))) struct CompletionReceiptTests {
    @Test(.timeLimit(.minutes(1)), arguments: [CrashPoint.afterOperationCompleted, .afterCompletionReceipt, .afterEngineCleanup])
    func receiptWrittenBeforeCleanup(point: CrashPoint) async throws {
        let fixtures = try TempDir(); let root = try TempDir()
        let plan = try crashFixture(fixtures.url, root: root.url)
        let harness = try crashHarnessURL(in: Bundle(for: ReceiptBundleToken.self).bundleURL)
        let result = try await SystemProcessRunner().run(harness,
            arguments: [fixtures.url.path, root.url.path, point.rawValue], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
        let receipt = try CompletionReceipt.load(installRoot: root.url, planID: plan.id)
        if point == .afterOperationCompleted { #expect(receipt == nil) }
        else { #expect(receipt?.planDigest == plan.planDigest) }
        let fs = try ContainedFileSystem(root: root.url)
        #expect((try fs.itemType(at: opDirectory(plan)) == nil) == (point == .afterEngineCleanup))
        let cdn = MockCDN()
        // Replaying a completed journal must create a missing receipt before cleanup.
        if point != .afterEngineCleanup {
            let operation = try InstallOperation(plan: plan, installRoot: root.url,
                fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), writesCompletionReceipt: true)
            #expect(try await opCollect(operation.run()).last == .phase(.completed))
        }
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: plan.id)?.planDigest == plan.planDigest)
        #expect(cdn.requestLog.isEmpty)
        try assertFixture(plan, root: root.url)
    }

    @Test(.timeLimit(.minutes(1))) func discoveryKeepsReceipts() async throws {
        let root = try TempDir(); let cdn = MockCDN()
        let first = try opPlan("receipt-first", [("a", "first")])
        opServe(cdn, first, ["first"])
        _ = try await opCollect(InstallOperation(plan: first, installRoot: root.url,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), writesCompletionReceipt: true).run())
        let next = try opPlan("receipt-next", [("b", "next")]); opServe(cdn, next, ["next"])
        _ = try await opCollect(opEngine(next, root.url, cdn).run())
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: first.id)?.planDigest == first.planDigest)
        try CompletionReceipt.acknowledge(installRoot: root.url, planID: first.id)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: first.id) == nil)
    }

    @Test func receiptPathReservedInPlans() throws {
        for name in [".macgacha-receipts/a.json", ".MACGACHA-RECEIPTS/a.json"] {
            let path = try SafeRelativePath(name)
            let file = FileTask(path: path, size: 0, digest: opDigest(""), extents: [])
            #expect(throws: LauncherError.unsafePath(name)) {
                try InstallPlan(id: SafeIdentifier("reserved"), objects: [:], files: [file]).validate()
            }
            #expect(throws: LauncherError.unsafePath(name)) {
                try InstallPlan(id: SafeIdentifier("reserved"), objects: [:], files: [], deletions: [path]).validate()
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func noReceiptByDefault() async throws {
        let root = try TempDir(); let cdn = MockCDN(); let plan = try opPlan("runtime", [("a", "abc")])
        opServe(cdn, plan, ["abc"])
        _ = try await opCollect(opEngine(plan, root.url, cdn).run())
        let fs = try ContainedFileSystem(root: root.url)
        #expect(try fs.itemType(at: SafeRelativePath(".macgacha-receipts")) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func receiptIsOnlyWrittenForRequestedPlan() async throws {
        let root = try TempDir(); let cdn = MockCDN(); let fs = try ContainedFileSystem(root: root.url)
        let old = try opPlan("previous", [("a", "old")]), requested = try opPlan("requested", [("a", "new")])
        _ = try await opSeed(fs, old, commit: true)
        try fs.writeAtomically(Data("old".utf8), to: opStaged(old, old.files[0].path))
        opServe(cdn, requested, ["new"])
        let operation = try InstallOperation(plan: requested, installRoot: root.url,
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), writesCompletionReceipt: true)
        #expect(try await opCollect(operation.run()).last == .phase(.completed))
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: old.id) == nil)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: requested.id)?.planDigest == requested.planDigest)
    }
}

private final class ReceiptBundleToken: NSObject {}
