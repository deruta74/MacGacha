// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Launch
import RuntimeManager
@testable import MacGacha

@MainActor struct AppModelStorageTests {
    @Test func cleanupReservationBlocksRestartAndSparkleThenRefreshes() async throws {
        let model = AppModel.preview(rows: [], games: [:])
        let root = model.paths.root
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-old"))
        let service = SuspendedStorage(base: StorageInventory(paths: model.paths))
        model.storageService = service
        let snapshot = try await model.refreshStorage()
        #expect(model.storage == snapshot)
        let candidate = try #require(snapshot.candidates.first)
        let cleanup = Task { try await model.cleanUp(candidate) }
        await service.entered.wait()
        var resumed = 0
        let gate = UpdateRelaunchGate(isBusy: { model.isBusyForUpdates })
        #expect(gate.postponeRelaunch { resumed += 1 })
        #expect(resumed == 0)
        #expect(model.storageCleanupInProgress)
        #expect(model.languageRestartBlocker == .runtimeWork)
        #expect(model.isBusyForUpdates)
        #expect(!model.canBeginGameOrRuntimeOperation())
        #expect(!model.canChangeRuntimeCatalog)
        await #expect(throws: (any Error).self) { try await model.cleanUp(candidate) }
        await service.release.signal()
        try await cleanup.value
        #expect(!model.storageCleanupInProgress)
        #expect(model.storage?.candidates.isEmpty == true)
        #expect(!model.isBusyForUpdates)
        gate.refresh()
        #expect(resumed == 1)
    }

    @Test func runtimeCleanupUsesManualRemovalAndRejectsNewSessionPin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root), fs = try ContainedFileSystem(root: root)
        let installed = try InstalledComponent(kind: .wine, version: "old", installedAt: Date(timeIntervalSince1970: 1), source: .download)
        try fs.writeAtomically(JSONEncoder().encode(installed), to: SafeRelativePath("Runtimes/wine/old/.macgacha-component.json"))
        try fs.writeAtomically(Data([1]), to: SafeRelativePath("Runtimes/wine/old/bin/wine"))
        let model = AppModel(paths: paths, manifest: try RuntimeManifest(components: []),
            services: LiveRuntimeServices(paths: paths), defaults: nil)
        await model.start()
        let candidate = try #require(try await model.refreshStorage().candidates.first { $0.kind == .runtimeVersion })
        do {
            let pin = try RuntimePin.pin(paths: paths, componentIDs: ["wine-old"])
            await #expect(throws: (any Error).self) { try await model.cleanUp(candidate) }
            #expect(!model.storageCleanupInProgress)
            #expect(model.storage?.candidates.contains { $0.runtimeID == "wine-old" } == false)
            #expect(try fs.itemType(at: SafeRelativePath("Runtimes/wine/old")) == .directory)
            withExtendedLifetime(pin) {}
        }
        let retry = try #require(try await model.refreshStorage().candidates.first { $0.kind == .runtimeVersion })
        try await model.cleanUp(retry)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/wine/old")) == nil)
        #expect(model.storage?.candidates.contains { $0.runtimeID == "wine-old" } == false)
    }

    @Test func cancellationPreservesLastPublishedInventory() async throws {
        let model = AppModel.preview(rows: [], games: [:])
        defer { try? FileManager.default.removeItem(at: model.paths.root) }
        let snapshot = try await model.refreshStorage()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await model.refreshStorage()
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(model.storage == snapshot)
        #expect(!model.isRefreshingStorage)
    }
}

private actor StorageSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private struct SuspendedStorage: StorageServicing {
    let base: StorageInventory
    let entered = StorageSignal(), release = StorageSignal()
    func refresh(_ context: StorageContext) async throws -> StorageSnapshot { try await base.refresh(context) }
    func cleanUp(_ item: StorageCleanupCandidate, context: StorageContext) async throws {
        await entered.signal(); await release.wait()
        try await base.cleanUp(item, context: context)
    }
    func validateRuntimeCandidate(_ item: StorageCleanupCandidate, context: StorageContext) async throws {
        try await base.validateRuntimeCandidate(item, context: context)
    }
}
