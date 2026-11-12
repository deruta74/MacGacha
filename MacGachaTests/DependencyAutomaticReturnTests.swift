// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

@Suite(.timeLimit(.minutes(1))) @MainActor struct DependencyAutomaticReturnTests {
    @Test(arguments: ReturnFamily.allCases, [false, true])
    func returningToAutomaticRetainsUntilQualifiedAndKeepsSharedComponents(family: ReturnFamily, needsSetup: Bool) async throws {
        let f = try await AutomaticReturnFixture.make(family, targetInstalled: !needsSetup)
        let shared = try InstalledComponent(kind: family == .dxmt ? .dxmt : .d3dmetal,
            version: family == .dxmt ? "0.80" : "4.0b3", installedAt: .now, source: .download)
        f.base.services.state.withLock { $0.components.append(shared) }
        try await f.base.model.scanAndApply()
        var events = f.base.services.installEvents.stream.makeAsyncIterator()
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        if needsSetup {
            #expect(await events.next() == f.target)
            #expect(try await f.records().isEmpty)
            try f.publish(f.target)
            f.base.services.emit(.phase(.completed))
        }
        try await waitForCatalogModel { f.base.model.runtimeCatalogMutationID == nil }
        #expect(f.base.model.runtimeIsSelected(f.target))
        #expect(!f.base.model.runtimeIsPinned(f.target))
        let record = try #require(try await f.records().only)
        #expect(record.familyID == f.familyID && record.previousID == f.previous && record.replacementID == f.target)
        #expect(!record.verified)
        // The state names the version that will be removed, which the panel shows as "Kept for now".
        #expect(f.base.model.dependencyAutoUpdate(for: f.familyID) == .keepingPrevious(id: f.previous))
        try await f.qualify(seconds: 119)
        await f.cleanup()
        #expect(f.isInstalled(f.previous))
        #expect(try await f.records().only?.verified == false)
        try await f.qualify(seconds: 120)
        await f.cleanup()
        #expect(!f.isInstalled(f.previous))
        #expect(f.isInstalled(f.target))
        #expect(f.base.services.snapshot.components.contains(shared))
        #expect(try await f.records().isEmpty)
    }

    @Test(arguments: ReturnFamily.allCases, [false, true])
    func failedOrCancelledSetupCreatesNoReplacement(family: ReturnFamily, cancel: Bool) async throws {
        let f = try await AutomaticReturnFixture.make(family, targetInstalled: false)
        var events = f.base.services.installEvents.stream.makeAsyncIterator()
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        #expect(await events.next() == f.target)
        if cancel {
            try f.publish(f.target)
            f.base.model.cancel(f.target)
            f.base.services.emit(.phase(.completed))
        } else { f.base.services.emit(.failed(.io("Synthetic install failure"))) }
        try await waitForCatalogModel { f.base.model.runtimeCatalogMutationID == nil }
        #expect(f.base.model.runtimeIsSelected(f.previous))
        #expect(f.base.model.runtimeIsPinned(f.previous))
        #expect(try await f.records().isEmpty)
    }

    @Test(arguments: ReturnFamily.allCases, ["success", "before", "after"])
    func replacementFollowsSuccessfulDurableActivation(family: ReturnFamily, failure: String) async throws {
        let bytes = Mutex<Data?>(nil), armed = Mutex(false), emptyAtPublication = Mutex<Bool?>(nil)
        let f = try await AutomaticReturnFixture.make(family, storeFactory: { paths in
            RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
                if armed.withLock({ value in let wasArmed = value; value = false; return wasArmed }) {
                    let empty = try RuntimeAutomaticUpdateStore(paths: paths).load().replacements.isEmpty
                    emptyAtPublication.withLock { $0 = empty }
                    if failure == "before" { throw LauncherError.io("Synthetic failure before publication") }
                    bytes.withLock { $0 = data }
                    if failure == "after" { throw LauncherError.io("Synthetic failure after publication") }
                } else { bytes.withLock { $0 = data } }
            })
        })
        armed.withLock { $0 = true }
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        await f.base.model.catalogMutationTask?.value
        #expect(emptyAtPublication.withLock { $0 } == true)
        #expect(f.base.model.runtimeIsSelected(failure == "before" ? f.previous : f.target))
        if failure == "success" {
            #expect(try await f.records().count == 1)
        } else {
            #expect(f.base.model.lastError != nil)
            #expect(try await f.records().isEmpty)
        }
        #expect(f.isInstalled(f.previous))
    }

    @Test(arguments: ReturnFamily.allCases)
    func repinningCancelsCleanupAndAnotherReturnStartsANewTrial(family: ReturnFamily) async throws {
        let f = try await AutomaticReturnFixture.make(family)
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        await f.base.model.catalogMutationTask?.value
        let first = try #require(try await f.records().only)
        try await f.qualify(seconds: 120)
        f.base.model.useRuntimeVersion(f.previous, pinned: true)
        await f.base.model.catalogMutationTask?.value
        #expect(try await f.records().isEmpty)
        await f.cleanup()
        #expect(f.isInstalled(f.previous))
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        await f.base.model.catalogMutationTask?.value
        let next = try #require(try await f.records().only)
        #expect(next.id != first.id && !next.verified)
    }

    @Test(arguments: ReturnFamily.allCases)
    func unpinningTheSameRecommendedVersionCreatesNoReplacement(family: ReturnFamily) async throws {
        let f = try await AutomaticReturnFixture.make(family)
        f.base.model.useRuntimeVersion(f.target, pinned: true)
        await f.base.model.catalogMutationTask?.value
        #expect(f.base.model.runtimeIsPinned(f.target))
        f.base.model.useRuntimeVersion(f.target)
        await f.base.model.catalogMutationTask?.value
        #expect(!f.base.model.runtimeIsPinned(f.target))
        #expect(try await f.records().isEmpty)
    }

    @Test(arguments: ReturnFamily.allCases)
    func missingPreviousInstallationCreatesNoReplacement(family: ReturnFamily) async throws {
        let f = try await AutomaticReturnFixture.make(family)
        f.removeReceipt(f.previous)
        try await f.base.model.scanAndApply()
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        await f.base.model.catalogMutationTask?.value
        #expect(f.base.model.runtimeIsSelected(f.target))
        #expect(try await f.records().isEmpty)
    }

    @Test(arguments: ReturnFamily.allCases)
    func cancellationDuringPostPublicationScanCreatesNoReplacement(family: ReturnFamily) async throws {
        let bytes = Mutex<Data?>(nil), armed = Mutex(false), services = Mutex<FakeRuntimeServices?>(nil)
        let f = try await AutomaticReturnFixture.make(family, storeFactory: { _ in
            RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
                bytes.withLock { $0 = data }
                if armed.withLock({ value in let wasArmed = value; value = false; return wasArmed }) {
                    services.withLock { $0 }?.state.withLock { $0.holdNextScan = true }
                }
            })
        })
        services.withLock { $0 = f.base.services }
        armed.withLock { $0 = true }
        var scans = f.base.services.heldScanEvents.stream.makeAsyncIterator()
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        let activation = try #require(f.base.model.catalogMutationTask)
        _ = await scans.next()
        #expect(f.base.model.runtimeIsSelected(f.target))
        #expect(try await f.records().isEmpty)
        activation.cancel()
        f.base.services.releaseScan()
        await activation.value
        #expect(try await f.records().isEmpty)
        #expect(f.isInstalled(f.previous))
    }

    @Test(arguments: ReturnFamily.allCases)
    func unpinnedManualSwitchCreatesNoReplacement(family: ReturnFamily) async throws {
        let f = try await AutomaticReturnFixture.make(family)
        f.base.model.useRuntimeVersion(f.previous, pinned: false)
        await f.base.model.catalogMutationTask?.value
        f.base.model.useRuntimeVersion(f.target, pinned: false)
        await f.base.model.catalogMutationTask?.value
        #expect(f.base.model.runtimeIsSelected(f.target))
        #expect(try await f.records().isEmpty)
    }

    @Test func unpinningToANonrecommendedHelperCreatesNoReplacement() async throws {
        let f = try await AutomaticReturnFixture.make(.helper)
        let historical = "surround-audio-wine-11.20-1"
        try f.publish(historical)
        try await f.base.model.scanAndApply()
        f.base.model.useRuntimeVersion(historical, pinned: true)
        await f.base.model.catalogMutationTask?.value
        f.base.model.useRuntimeVersion(f.previous, pinned: false)
        await f.base.model.catalogMutationTask?.value
        #expect(f.base.model.runtimeIsSelected(f.previous))
        #expect(try await f.records().isEmpty)
    }
}

enum ReturnFamily: CaseIterable, Sendable { case dxmt, d3dmetal, helper }

@MainActor private struct AutomaticReturnFixture {
    let base: BundleUpgradeFixture
    let family: ReturnFamily
    let previous: String
    let target: String
    var familyID: String { family == .helper ? "component-surroundAudio" : "bundle-\(family == .dxmt ? "dxmt" : "d3dmetal")" }

    static func make(_ family: ReturnFamily, targetInstalled: Bool = true,
        storeFactory: ((AppPaths) -> RuntimeCatalogStore)? = nil) async throws -> Self {
        let base = try await BundleUpgradeFixture.make(pinned: true, storeFactory: storeFactory)
        let previous: String, target: String
        switch family {
        case .dxmt: previous = "dxmt-wine11.0cx-dxmt0.80"; target = "dxmt-wine11.20mg1.0-dxmt0.80"
        case .d3dmetal: previous = base.old; target = base.new
        case .helper: previous = "surround-audio-wine-11.20-2"; target = SurroundAudio.componentID
        }
        let result = Self(base: base, family: family, previous: previous, target: target)
        try result.publish(previous)
        try await base.model.scanAndApply()
        base.model.useRuntimeVersion(previous, pinned: true)
        await base.model.catalogMutationTask?.value
        try #require(base.model.runtimeIsSelected(previous) && base.model.runtimeIsPinned(previous))
        if targetInstalled { try result.publish(target) } else { result.removeReceipt(target) }
        try await base.model.scanAndApply()
        try #require(base.model.canUseRuntimeVersion(target))
        return result
    }

    func publish(_ id: String) throws {
        guard family == .helper else { try base.publish(id); return }
        let descriptor = try #require(base.model.runtimeCatalog?.catalog.manifest.components.first { $0.id.rawValue == id })
        let receipt = try InstalledComponent(kind: descriptor.kind, version: descriptor.version.rawValue, installedAt: .now, source: .download)
        base.services.state.withLock { $0.components.removeAll { $0.kind == receipt.kind && $0.version == receipt.version }; $0.components.append(receipt) }
    }
    func removeReceipt(_ id: String) {
        base.services.state.withLock {
            $0.bundles[id] = nil
            $0.components.removeAll { "\($0.kind.idPrefix)-\($0.version)" == id }
        }
    }
    func isInstalled(_ id: String) -> Bool {
        let state = base.services.snapshot
        return state.bundles[id] != nil || state.components.contains { "\($0.kind.idPrefix)-\($0.version)" == id }
    }
    func records() async throws -> [RuntimeAutomaticReplacement] {
        let paths = base.paths
        return try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load().replacements }
    }
    func qualify(seconds: Double) async throws {
        let paths = base.paths, target = target
        let bundleID = family == .helper ? base.old : target
        let components = family == .helper ? [target] : []
        try await BlockingIO.run {
            try RuntimeAutomaticUpdateStore(paths: paths).recordVerifiedSession(bundleID: bundleID,
                componentIDs: components, confirmedRunningSeconds: seconds, sessionID: UUID())
        }
    }
    func cleanup() async {
        base.model.scheduleDependencyAutoUpdates()
        await base.model.dependencyAutoUpdateTask?.value
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
