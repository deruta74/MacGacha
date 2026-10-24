// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite(.serialized, .timeLimit(.minutes(1))) struct OperationRunnerTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func discardedPipelineRetainsStoreLeaseUntilWorkersJoin(cancelFirstWait: Bool) async throws {
        let root = try TempDir(), records = try TempDir(), cdn = MockCDN(), ops = BridgeBlockedAssembly()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let rootURL = root.url
        let store = GameRecordStore(directory: records.url)
        let runner = OperationRunner(store: store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max),
            log: nil, fileOps: ops)
        let released = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiting = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { ops.release() }
        try await OperationWork.$observer.withValue({
            if $0 == .stagingLeaseReleased { released.continuation.yield(()) }
            if $0 == .ownershipDrainWait { waiting.continuation.yield(()) }
        }) {
            let task = Task {
                for try await event in await runner.start("genshin", record: try bridgeRecord(rootURL), plan: plan,
                    kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))) {
                    if event == .fileVerified(plan.files[0].path) {
                        await ops.waitUntilBlocked()
                        return // Destroy the stream while another output write is still running.
                    }
                }
                Issue.record("Missing first file event")
            }
            try await task.value
            await #expect(throws: LauncherError.busy("another game operation is running")) {
                _ = try await store.acquireOperationLease()
            }
            if cancelFirstWait {
                let cancelled = Task { _ = try await runner.reconcile("genshin") }
                var firstWait = waiting.stream.makeAsyncIterator(); _ = await firstWait.next()
                cancelled.cancel()
                await #expect(throws: LauncherError.cancelled) { try await cancelled.value }
                // Cancelling one waiter cannot release another waiter's barrier.
            }
            let reconciliation = Task { _ = try await runner.reconcile("genshin") }
            defer { reconciliation.cancel() }
            var drainWait = waiting.stream.makeAsyncIterator(); _ = await drainWait.next()
            ops.release()
            try await reconciliation.value
            var iterator = released.stream.makeAsyncIterator(); _ = await iterator.next()
        }
        let lease = try await store.acquireOperationLease()
        withExtendedLifetime(lease) {}
        #expect(try await store.load("genshin")?.pending?.planDigest == plan.planDigest)
    }

    @Test func blockedCompletionCleanupDoesNotStarveCancellation() async throws {
        let root = try TempDir(), records = try TempDir(), cdn = MockCDN()
        let plan = try bridgePlan(), store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(root.url)
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await bridgeSave(record, store: store)
        try await store.savePlan(plan, for: "genshin")
        let fs = try ContainedFileSystem(root: root.url)
        let receipt = CompletionReceipt(planID: plan.id, planDigest: plan.planDigest)
        try fs.writeAtomically(JSONEncoder().encode(receipt), to: SafeRelativePath(".macgacha-receipts/\(plan.id).json"))
        try fs.writeAtomically(JSONEncoder().encode(plan), to: SafeRelativePath(".macgacha-staging/\(plan.id)/plan.json"))
        let gate = CompletionCleanupGate()
        let runner = OperationRunner(store: store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max), log: nil, fileOps: gate)
        let task = Task { try await runner.reconcile("genshin") }
        defer { gate.release.signal(); task.cancel() }
        var entered = gate.entered.stream.makeAsyncIterator(); _ = await entered.next()
        task.cancel(); gate.release.signal()
        await #expect(throws: LauncherError.cancelled) { _ = try await task.value }
        #expect(try await store.load("genshin") == record)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: plan.id) == receipt)
        #expect(try await bridgeRunner(store, cdn).reconcile("genshin")?.installed == bridgeBuild("new"))
        #expect(cdn.requestLog.isEmpty)
    }

    @Test func runnerCompletesAndAcknowledgesInOrder() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url)
        let runner = bridgeRunner(store, cdn)
        let record = try bridgeRecord(root.url)
        let events = try await bridgeCollect(await runner.start("genshin", record: record, plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
        #expect(events.filter { $0 == .phase(.completed) }.count == 1)
        let saved = try #require(try await store.load("genshin"))
        #expect(saved.installed == bridgeBuild("new")); #expect(saved.pending == nil)
        #expect(try await store.loadPlan(for: "genshin") == nil)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: plan.id) == nil)
        try await bridgeAssertTree(root.url, plan)
    }

    @Test func repairResumeKeepsOriginalPlan() async throws { try await exactResume(kind: .repair) }
    @Test func adoptResumeKeepsOriginalPlan() async throws { try await exactResume(kind: .adopt) }

    private func exactResume(kind: PendingOperation.Kind) async throws {
        for afterFirstBatch in [false, true] {
            let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
            let full = try bridgePlan(); let fs = try ContainedFileSystem(root: root.url)
            for file in full.files { try fs.writeAtomically(Data("bad!!".utf8), to: file.path) }
            let report = try await Verifier().verify(fs: fs, files: full.files.map(ManifestFile.init))
            let plan = try repairPlan(from: report, plan: full, id: full.id)
            bridgeServe(cdn, plan)
            let store = GameRecordStore(directory: records.url)
            var record = try bridgeRecord(root.url); if kind == .adopt { record.installed = nil; record.ownership = .adopted }
            let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 15)
            try await pauseBridge(await runner.start("genshin", record: record, plan: plan, kind: kind,
                target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))), plan: plan, fs: fs, afterFirstBatch: afterFirstBatch)
            let pending = try #require(try await store.load("genshin")?.pending)
            #expect(pending.planDigest == plan.planDigest)
            let journal = try OperationJournal.replay(fs: fs, path: SafeRelativePath(".macgacha-staging/\(plan.id)/journal.jsonl"))
            #expect(journal.committedFiles.count == (afterFirstBatch ? 1 : 0))
            if !afterFirstBatch { #expect(journal.commitStartedBatches.isEmpty) }
            let restarted = bridgeRunner(GameRecordStore(directory: records.url), cdn)
            #expect(try await restarted.reconcile("genshin")?.pending?.planDigest == plan.planDigest)
            #expect(try await store.loadPlan(for: "genshin")?.planDigest == plan.planDigest)
            let events = try await bridgeCollect(await restarted.resume("genshin", approved: true))
            #expect(events.last == .phase(.completed))
            try await bridgeAssertTree(root.url, full)
            #expect(try await store.load("genshin")?.installed == bridgeBuild("new"))
        }
    }

    @Test func resumeIgnoresNewerReleasedBuild() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url)
        let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 15)
        _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: false, managedPaths: Set(plan.files.map(\.path))))
        cdn.serve("getGameBranches", data: Data("newer released build".utf8))
        let newer = try bridgePlan(id: "newer", bodies: ["later", "later"]); bridgeServe(cdn, newer, bodies: ["later", "later"])
        let restarted = bridgeRunner(GameRecordStore(directory: records.url), cdn)
        _ = try await bridgeCollect(await restarted.resume("genshin", approved: true))
        #expect(try await store.load("genshin")?.installed == bridgeBuild("new"))
        #expect(cdn.requestLog.map(\.path).sorted() == ["bridge-0", "bridge-1"])
        try await bridgeAssertTree(root.url, plan)
    }

    @Test func approvalPairKeepsPending() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url)
        let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 15)
        let events = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: false, managedPaths: Set(plan.files.map(\.path))))
        #expect(events.last == .needsBatchApproval(required: SpaceBudget.margin + 20, available: SpaceBudget.margin + 15))
        #expect(try await store.load("genshin")?.pending?.planDigest == plan.planDigest)
        #expect(try await store.load("genshin")?.installed == bridgeBuild("old"))
        #expect(cdn.requestLog.isEmpty)
        #expect(try await bridgeCollect(await runner.resume("genshin", approved: true)).last == .phase(.completed))
    }

    @Test(arguments: [OperationPhase.checkingSpace, .staging, .committing, .cleaningUp])
    func cancelledStreamDoesNotMarkInstalled(at phase: OperationPhase) async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url); let runner = bridgeRunner(store, cdn)
        let rootURL = root.url
        let task = Task {
            for try await event in await runner.start("genshin", record: try bridgeRecord(rootURL), plan: plan,
                kind: .repair, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))) {
                if event == .phase(phase) { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await task.value }
        catch let error as LauncherError { #expect(error == .cancelled) }
        let record = try #require(try await store.load("genshin"))
        #expect(record.installed == bridgeBuild("old")); #expect(record.pending?.planDigest == plan.planDigest)
    }

    @Test func completedWithoutReceiptDoesNotMarkInstalled() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan); let rootURL = root.url
        let store = GameRecordStore(directory: records.url)
        let hooks = CrashHooks(at: .afterEngineCleanup, action: {
            try? CompletionReceipt.acknowledge(installRoot: rootURL, planID: plan.id)
        })
        let runner = bridgeRunner(store, cdn, hooks: hooks)
        await #expect(throws: LauncherError.journalCorrupt("Missing or mismatched completion receipt")) {
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(rootURL), plan: plan,
                kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
        }
        #expect(try await store.load("genshin")?.pending != nil)
        #expect(try await store.load("genshin")?.installed == bridgeBuild("old"))
    }

    @Test(arguments: ["/Volumes", "/System/Volumes/Data/Volumes"])
    func missingVolumeIsLocationUnavailable(prefix: String) async throws {
        let records = try TempDir(); let cdn = MockCDN(); let plan = try bridgePlan()
        let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(URL(fileURLWithPath: "\(prefix)/Task17-\(UUID().uuidString)/Game"),
            identity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 1))
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await store.savePlan(plan, for: "genshin"); try await bridgeSave(record, store: store)
        let runner = bridgeRunner(store, cdn)
        await #expect(throws: LauncherError.io("install location unavailable")) {
            _ = try await bridgeCollect(await runner.resume("genshin", approved: true))
        }
        #expect(try await store.load("genshin") == record); #expect(cdn.requestLog.isEmpty)
    }

    @Test func enospcLeavesResumableRecord() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url)
        let runner = OperationRunner(store: store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max),
            log: nil, fileOps: BridgeNoSpace())
        await #expect(throws: LauncherError.io("Cannot write file (errno 28)")) {
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
                kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
        }
        #expect(try await store.load("genshin")?.pending?.planDigest == plan.planDigest)
        let restarted = bridgeRunner(store, cdn)
        #expect(try await bridgeCollect(await restarted.resume("genshin", approved: true)).last == .phase(.completed))
    }

    @Test func crashBeforePendingDeletesOrphanPlan() async throws {
        let scenario = try await bridgeCrash(.afterGamePlanSaved)
        let store = scenario.store
        #expect(try await store.load("genshin")?.pending == nil)
        #expect(try await store.loadPlan(for: "genshin") != nil)
        let cdn = MockCDN(); let runner = bridgeRunner(store, cdn)
        _ = try await runner.reconcile("genshin")
        #expect(try await store.loadPlan(for: "genshin") == nil); #expect(cdn.requestLog.isEmpty)
    }

    @Test func interruptedReceiptWriteIsRecoverable() async throws {
        let scenario = try await bridgeCrash(.duringCompletionReceiptWrite)
        let fs = try ContainedFileSystem(root: scenario.root.url)
        let directory = try SafeRelativePath(".macgacha-receipts")
        #expect(try fs.contentsOfDirectory(at: directory).contains { $0.components.last?.hasPrefix(".macgacha-write-") == true })
        #expect(try CompletionReceipt.load(installRoot: scenario.root.url, planID: scenario.plan.id) == nil)
        let cdn = MockCDN(); let runner = bridgeRunner(scenario.store, cdn)
        #expect(try await runner.reconcile("genshin")?.pending?.planDigest == scenario.plan.planDigest)
        #expect(try await bridgeCollect(await runner.resume("genshin", approved: true)).last == .phase(.completed))
        #expect(try fs.contentsOfDirectory(at: directory).isEmpty)
        #expect(try await runner.reconcile("genshin")?.installed == bridgeBuild("new"))
        #expect(cdn.requestLog.isEmpty)
        try await bridgeAssertTree(scenario.root.url, scenario.plan)
    }

    @Test func crashBetweenPendingAndEngineStartsStoredPlan() async throws {
        let scenario = try await bridgeCrash(.afterGamePendingSaved)
        let fs = try ContainedFileSystem(root: scenario.root.url)
        #expect(try fs.itemType(at: SafeRelativePath(".macgacha-staging/bridge")) == nil)
        let cdn = MockCDN(); bridgeServe(cdn, scenario.plan)
        let runner = bridgeRunner(scenario.store, cdn)
        #expect(try await runner.reconcile("genshin")?.pending?.planDigest == scenario.plan.planDigest)
        #expect(try await bridgeCollect(await runner.resume("genshin", approved: true)).last == .phase(.completed))
        try await bridgeAssertTree(scenario.root.url, scenario.plan)
    }

    @Test(arguments: [CrashPoint.afterCompletionReceipt, .afterEngineCleanup])
    func crashAfterCompletionBeforeRecordReconcilesOffline(point: CrashPoint) async throws {
        let scenario = try await bridgeCrash(point)
        #expect(try await scenario.store.load("genshin")?.installed == bridgeBuild("old"))
        let cdn = MockCDN(); let runner = bridgeRunner(scenario.store, cdn)
        let record = try await runner.reconcile("genshin")
        #expect(record?.installed == bridgeBuild("new")); #expect(record?.pending == nil)
        #expect(cdn.requestLog.isEmpty)
        #expect(try CompletionReceipt.load(installRoot: scenario.root.url, planID: scenario.plan.id) == nil)
        #expect(try await scenario.store.loadPlan(for: "genshin") == nil)
        try await bridgeAssertTree(scenario.root.url, scenario.plan)
    }

    @Test(arguments: [CrashPoint.afterGameRecordSaved, .afterGamePlanDeleted, .afterReceiptAcknowledged])
    func crashAfterRecordBeforeAcknowledgeCleansReceipt(point: CrashPoint) async throws {
        let scenario = try await bridgeCrash(point)
        let cdn = MockCDN(); let runner = bridgeRunner(scenario.store, cdn)
        #expect(try await runner.reconcile("genshin")?.installed == bridgeBuild("new"))
        #expect(try await scenario.store.loadPlan(for: "genshin") == nil)
        #expect(try CompletionReceipt.load(installRoot: scenario.root.url, planID: scenario.plan.id) == nil)
        #expect(cdn.requestLog.isEmpty)
        try await bridgeAssertTree(scenario.root.url, scenario.plan)
    }

    @Test func completionNeverInfersManagedPathsFromAPartialPlan() async throws {
        let root = try TempDir(), records = try TempDir()
        let store = GameRecordStore(directory: records.url), record = try bridgeRecord(root.url)
        try await store.savePlan(bridgePlan(bodies: ["only-a"]), for: "genshin")
        await #expect(throws: LauncherError.journalCorrupt("missing managed paths")) {
            try await store.completeManagedPaths(record: record, for: "genshin")
        }
        #expect(try await store.readState("managed-paths.json", for: "genshin", maxBytes: 65_536) == nil)
    }

    @Test func uninstallingRecordIsLeftForUninstall() async throws {
        let root = try TempDir(); let records = try TempDir(); let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(root.url); record.uninstalling = true
        try await bridgeSave(record, store: store)
        #expect(try await bridgeRunner(store, MockCDN()).reconcile("genshin") == record)
    }

    @Test func receiptWithoutCompletedKeepsPendingUntilReconciliation() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url); let rootURL = root.url
        let runner = bridgeRunner(store, cdn, hooks: CrashHooks(at: .afterCompletionReceipt, action: {
            withUnsafeCurrentTask { $0?.cancel() }
        }))
        let events = Mutex<[OperationEvent]>([])
        let task = Task {
            for try await event in await runner.start("genshin", record: try bridgeRecord(rootURL), plan: plan,
                kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))) { events.withLock { $0.append(event) } }
        }
        do { try await task.value }
        catch let error as LauncherError { #expect(error == .cancelled) }
        #expect(!events.withLock { $0.contains(.phase(.completed)) })
        #expect(try await store.load("genshin")?.installed == bridgeBuild("old"))
        #expect(try await store.load("genshin")?.pending != nil)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: plan.id)?.planDigest == plan.planDigest)
        #expect(try await bridgeRunner(store, MockCDN()).reconcile("genshin")?.installed == bridgeBuild("new"))
    }

    @Test func pendingPlanIdentityMustMatchBeforeNetwork() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(root.url)
        record.pending = PendingOperation(kind: .repair, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await bridgeSave(record, store: store)
        for stored in [nil, try bridgePlan(bodies: ["other", "other"]) ] as [InstallPlan?] {
            if let stored { try await store.savePlan(stored, for: "genshin") }
            await #expect(throws: LauncherError.journalCorrupt("Missing or mismatched pending plan")) {
                _ = try await bridgeCollect(await bridgeRunner(store, cdn).resume("genshin", approved: true))
            }
            #expect(try await store.load("genshin") == record)
        }
        #expect(cdn.requestLog.isEmpty)
    }

    @Test func mismatchedReceiptCannotCompletePendingOperation() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); let other = try bridgePlan(bodies: ["other", "other"])
        let store = GameRecordStore(directory: records.url); var record = try bridgeRecord(root.url)
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await store.savePlan(plan, for: "genshin"); try await bridgeSave(record, store: store)
        let fs = try ContainedFileSystem(root: root.url)
        try fs.writeAtomically(JSONEncoder().encode(CompletionReceipt(planID: plan.id, planDigest: other.planDigest)),
            to: SafeRelativePath(".macgacha-receipts/\(plan.id).json"))
        let runner = bridgeRunner(store, cdn)
        await #expect(throws: LauncherError.journalCorrupt("Missing or mismatched completion receipt")) { _ = try await runner.reconcile("genshin") }
        await #expect(throws: LauncherError.journalCorrupt("Missing or mismatched completion receipt")) {
            _ = try await bridgeCollect(await runner.resume("genshin", approved: true))
        }
        #expect(try await store.load("genshin") == record); #expect(cdn.requestLog.isEmpty)
    }

    @Test func unrelatedReceiptIsAcknowledgedWhilePendingStays() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let old = try bridgePlan(id: "old"); bridgeServe(cdn, old)
        for try await _ in try InstallOperation(plan: old, installRoot: root.url, fetcher: bridgeFetcher(cdn), writesCompletionReceipt: true).run() {}
        let plan = try bridgePlan(); let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(root.url)
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await store.savePlan(plan, for: "genshin"); try await bridgeSave(record, store: store)
        let offline = MockCDN()
        #expect(try await bridgeRunner(store, offline).reconcile("genshin") == record)
        #expect(try CompletionReceipt.load(installRoot: root.url, planID: old.id) == nil)
        #expect(try await store.loadPlan(for: "genshin")?.planDigest == plan.planDigest)
        #expect(offline.requestLog.isEmpty)
    }

    @Test func insufficientSpaceWithoutApprovalEventStillThrows() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN(); let plan = try bridgePlan()
        let store = GameRecordStore(directory: records.url)
        let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin)
        await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + 15, available: SpaceBudget.margin)) {
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
                kind: .install, target: bridgeBuild("new"), approved: false, managedPaths: Set(plan.files.map(\.path))))
        }
        #expect(try await store.load("genshin")?.pending != nil); #expect(cdn.requestLog.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func cacheWriteProcessDeathReconcilesYoungAndOldTemporaries(existingRecord: Bool, old: Bool) async throws {
        let root = try TempDir(), records = try TempDir()
        let store = GameRecordStore(directory: records.url)
        if existingRecord { try await bridgeSave(bridgeRecord(root.url), store: store) }
        let harness = Bundle(for: BridgeBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        let result = try await SystemProcessRunner().run(harness, arguments: ["crash-cache-write", records.url.path], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
        let fs = try ContainedFileSystem(root: records.url), directory = try SafeRelativePath("genshin")
        let temporary = try #require(try fs.contentsOfDirectory(at: directory).first {
            $0.components.last!.hasPrefix(".macgacha-cache-write-")
        })
        #expect(try fs.size(at: temporary) == 20)
        let nested = try SafeRelativePath("genshin/manifests/.macgacha-cache-write-\(UUID().uuidString)")
        try fs.writeAtomically(Data("nested".utf8), to: nested)
        if old {
            for path in [temporary, nested] {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                    ofItemAtPath: path.resolved(against: records.url).path)
            }
        }
        // Both orphan and installed-record reconciliation must finish other
        // metadata retirement even when a young cache sibling remains.
        try await store.savePlan(bridgePlan(), for: "genshin")
        let reconciled = try await bridgeRunner(store, MockCDN()).reconcile("genshin")
        #expect(reconciled?.installed == (existingRecord ? bridgeBuild("old") : nil))
        #expect(try fs.itemType(at: temporary) == (old ? nil : .regularFile))
        #expect(try fs.itemType(at: nested) == (old ? nil : .regularFile))
        #expect(try await store.loadPlan(for: "genshin") == nil)
        #expect(try fs.itemType(at: directory) == ((!existingRecord && old) ? nil : .directory))
    }

    @Test(arguments: [false, true], [false, true])
    func launchWriteTemporariesAreAgedAndLiveSessionWritesAreNeverSwept(old: Bool, held: Bool) async throws {
        let records = try TempDir(), fs = try ContainedFileSystem(root: records.url)
        let path = try SafeRelativePath("genshin/.macgacha-launch-write-\(UUID().uuidString)")
        try fs.writeAtomically(Data("launch snapshot".utf8), to: path)
        if old {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                ofItemAtPath: path.resolved(against: records.url).path)
        }
        let lock = held ? try InstallLock(fs: fs, path: SafeRelativePath("genshin/.session.lock")) : nil
        defer { withExtendedLifetime(lock) {} }
        let store = GameRecordStore(directory: records.url)
        try await store.savePlan(bridgePlan(), for: "genshin")
        #expect(try await bridgeRunner(store, MockCDN()).reconcile("genshin") == nil)
        #expect(try await store.loadPlan(for: "genshin") == nil)
        #expect(try fs.itemType(at: path) == ((old && !held) ? nil : .regularFile))
    }

    @Test func gameOperationLeaseRetainsSessionLockUntilFinalOwnerReleasesIt() async throws {
        let records = try TempDir(), fs = try ContainedFileSystem(root: records.url)
        let path = try SafeRelativePath("genshin/.session.lock")
        let store = GameRecordStore(directory: records.url)
        var lease: GameOperationLease?
        do {
            let lock = try InstallLock(fs: fs, path: path)
            lease = try await store.acquireOperationLease(retainedGameLock: lock)
        }
        #expect(throws: LauncherError.busy("install root in use")) { try InstallLock(fs: fs, path: path) }
        withExtendedLifetime(lease) {}
        lease = nil
        let retry = try InstallLock(fs: fs, path: path)
        withExtendedLifetime(retry) {}
    }

    @Test func recordlessReconciliationKeepsSessionLockAndCleansOrphanPlan() async throws {
        let records = try TempDir(), fs = try ContainedFileSystem(root: records.url)
        let path = try SafeRelativePath("genshin/.session.lock")
        do {
            let lock = try InstallLock(fs: fs, path: path)
            withExtendedLifetime(lock) {}
        }
        let original = try fs.openForReading(at: path)
        defer { try? original.close() }
        var before = stat()
        try #require(fstat(original.fileDescriptor, &before) == 0)
        let store = GameRecordStore(directory: records.url)
        try await store.savePlan(bridgePlan(), for: "genshin")
        try await store.writeCacheState(Data("orphan cache".utf8), named: "branch.json", for: "genshin")
        #expect(try await bridgeRunner(store, MockCDN()).reconcile("genshin") == nil)
        #expect(try await store.loadPlan(for: "genshin") == nil)
        #expect(try fs.itemType(at: SafeRelativePath("genshin/branch.json")) == nil)
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("genshin")) == [path])
        let retained = try fs.openForReading(at: path)
        defer { try? retained.close() }
        var after = stat()
        try #require(fstat(retained.fileDescriptor, &after) == 0)
        #expect(after.st_dev == before.st_dev && after.st_ino == before.st_ino)
        let retry = try InstallLock(fs: fs, path: path)
        withExtendedLifetime(retry) {}
    }

    @Test(arguments: [false, true])
    func orphanReconciliationRejectsNonRegularSessionLock(symlink: Bool) async throws {
        let records = try TempDir(), fs = try ContainedFileSystem(root: records.url)
        let path = try SafeRelativePath("genshin/.session.lock")
        let store = GameRecordStore(directory: records.url)
        try await store.savePlan(bridgePlan(), for: "genshin")
        try fs.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("genshin/branch.json"))
        if symlink { try fs.createSymbolicLink(at: path, target: "branch.json") }
        else { try fs.createDirectory(at: path) }
        do {
            _ = try await bridgeRunner(store, MockCDN()).reconcile("genshin")
            Issue.record("Non-regular session lock was accepted")
        } catch LauncherError.unsafePath { #expect(symlink) }
        catch LauncherError.journalCorrupt(let message) {
            #expect(!symlink && message == "unexpected game metadata")
        }
        #expect(try await store.loadPlan(for: "genshin") != nil)
        #expect(try fs.readFile(at: SafeRelativePath("genshin/branch.json"), maxBytes: 100) == Data("untouched".utf8))
    }

    @Test func orphanRecoveryRejectsMalformedCacheTemporaryNames() async throws {
        let records = try TempDir(), fs = try ContainedFileSystem(root: records.url)
        let path = try SafeRelativePath("genshin/.macgacha-cache-write-\(UUID().uuidString)-foreign")
        try fs.writeAtomically(Data("keep".utf8), to: path)
        await #expect(throws: LauncherError.journalCorrupt("unexpected game metadata")) {
            _ = try await bridgeRunner(GameRecordStore(directory: records.url), MockCDN()).reconcile("genshin")
        }
        #expect(try fs.readFile(at: path, maxBytes: 4) == Data("keep".utf8))
    }

    @Test func existingRecordReclaimsInterruptedPlanWriteAfterProcessDeath() async throws {
        let scenario = try await bridgeCrash(.duringGamePlanWrite)
        let fs = try ContainedFileSystem(root: scenario.records.url)
        let directory = try SafeRelativePath("genshin")
        let before = try fs.contentsOfDirectory(at: directory)
        #expect(before.contains { $0.components.last!.hasPrefix(".macgacha-write-") })
        let unrelated = try SafeRelativePath("genshin/.macgacha-write-not-a-uuid")
        try fs.writeAtomically(Data("keep".utf8), to: unrelated)
        let runner = bridgeRunner(scenario.store, MockCDN())
        let record = try await runner.reconcile("genshin")
        #expect(record?.installed == bridgeBuild("old") && record?.pending == nil)
        let remaining = try fs.contentsOfDirectory(at: directory)
        #expect(!remaining.contains { UUID(uuidString: String($0.components.last!.dropFirst(".macgacha-write-".count))) != nil })
        #expect(try fs.readFile(at: unrelated, maxBytes: 4) == Data("keep".utf8))
        let cdn = MockCDN(); bridgeServe(cdn, scenario.plan)
        let events = try await bridgeCollect(await bridgeRunner(scenario.store, cdn).start("genshin", record: #require(record),
            plan: scenario.plan, kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(scenario.plan.files.map(\.path))))
        #expect(events.last == .phase(.completed))
    }

    @Test func anotherProcessCannotPrepareReconcileOrUninstallWhileStoreIsOwned() async throws {
        let root = try TempDir(), records = try TempDir(), signals = try TempDir(), cdn = MockCDN()
        let store = GameRecordStore(directory: records.url), record = try bridgeRecord(root.url)
        let plan = try bridgePlan()
        try await bridgeSave(record, store: store)
        try await store.savePlan(plan, for: "genshin")
        let ready = signals.url.appendingPathComponent("ready"), release = signals.url.appendingPathComponent("release")
        let harness = Bundle(for: BridgeBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
        let readyEvent = try FileAppearanceEvent(ready)
        let child = Task { try await SystemProcessRunner().run(harness,
            arguments: ["hold-game-store", records.url.path, ready.path, release.path], environment: [:], currentDirectory: nil) }
        defer { try? Data().write(to: release) }
        try await readyEvent.wait()
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let runner = bridgeRunner(store, cdn)
        await #expect(throws: LauncherError.busy("another game operation is running")) {
            _ = try await bridgeCollect(await runner.start("genshin", record: record, plan: bridgePlan(id: "contender"),
                kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
        }
        await #expect(throws: LauncherError.busy("another game operation is running")) { _ = try await runner.reconcile("genshin") }
        let library = GameLibrary(paths: AppPaths(root: signals.url), api: Sophon.DeliveryAPI(http: cdn), runner: runner,
            store: store, disk: FixedDiskSpace(bytes: Int64.max), log: nil)
        await #expect(throws: LauncherError.busy("another game operation is running")) { try await library.uninstall(GameDefinition.all[0]) }
        #expect(try await store.load("genshin") == record)
        #expect(try await store.loadPlan(for: "genshin")?.planDigest == plan.planDigest)
        #expect(cdn.requestLog.isEmpty)
        try Data().write(to: release)
        #expect(try await child.value.exitCode == 0)
        let lease = try await store.acquireOperationLease()
        withExtendedLifetime(lease) {}
    }

    @Test(arguments: [false, true])
    func concurrentRunnersKeepRecordAndPlanConsistent(separateStores: Bool) async throws {
        for _ in 0..<20 {
            let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
            let store = GameRecordStore(directory: records.url)
            let other = separateStores ? GameRecordStore(directory: records.url) : store
            let a = try bridgePlan(id: "race-a"), b = try bridgePlan(id: "race-b")
            let record = try bridgeRecord(root.url)
            let first = BridgeReader(await bridgeRunner(store, cdn).start("genshin", record: record, plan: a,
                kind: .install, target: bridgeBuild("new"), approved: true, managedPaths: Set(a.files.map(\.path))))
            let second = BridgeReader(await bridgeRunner(other, cdn).start("genshin", record: record, plan: b,
                kind: .install, target: bridgeBuild("new"), approved: true, managedPaths: Set(b.files.map(\.path))))
            async let left = first.next(); async let right = second.next()
            let results = await [left, right]
            #expect(results.filter { if case .failure(.busy) = $0 { true } else { false } }.count == 1, "\(results)")
            let saved = try #require(try await store.load("genshin"))
            let pending = try #require(saved.pending)
            #expect(try await store.loadPlan(for: "genshin")?.planDigest == pending.planDigest)
            for (index, result) in results.enumerated() {
                if case .success(.some(.phase(.checkingSpace))) = result {
                    #expect(pending.planID == (index == 0 ? a.id : b.id))
                }
            }
            await first.discard(); await second.discard()
        }
    }

    @Test func storeLeaseSharesIdentityButAllowsIndependentDirectories() async throws {
        let parent = try TempDir(); let independent = try TempDir()
        let real = parent.url.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = parent.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = GameRecordStore(directory: real.appendingPathComponent("Games"))
        let other = GameRecordStore(directory: alias.appendingPathComponent("Games"))
        let lease = try await store.acquireOperationLease()
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: LauncherError.busy("another game operation is running")) {
            _ = try await other.acquireOperationLease()
        }
        let separate = try await GameRecordStore(directory: independent.url).acquireOperationLease()
        withExtendedLifetime(separate) {}
    }

    @Test(arguments: [false, true], [false, true])
    func resumeRefusesAnotherStagingPlanBeforeMutation(sameID: Bool, committed: Bool) async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); let other = try bridgePlan(id: sameID ? "bridge" : "other", bodies: ["other", "other"])
        bridgeServe(cdn, plan); bridgeServe(cdn, other, bodies: ["other", "other"])
        let fs = try ContainedFileSystem(root: root.url)
        try fs.writeAtomically(Data("original".utf8), to: SafeRelativePath("a"))
        let directory = ".macgacha-staging/\(other.id)"
        try fs.writeAtomically(JSONEncoder().encode(other), to: SafeRelativePath("\(directory)/plan.json"))
        let journalPath = try SafeRelativePath("\(directory)/journal.jsonl")
        let journal = try OperationJournal(fs: fs, path: journalPath)
        try await journal.append(.planStored(planID: other.id, planDigest: other.planDigest)); try await journal.append(.operationStarted)
        for file in other.files {
            try fs.writeAtomically(Data("other".utf8), to: SafeRelativePath("\(directory)/files/\(file.path)"))
            try await journal.append(.fileStaged(path: file.path))
        }
        if committed {
            try await journal.append(.batchStarted(index: 0)); try await journal.append(.commitStarted(batch: 0))
            try InstallStateMarker(planID: other.id).write(fs: fs)
        }
        // Discovery must neither repair this tail nor remove an earlier orphan.
        try fs.append(Data("{torn".utf8), to: journalPath)
        let before = try fs.readFile(at: journalPath, maxBytes: 65_536)
        let orphan = try SafeRelativePath(".macgacha-staging/aaa-orphan/retained")
        try fs.writeAtomically(Data("keep".utf8), to: orphan)
        let store = GameRecordStore(directory: records.url); var record = try bridgeRecord(root.url)
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await store.savePlan(plan, for: "genshin"); try await bridgeSave(record, store: store)
        await #expect(throws: LauncherError.journalCorrupt("staging holds another plan")) {
            _ = try await bridgeCollect(await bridgeRunner(store, cdn).resume("genshin", approved: true))
        }
        #expect(try await store.load("genshin") == record)
        #expect(try await store.loadPlan(for: "genshin")?.planDigest == plan.planDigest)
        #expect(try fs.readFile(at: journalPath, maxBytes: 65_536) == before)
        #expect(try fs.readFile(at: orphan, maxBytes: 10) == Data("keep".utf8))
        #expect(try fs.readFile(at: SafeRelativePath("a"), maxBytes: 20) == Data("original".utf8))
        #expect(try InstallStateMarker.load(fs: fs)?.planID == (committed ? other.id : nil))
        #expect(cdn.requestLog.isEmpty)
    }

    @Test(arguments: [false, true])
    func missingInstallRootIsDurableBeforePending(failSync: Bool) async throws {
        let parent = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let root = parent.url.appendingPathComponent("NewGame")
        var info = stat(); #expect(stat(parent.url.path, &info) == 0)
        let identity = "\(info.st_dev):\(info.st_ino)"
        let ops = BridgeRootOps(failing: failSync ? identity : nil)
        let plan = try bridgePlan(); bridgeServe(cdn, plan); let store = GameRecordStore(directory: records.url)
        let runner = OperationRunner(store: store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max), log: nil,
            crashHooks: CrashHooks(at: .afterGamePendingSaved, action: { ops.events.withLock { $0.append("pending") } }), fileOps: ops)
        if failSync {
            await #expect(throws: LauncherError.io("injected root parent sync failure")) {
                _ = try await bridgeCollect(await runner.startInstall("genshin", at: root, executable: SafeRelativePath("a"), plan: plan, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
            }
            #expect(try await store.load("genshin") == nil)
            #expect(cdn.requestLog.isEmpty)
        } else {
            _ = try await bridgeCollect(await runner.startInstall("genshin", at: root, executable: SafeRelativePath("a"), plan: plan, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
            let events = ops.events.withLock { $0 }
            let sync = try #require(events.firstIndex(of: identity)), pending = try #require(events.firstIndex(of: "pending"))
            #expect(sync < pending)
            try await bridgeAssertTree(root, plan)
        }
    }

    @Test(arguments: ["online", "reconcile", "resume"])
    func completionLogUsesApprovedFieldsOnEveryPath(path: String) async throws {
        let logs = try TempDir(); let log = EventLog(directory: logs.url)
        if path == "online" {
            let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN(); let plan = try bridgePlan(); bridgeServe(cdn, plan)
            let runner = OperationRunner(store: GameRecordStore(directory: records.url), fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max), log: log)
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
                kind: .update, target: bridgeBuild("new"), approved: true, managedPaths: Set(plan.files.map(\.path))))
        } else {
            let scenario = try await bridgeCrash(.afterEngineCleanup); let cdn = MockCDN()
            let runner = OperationRunner(store: scenario.store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: Int64.max), log: log)
            if path == "reconcile" { _ = try await runner.reconcile("genshin") }
            else { _ = try await bridgeCollect(await runner.resume("genshin", approved: true)) }
            #expect(cdn.requestLog.isEmpty)
        }
        let fs = try ContainedFileSystem(root: logs.url)
        let bytes = try fs.readFile(at: SafeRelativePath("macgacha.log"), maxBytes: 65_536)
        let entries = try bytes.split(separator: 10).map { try JSONDecoder().decode(EventLog.Record.self, from: Data($0)) }
        let completed = entries.filter { $0.message == "Operation completed" }
        #expect(completed.count == 1)
        #expect(completed.first?.metadata == ["game": "genshin", "tag": "new", "build_id": "build-new"])
    }
}

private actor BridgeReader {
    private var iterator: AsyncThrowingStream<OperationEvent, any Error>.Iterator?
    init(_ stream: AsyncThrowingStream<OperationEvent, any Error>) { iterator = stream.makeAsyncIterator() }
    func next() async -> Result<OperationEvent?, LauncherError> {
        guard var current = iterator else { return .success(nil) }
        iterator = nil
        do {
            let event = try await current.next(isolation: self); iterator = current
            return .success(event)
        } catch { return .failure((error as? LauncherError) ?? .io("unexpected error")) }
    }
    func discard() { iterator = nil }
}

private final class BridgeRootOps: FileOps, Sendable {
    let events = Mutex<[String]>([])
    let failing: String?
    init(failing: String?) { self.failing = failing }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var info = stat(); guard fstat(descriptor, &info) == 0 else { throw LauncherError.io("fstat failed") }
        if info.st_mode & S_IFMT == S_IFDIR {
            let identity = "\(info.st_dev):\(info.st_ino)"; events.withLock { $0.append(identity) }
            if identity == failing { throw LauncherError.io("injected root parent sync failure") }
        }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

private func bridgeBuild(_ tag: String) -> InstalledBuild {
    InstalledBuild(tag: tag, buildID: "build-\(tag)", categories: [], voices: ["en-us"])
}
/// The fixture build owns a and b; saved pending/receipt scenarios must model
/// the same complete ownership metadata as a real runner start.
private func bridgeSave(_ record: GameRecord, store: GameRecordStore) async throws {
    let paths = try Set(["a", "b"].map(SafeRelativePath.init))
    if let installed = record.installed { try await store.prepareManagedPaths(paths, target: installed, record: record, for: "genshin") }
    if let pending = record.pending { try await store.prepareManagedPaths(paths, target: pending.target, record: record, for: "genshin") }
    try await store.save(record, for: "genshin")
}
private func bridgeRecord(_ root: URL, identity: FileSystemIdentity? = nil) throws -> GameRecord {
    if let identity { return GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("a"), installed: bridgeBuild("old"), installIdentity: identity) }
    let fs = try ContainedFileSystem(root: root)
    try fs.createRootDurably()
    return GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("a"), installed: bridgeBuild("old"), installIdentity: try fs.rootIdentity())
}
private func bridgeHash(_ data: Data) -> Digest { var h = StreamingHasher(.md5); h.update(data); return h.finalize() }
private func bridgePlan(id: String = "bridge", bodies: [String] = ["new-a", "new-b"]) throws -> InstallPlan {
    var objects: [String: ChunkObject] = [:]; var files: [FileTask] = []
    for (index, body) in bodies.enumerated() {
        let name = "\(id)-\(index)"; let data = Data(body.utf8); let digest = bridgeHash(data)
        objects[name] = ChunkObject(id: name, urls: [URL(string: "https://cdn.hoyoverse.com/\(name)")!],
            transferSize: Int64(data.count), transferDigest: digest, decodedSize: Int64(data.count), decodedDigest: digest)
        files.append(FileTask(path: try SafeRelativePath(index == 0 ? "a" : "b"), size: Int64(data.count), digest: digest,
            extents: [Extent(source: .chunk(id: name), fileOffset: 0, length: Int64(data.count), digest: digest)]))
    }
    return InstallPlan(id: try SafeIdentifier(id), objects: objects, files: files)
}
private func bridgeServe(_ cdn: MockCDN, _ plan: InstallPlan, bodies: [String] = ["new-a", "new-b"]) {
    for (index, body) in bodies.enumerated() { cdn.serve("\(plan.id)-\(index)", data: Data(body.utf8)) }
}
private func bridgeFetcher(_ cdn: MockCDN) -> ChunkFetcher {
    ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper())
}
private func bridgeRunner(_ store: GameRecordStore, _ cdn: MockCDN, bytes: Int64 = Int64.max, hooks: CrashHooks = .none) -> OperationRunner {
    OperationRunner(store: store, fetcher: bridgeFetcher(cdn), disk: FixedDiskSpace(bytes: bytes), log: nil, crashHooks: hooks)
}
private func bridgeCollect(_ stream: AsyncThrowingStream<OperationEvent, any Error>) async throws -> [OperationEvent] {
    var events: [OperationEvent] = []; for try await event in stream { events.append(event) }; return events
}
private func pauseBridge(_ stream: AsyncThrowingStream<OperationEvent, any Error>, plan: InstallPlan,
    fs: ContainedFileSystem, afterFirstBatch: Bool) async throws {
    for try await event in stream {
        if !afterFirstBatch, case .fileVerified = event { return }
        if afterFirstBatch, event == .phase(.checkingSpace) {
            let state = try OperationJournal.replay(fs: fs, path: SafeRelativePath(".macgacha-staging/\(plan.id)/journal.jsonl"))
            if state.committedFiles.count == 1 { return }
        }
    }
    Issue.record("Operation did not pause at the requested boundary")
}
private func bridgeAssertTree(_ root: URL, _ plan: InstallPlan) async throws {
    let fs = try ContainedFileSystem(root: root)
    #expect(try InstallStateMarker.load(fs: fs) == nil)
    #expect(try await Verifier().verify(fs: fs, files: plan.files.map(ManifestFile.init)).isClean)
}

private struct BridgeCrashScenario: ~Copyable {
    let fixtures: TempDir; let root: TempDir; let records: TempDir; let plan: InstallPlan
    var store: GameRecordStore { GameRecordStore(directory: records.url) }
}
private final class BridgeBundleToken: NSObject {}
private func bridgeCrash(_ point: CrashPoint) async throws -> BridgeCrashScenario {
    let scenario = BridgeCrashScenario(fixtures: try TempDir(), root: try TempDir(), records: try TempDir(), plan: try bridgePlan())
    let fs = try ContainedFileSystem(root: scenario.fixtures.url)
    try fs.writeAtomically(JSONEncoder().encode(scenario.plan), to: SafeRelativePath("plan.json"))
    try fs.writeAtomically(JSONEncoder().encode(bridgeRecord(scenario.root.url)), to: SafeRelativePath("record.json"))
    try fs.writeAtomically(JSONEncoder().encode(bridgeBuild("new")), to: SafeRelativePath("target.json"))
    for (index, body) in ["new-a", "new-b"].enumerated() {
        try fs.writeAtomically(Data(body.utf8), to: SafeRelativePath("bridge-\(index)"))
    }
    try await bridgeSave(bridgeRecord(scenario.root.url), store: scenario.store)
    let bundle = Bundle(for: BridgeBundleToken.self).bundleURL
    guard bundle.pathExtension == "xctest" else { throw LauncherError.io("Cannot locate current test products") }
    let harness = bundle.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    guard FileManager.default.isExecutableFile(atPath: harness.path) else { throw LauncherError.io("Missing CrashHarness beside current tests") }
    let arguments = [scenario.fixtures.url.path, scenario.root.url.path, point.rawValue, scenario.records.url.path, "update"]
    let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
        group.addTask { try await SystemProcessRunner().run(harness, arguments: arguments, environment: [:], currentDirectory: nil) }
        group.addTask { try await Task.sleep(for: .seconds(60)); throw LauncherError.io("Crash harness deadline") }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw LauncherError.io("No crash harness result") }
        return result
    }
    #expect(result.exitCode == 137, "\(String(decoding: result.stderr, as: UTF8.self))")
    return scenario
}
private struct BridgeNoSpace: FileOps {
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { throw LauncherError.io("Cannot write file (errno 28)") }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

private final class BridgeBlockedAssembly: FileOps {
    private let gate = DispatchSemaphore(value: 0)
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let didBlock = Mutex(false)
    func release() { gate.signal() }
    func waitUntilBlocked() async { var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next() }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(descriptor, F_GETPATH, &path) == 0,
            String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("/files/b"),
            didBlock.withLock({ if $0 { return false }; $0 = true; return true }) {
            entered.continuation.yield(())
            guard gate.wait(timeout: .now() + 60) == .success else { throw LauncherError.io("Blocked assembly deadline") }
        }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

private final class CompletionCleanupGate: FileOps {
    let release = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try SystemFileOps().synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if name == "plan.json" {
            entered.continuation.yield(())
            guard release.wait(timeout: .now() + 60) == .success else { throw LauncherError.io("completion cleanup deadline") }
        }
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
