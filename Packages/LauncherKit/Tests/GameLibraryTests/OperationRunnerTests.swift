// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import GameLibrary

@Suite(.serialized) struct OperationRunnerTests {
    @Test func runnerCompletesAndAcknowledgesInOrder() async throws {
        let root = try TempDir(); let records = try TempDir(); let cdn = MockCDN()
        let plan = try bridgePlan(); bridgeServe(cdn, plan)
        let store = GameRecordStore(directory: records.url)
        let runner = bridgeRunner(store, cdn)
        let record = try bridgeRecord(root.url)
        let events = try await bridgeCollect(await runner.start("genshin", record: record, plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: true))
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
            let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 10)
            try await pauseBridge(await runner.start("genshin", record: record, plan: plan, kind: kind,
                target: bridgeBuild("new"), approved: true), plan: plan, fs: fs, afterFirstBatch: afterFirstBatch)
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
        let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 10)
        _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: false))
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
        let runner = bridgeRunner(store, cdn, bytes: SpaceBudget.margin + 10)
        let events = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
            kind: .update, target: bridgeBuild("new"), approved: false))
        #expect(events.last == .needsBatchApproval(required: SpaceBudget.margin + 20, available: SpaceBudget.margin + 10))
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
                kind: .repair, target: bridgeBuild("new"), approved: true) {
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
                kind: .update, target: bridgeBuild("new"), approved: true))
        }
        #expect(try await store.load("genshin")?.pending != nil)
        #expect(try await store.load("genshin")?.installed == bridgeBuild("old"))
    }

    @Test(arguments: ["/Volumes", "/System/Volumes/Data/Volumes"])
    func missingVolumeIsLocationUnavailable(prefix: String) async throws {
        let records = try TempDir(); let cdn = MockCDN(); let plan = try bridgePlan()
        let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(URL(fileURLWithPath: "\(prefix)/Task17-\(UUID().uuidString)/Game"))
        record.pending = PendingOperation(kind: .update, planID: plan.id, planDigest: plan.planDigest, target: bridgeBuild("new"))
        try await store.savePlan(plan, for: "genshin"); try await store.save(record, for: "genshin")
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
                kind: .update, target: bridgeBuild("new"), approved: true))
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

    @Test func uninstallingRecordIsLeftForUninstall() async throws {
        let root = try TempDir(); let records = try TempDir(); let store = GameRecordStore(directory: records.url)
        var record = try bridgeRecord(root.url); record.uninstalling = true
        try await store.save(record, for: "genshin")
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
                kind: .update, target: bridgeBuild("new"), approved: true) { events.withLock { $0.append(event) } }
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
        try await store.save(record, for: "genshin")
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
        try await store.savePlan(plan, for: "genshin"); try await store.save(record, for: "genshin")
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
        try await store.savePlan(plan, for: "genshin"); try await store.save(record, for: "genshin")
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
        await #expect(throws: LauncherError.insufficientSpace(required: SpaceBudget.margin + 20, available: SpaceBudget.margin)) {
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root.url), plan: plan,
                kind: .install, target: bridgeBuild("new"), approved: false))
        }
        #expect(try await store.load("genshin")?.pending != nil); #expect(cdn.requestLog.isEmpty)
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
                kind: .install, target: bridgeBuild("new"), approved: true))
            let second = BridgeReader(await bridgeRunner(other, cdn).start("genshin", record: record, plan: b,
                kind: .install, target: bridgeBuild("new"), approved: true))
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
        try await store.savePlan(plan, for: "genshin"); try await store.save(record, for: "genshin")
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
                _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root), plan: plan,
                    kind: .install, target: bridgeBuild("new"), approved: true))
            }
            #expect(try await store.load("genshin") == nil)
            #expect(cdn.requestLog.isEmpty)
        } else {
            _ = try await bridgeCollect(await runner.start("genshin", record: bridgeRecord(root), plan: plan,
                kind: .install, target: bridgeBuild("new"), approved: true))
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
                kind: .update, target: bridgeBuild("new"), approved: true))
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
private func bridgeRecord(_ root: URL) throws -> GameRecord {
    GameRecord(installPath: root, ownership: .created, executable: try SafeRelativePath("a"), installed: bridgeBuild("old"))
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
    try await scenario.store.save(bridgeRecord(scenario.root.url), for: "genshin")
    let bundle = Bundle(for: BridgeBundleToken.self).bundleURL
    guard bundle.pathExtension == "xctest" else { throw LauncherError.io("Cannot locate current test products") }
    let harness = bundle.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    guard FileManager.default.isExecutableFile(atPath: harness.path) else { throw LauncherError.io("Missing CrashHarness beside current tests") }
    let arguments = [scenario.fixtures.url.path, scenario.root.url.path, point.rawValue, scenario.records.url.path, "update"]
    let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
        group.addTask { try await SystemProcessRunner().run(harness, arguments: arguments, environment: [:], currentDirectory: nil) }
        group.addTask { try await Task.sleep(for: .seconds(15)); throw LauncherError.io("Crash harness deadline") }
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
