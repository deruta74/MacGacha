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
                    let components = self.dependencyComponents(update, in: current)
                    if components.contains(where: { $0.consent != nil && self.runtimeConsentAccepted[$0.id.rawValue] != true }) {
                        if let backend = update.backend { self.dependencyConsentTargets[backend] = update }
                        self.refreshDependencyConsentGames()
                        continue
                    }
                    try await self.waitForDependencyActivation()
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
        let stream: RuntimeInstallStream
        if let bundle = snapshot.catalog.manifest.bundles.first(where: { $0.id == update.targetID }) {
            stream = services.install(bundle, manifest: snapshot.catalog.manifest, from: nil)
        } else if let component = snapshot.catalog.manifest.component(id: update.targetID) {
            stream = RuntimeInstallStream(services.install(component, from: nil))
        } else { throw LauncherError.io("Automatic runtime target is missing") }
        do {
            var completed = false
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .phase(.completed): completed = true
                case .failed(let error): throw error
                case .phase(.cancelled): throw LauncherError.cancelled
                case .phase(.failed): throw LauncherError.io("Automatic runtime installation failed")
                case .needsBatchApproval(let required, let available): throw LauncherError.insufficientSpace(required: required, available: available)
                case .phase(let phase): dependencyWorking[id] = .working(phase: phase, fraction: nil)
                case .progress(let downloaded, let network, let staged, let totalStaged):
                    let total = network > 0 ? network : totalStaged, count = network > 0 ? downloaded : staged
                    let fraction = total > 0 ? min(1, max(0, Double(count) / Double(total))) : nil
                    dependencyWorking[id] = .working(phase: .staging, fraction: fraction)
                case .fileVerified: break
                }
                rebuildRows()
                if completed { break }
            }
            await stream.waitUntilFinished()
            try Task.checkCancellation()
            guard completed else { throw LauncherError.transport("Automatic installation ended before completion") }
            try await scanAndApply()
            guard dependencyUpdateIsInstalled(update) else { throw LauncherError.io("Automatic runtime receipt is missing") }
            dependencyWorking[id] = nil; rebuildRows()
            postDependencyUpdate("Automatic install succeeded", update: update)
            dependencyAutoUpdates[family] = .waitingToActivate(id: id)
            try await waitForDependencyActivation()
            try Task.checkCancellation()
            guard autoUpdateDependencies, let current = runtimeCatalog, let catalogAccess else { throw LauncherError.cancelled }
            let selections = try update.selections(in: current)
            runtimeCatalogMutationID = id; catalogSelectionGeneration = UUID()
            defer { runtimeCatalogMutationID = nil; catalogSelectionGeneration = UUID() }
            do {
                let paths = paths
                try await BlockingIO.run {
                    try RuntimeAutomaticUpdateStore(paths: paths).retain(familyID: update.familyID,
                        previousID: update.previousID.rawValue, replacementID: update.targetID.rawValue)
                }
                let actual = try await catalogAccess.activate(selections)
                applyRuntimeCatalog(actual)
                dependencyConsentTargets[update.backend ?? .dxmt] = nil; refreshDependencyConsentGames()
                dependencyAutoUpdates[family] = .keepingPrevious(id: id)
                postDependencyUpdate("Automatic version activated", update: update)
            } catch {
                await reconcileRuntimeCatalog()
                throw error
            }
        } catch {
            await stream.cancelAndWait()
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

    func postDependencyUpdate(_ message: String, update: RuntimeAutomaticUpdate) {
        postDependencyUpdate(message, familyID: update.familyID)
    }
    func postDependencyUpdate(_ message: String, familyID: String) {
        if dependencyUpdateLog == nil { dependencyUpdateLog = EventLog(directory: paths.logs) }
        dependencyUpdateLog?.post(.info, "runtime", message, metadata: ["family": familyID])
    }
}
