// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import Launch

@MainActor extension AppModel {
    var storageContext: StorageContext {
        let selections = runtimeCatalog.map { Array($0.selections.bundles.values) + Array($0.selections.helpers.values) } ?? []
        var selected = Set(selections.map { $0.id.rawValue }).union(
            effectiveRuntimeManifest?.bundles.filter { bundle in
                runtimeCatalog == nil && effectiveRuntimeManifest?.defaultBundle(for: bundle.backend)?.id == bundle.id
            }.map { $0.id.rawValue } ?? [])
        if runtimeCatalog == nil {
            selected.formUnion(effectiveRuntimeManifest?.components.map { $0.id.rawValue } ?? [])
        }
        return StorageContext(region: region, selectedRuntimeIDs: selected,
            prefixSelectionKnown: effectiveRuntimeManifest != nil && !runtimeCatalogUnavailable && (catalogAccess == nil || runtimeCatalog != nil),
            pinnedRuntimeIDs: Set(selections.filter(\.pinned).map { $0.id.rawValue }),
            manifest: effectiveRuntimeManifest, cacheDirectory: storageCacheDirectory)
    }

    /// The caller owns cancellation, for example the Settings panel's task.
    @discardableResult func refreshStorage() async throws -> StorageSnapshot {
        try Task.checkCancellation()
        let generation = UUID()
        storageRefreshGeneration = generation; isRefreshingStorage = true
        defer { if storageRefreshGeneration == generation { isRefreshingStorage = false } }
        let result = try await storageService.refresh(storageContext)
        try Task.checkCancellation()
        guard storageRefreshGeneration == generation else { throw LauncherError.cancelled }
        storage = result
        return result
    }

    func cleanUp(_ candidate: StorageCleanupCandidate) async throws {
        guard !isBusyForUpdates, canBeginGameOrRuntimeOperation(),
            storage?.candidates.contains(candidate) == true else { throw LauncherError.busy("Storage cleanup unavailable") }
        if let id = candidate.runtimeID {
            guard canRemoveRuntime(id) else { throw LauncherError.busy("Runtime removal unavailable") }
        }
        // Publish before the first await, through deletion, provider invalidation
        // and the final inventory. New operations, restart and Sparkle all see it.
        storageCleanupInProgress = true
        storageRefreshGeneration = UUID(); isRefreshingStorage = false
        defer { storageCleanupInProgress = false; scheduleDependencyAutoUpdates() }
        let context = storageContext
        if candidate.kind == .inactiveRegionCache {
            // Existing providers own their network/disk tasks. Join every reader
            // before deleting and prevent new hydration/refresh while reserved.
            for task in artTasks.values { await task.value }
            for task in artHydrationTasks.values { await task.value }
            for task in eventsTasks.values { await task.value }
            await eventsHydrationTask?.value
        }
        try Task.checkCancellation()
        var failure: (any Error)?
        do {
            if let id = candidate.runtimeID {
                try await persistRuntimeCatalogSelection()
                try await storageService.validateRuntimeCandidate(candidate, context: storageContext)
                if let manifest = effectiveRuntimeManifest, let bundle = manifest.bundles.first(where: { $0.id.rawValue == id }) {
                    try await services.remove(bundle, manifest: manifest)
                } else if let component = installed.first(where: { "\($0.kind.idPrefix)-\($0.version)" == id }) {
                    try await services.remove(component)
                } else { throw LauncherError.busy("Runtime is no longer installed") }
                try await scanAndApply()
            } else {
                try await storageService.cleanUp(candidate, context: context)
            }
        } catch { failure = error }
        // Deletion can fail or be cancelled after removing a subset of a cache.
        // Release stale provider URLs even in that case, then reconcile totals.
        if let inactive = candidate.region {
            await artServices[inactive]?.invalidateStorageCache()
            await eventsServices[inactive]?.invalidateStorageCache()
            applyArt([:], in: inactive); applyEvents([:], in: inactive)
            artHydrationTasks[inactive] = nil
        }
        if failure == nil {
            let log = EventLog(directory: paths.logs)
            log.post(.info, "storage", "Storage cleanup completed", metadata: ["bytes": String(candidate.bytes)])
        }
        do { try await refreshStorage() }
        catch { if failure == nil { throw error } }
        if let failure { throw failure }
    }
}
