// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Observation
import LauncherCore
import RuntimeManager
import DownloadEngine

@MainActor extension AppModel {
    func scheduleDependencyAutoUpdates(retry: Bool = false) {
        if retry { dependencyAutoUpdateSuppressed = [] }
        guard autoUpdateDependencies || dependencyHasRetainedVersions else { return }
        guard !isStarting, catalogAccess != nil, runtimeCatalog != nil,
            !runtimeCatalogUnavailable, dependencyAutoUpdateTask == nil else { return }
        let generation = UUID(); dependencyAutoUpdateGeneration = generation
        dependencyAutoUpdateReservation = true
        dependencyAutoUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.dependencyAutoUpdateGeneration == generation {
                    self.dependencyAutoUpdateTask = nil; self.dependencyAutoUpdateReservation = false
                    for (family, state) in self.dependencyAutoUpdates {
                        switch state {
                        case .installing, .waitingToActivate: self.dependencyAutoUpdates[family] = nil
                        default: break
                        }
                    }
                    self.dependencyWorking = [:]; self.rebuildRows()
                }
            }
            do {
                try await self.flushLaunchSettings()
                try await self.refreshAutomaticRetention()
                try await self.cleanupAutomaticReplacements()
                self.dependencyConsentTargets = [:]; self.refreshDependencyConsentGames()
                var attempted = self.dependencyAutoUpdateSuppressed
                while !Task.isCancelled, self.autoUpdateDependencies, let current = self.runtimeCatalog {
                    let installedIDs = Set(self.installed.compactMap { try? SafeIdentifier("\($0.kind.idPrefix)-\($0.version)") })
                    let candidates = RuntimeAutomaticUpdate.candidates(in: current,
                        installedBundleIDs: Set(self.installedBundles.keys.compactMap { try? SafeIdentifier($0) }),
                        installedComponentIDs: installedIDs)
                    guard let update = candidates.first(where: { !attempted.contains($0.familyID) }) else { break }
                    attempted.insert(update.familyID)
                    if self.installedBundles[update.previousID.rawValue]?.source == .importFromGPTK,
                        let version = update.changedGraphicsVersion(in: current, importedFramework: self.installedBundles[update.previousID.rawValue]?.importedFramework, isImported: true) {
                        let paths = self.paths
                        let state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
                        self.dependencyAutoUpdates[update.familyID] = state.declinedGraphicsVersions.contains(version.rawValue)
                            ? .graphicsUpdateDeclined(id: update.targetID.rawValue) : .graphicsUpdateOffered(id: update.targetID.rawValue)
                        continue
                    }
                    let components = self.dependencyComponents(update, in: current)
                    if components.contains(where: { $0.consent != nil && self.runtimeConsentAccepted[$0.id.rawValue] != true }) {
                        if let backend = update.backend { self.dependencyConsentTargets[backend] = update }
                        self.refreshDependencyConsentGames()
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.autoUpdateDependencies, let current = self.runtimeCatalog,
                        (try? update.selections(in: current)) != nil else { continue }
                    try await self.installDependencyUpdate(update, snapshot: current)
                }
            } catch { /* A failed settings write or cancellation never changes selection. */ }
        }
    }

    func dependencyComponents(_ update: RuntimeAutomaticUpdate, in snapshot: RuntimeCatalogSnapshot) -> [RuntimeComponent] {
        if let bundle = snapshot.catalog.manifest.bundles.first(where: { $0.id == update.targetID }) {
            return snapshot.catalog.manifest.components.filter { bundle.components.contains($0.id) }
        }
        return snapshot.catalog.manifest.components.filter { $0.id == update.targetID }
    }

    func installDependencyUpdate(_ update: RuntimeAutomaticUpdate, snapshot: RuntimeCatalogSnapshot) async throws {
        let id = update.targetID.rawValue, family = update.familyID
        dependencyAutoUpdates[family] = .installing(id: id)
        dependencyWorking[id] = .working(phase: .checkingSpace, fraction: nil)
        setDependencyUpdateError(nil, for: id)
        postDependencyUpdate("Automatic install started", update: update)
        var staged: DependencyStagingHandle?
        do {
            let importedFrom = installedBundles[update.previousID.rawValue]?.source == .importFromGPTK
                ? snapshot.catalog.manifest.bundles.first { $0.id == update.previousID } : nil
            let generation = dependencyAutoUpdateGeneration
            staged = try await services.stageDependency(update, manifest: snapshot.catalog.manifest, importedFrom: importedFrom) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self, self.dependencyAutoUpdateGeneration == generation,
                        self.dependencyAutoUpdates[family] == .installing(id: id) else { return }
                    switch event {
                    case .phase(let phase): self.dependencyWorking[id] = .working(phase: phase, fraction: nil)
                    case .progress(let downloaded, let network, let assembled, let totalAssembled):
                        let total = network > 0 ? network : totalAssembled, count = network > 0 ? downloaded : assembled
                        self.dependencyWorking[id] = .working(phase: .staging, fraction: total > 0 ? min(1, max(0, Double(count) / Double(total))) : nil)
                    default: break
                    }
                    self.rebuildRows()
                }
            }
            try Task.checkCancellation()
            dependencyWorking[id] = nil; rebuildRows()
            postDependencyUpdate("Automatic staging succeeded", update: update)
            dependencyAutoUpdates[family] = .waitingToActivate(id: id)
            try await waitForDependencyActivation()
            try Task.checkCancellation()
            guard autoUpdateDependencies, let current = runtimeCatalog, let catalogAccess, let staged else { throw LauncherError.cancelled }
            let selections = try update.selections(in: current)
            runtimeCatalogMutationID = id; catalogSelectionGeneration = UUID()
            defer { runtimeCatalogMutationID = nil; catalogSelectionGeneration = UUID() }
            do {
                try await scanAndApply()
                let previousInstalled = update.backend != nil ? installedBundles[update.previousID.rawValue] != nil
                    : installed.contains { "\($0.kind.idPrefix)-\($0.version)" == update.previousID.rawValue }
                guard previousInstalled else { throw LauncherError.busy("Automatic source is no longer installed") }
                try await staged.publish()
                try await scanAndApply()
                guard dependencyUpdateIsInstalled(update) else { throw LauncherError.io("Automatic runtime receipt is missing") }
                let paths = paths
                try await BlockingIO.run {
                    try RuntimeAutomaticUpdateStore(paths: paths).retain(familyID: update.familyID,
                        previousID: update.previousID.rawValue, replacementID: update.targetID.rawValue)
                }
                dependencyHasRetainedVersions = true
                let actual = try await catalogAccess.activate(selections)
                if Task.isCancelled || !autoUpdateDependencies {
                    var previous = actual.selections
                    if let backend = update.backend { previous.bundles[backend] = current.selections.bundles[backend] }
                    if let kind = update.kind { previous.helpers[kind] = current.selections.helpers[kind] }
                    let restoredSelections = previous
                    let restored = try await Task.detached { try await catalogAccess.activate(restoredSelections) }.value
                    applyRuntimeCatalog(restored)
                    throw LauncherError.cancelled
                }
                applyRuntimeCatalog(actual)
                dependencyConsentTargets[update.backend ?? .dxmt] = nil; refreshDependencyConsentGames()
                dependencyAutoUpdates[family] = .keepingPrevious(id: id)
                postDependencyUpdate("Automatic version activated", update: update)
                try await staged.discard()
            } catch {
                await reconcileRuntimeCatalog()
                throw error
            }
        } catch {
            if let staged { try? await staged.discard() }
            dependencyWorking[id] = nil
            if !Task.isCancelled, launcherError(error) != .cancelled { setDependencyUpdateError(launcherError(error), for: id) }
            postDependencyUpdate("Automatic install failed", update: update)
            // Reconcile a publication that won a late cancellation without activating it.
            await Task { @MainActor [weak self] in try? await self?.scanAndApply() }.value
            if Task.isCancelled { throw LauncherError.cancelled }
        }
    }

    func dependencyUpdateIsInstalled(_ update: RuntimeAutomaticUpdate) -> Bool {
        if update.backend != nil { return installedBundles[update.targetID.rawValue] != nil }
        return installed.contains { "\($0.kind.idPrefix)-\($0.version)" == update.targetID.rawValue }
    }

    func waitForDependencyActivation() async throws {
        while true {
            try Task.checkCancellation()
            let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let ready = withObservationTracking {
                canChangeRuntimeCatalog && !runtimeCatalogRefreshing
            } onChange: { changes.continuation.yield(()) }
            if ready { changes.continuation.finish(); return }
            for await _ in changes.stream { break }
            changes.continuation.finish()
        }
    }

    func refreshDependencyConsentGames() {
        runtimeUpdatesAwaitingConsent = autoUpdateDependencies ? Set(GameDefinition.all.filter {
            dependencyConsentTargets[launchSettings(for: $0.id).backend] != nil
        }.map(\.id)) : []
    }

    func dependencySetupTarget(for gameID: String) -> RuntimeCatalogSnapshot? {
        guard autoUpdateDependencies, let current = runtimeCatalog,
            let update = dependencyConsentTargets[launchSettings(for: gameID).backend],
            let selections = try? update.selections(in: current) else { return nil }
        return try? current.replacingSelections(selections)
    }

    func clearResolvedDependencyOffers() {
        for (family, state) in dependencyAutoUpdates {
            switch state {
            case .graphicsUpdateOffered(let id), .graphicsUpdateDeclined(let id):
                if runtimeIsSelected(id) { dependencyAutoUpdates[family] = nil }
            default: break
            }
        }
        for (backend, update) in dependencyConsentTargets where runtimeIsSelected(update.targetID.rawValue) {
            dependencyConsentTargets[backend] = nil
        }
        refreshDependencyConsentGames()
    }

    func postDependencyUpdate(_ message: String, update: RuntimeAutomaticUpdate) {
        postDependencyUpdate(message, familyID: update.familyID)
    }
    func postDependencyUpdate(_ message: String, familyID: String) {
        if dependencyUpdateLog == nil { dependencyUpdateLog = EventLog(directory: paths.logs) }
        dependencyUpdateLog?.post(.info, "runtime", message, metadata: ["family": familyID])
    }
}
