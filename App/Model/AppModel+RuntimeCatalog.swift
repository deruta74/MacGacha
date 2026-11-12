// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

struct RuntimeInstallContext: Sendable {
    let component: RuntimeComponent
    let bundle: RuntimeBundle?
    let manifest: RuntimeManifest
}

@MainActor extension AppModel {
    var effectiveRuntimeManifest: RuntimeManifest? {
        guard !runtimeCatalogUnavailable else { return nil }
        return catalogAccess == nil ? manifest : runtimeCatalog?.manifest
    }
    func applyRuntimeCatalog(_ snapshot: RuntimeCatalogSnapshot) {
        if let current = runtimeCatalog, current.catalog.revision > snapshot.catalog.revision { return }
        runtimeCatalog = snapshot; manifest = snapshot.catalog.manifest
        runtimeCatalogUnavailable = false; rebuildRows()
    }
    func scheduleRuntimeCatalogRefresh() {
        guard catalogAccess != nil, catalogRefreshTask == nil else { return }
        catalogRefreshTask = Task { [weak self] in
            await self?.refreshRuntimeCatalog(force: false)
            self?.catalogRefreshTask = nil
        }
    }
    func refreshRuntimeCatalog(force: Bool) async {
        guard let catalogAccess, !runtimeCatalogRefreshing else { return }
        runtimeCatalogRefreshing = true
        let selectionGeneration = catalogSelectionGeneration
        defer { runtimeCatalogRefreshing = false }
        do {
            let result = try await catalogAccess.refresh(force: force)
            guard catalogSelectionGeneration == selectionGeneration else { return }
            applyRuntimeCatalog(result)
            try await scanAndApply()
            scheduleDependencyAutoUpdates(retry: true)
        } catch {
            guard catalogSelectionGeneration == selectionGeneration else { return }
            // A rename may have published before an fsync error. Re-read the
            // shared authority before releasing any mutation reservation.
            await reconcileRuntimeCatalog()
            if force && !Task.isCancelled { show(error) }
        }
    }
    func reconcileRuntimeCatalog() async {
        guard let catalogAccess else { return }
        let selectionGeneration = catalogSelectionGeneration
        do {
            let snapshot = try await Task.detached { try await catalogAccess.snapshot() }.value
            guard catalogSelectionGeneration == selectionGeneration else { return }
            catalogSelectionGeneration = UUID()
            applyRuntimeCatalog(snapshot)
        }
        catch {
            guard catalogSelectionGeneration == selectionGeneration else { return }
            catalogSelectionGeneration = UUID()
            runtimeCatalogUnavailable = true; rebuildRows()
        }
    }
    func persistRuntimeCatalogSelection() async throws {
        guard let catalogAccess else { return }
        do {
            let actual = try await catalogAccess.persistSelection()
            applyRuntimeCatalog(actual)
        } catch {
            if let publication = error as? RuntimeCatalogPublicationFailure, let actual = publication.persistedSnapshot {
                catalogSelectionGeneration = UUID()
                applyRuntimeCatalog(actual)
            } else { await reconcileRuntimeCatalog() }
            throw error
        }
    }
    func runtimeProfile(for backend: RuntimeBackend) -> String? {
        guard let bundle = effectiveRuntimeManifest?.defaultBundle(for: backend) else { return nil }
        return runtimeCatalog?.profile(for: bundle.id)?.rawValue ?? bundle.id.rawValue
    }
    func captureRuntimeInstallContext(_ id: String, manifest captured: RuntimeManifest? = nil) {
        if captured == nil, runtimeInstallContexts[id] != nil { return }
        guard let captured = captured ?? manifest else { return }
        let bundle = captured.bundles.first { $0.id.rawValue == id }
        guard let component = captured.components.first(where: { component in
            if let bundle { return bundle.components.contains(component.id) && (bundle.backend == .d3dmetal ? component.kind == .d3dmetal : component.kind == .wine) }
            return component.id.rawValue == id
        }) else { return }
        runtimeInstallContexts[id] = RuntimeInstallContext(component: component, bundle: bundle, manifest: captured)
    }
    var canChangeRuntimeCatalog: Bool {
        !isStarting && !runtimeCatalogUnavailable && runtimeCatalogMutationID == nil &&
            launchSlotOwner == nil && liveLaunchGames.isEmpty && launchStartupError == nil &&
            !launchStates.values.contains { if case .recoveryNeeded = $0 { true } else { false } } &&
            !isRuntimeOperationRunning && !isGameOperationRunning && consentRequest == nil && importState == nil &&
            runtimeSetupChains.isEmpty && runtimeSetupRosettaChecks.isEmpty && languageRestart == nil && !updater.isInstallingUpdate
    }
    func runtimeIsSelected(_ id: String) -> Bool {
        guard let runtimeCatalog else { return false }
        return runtimeCatalog.selections.bundles.values.contains { $0.id.rawValue == id } ||
            runtimeCatalog.selections.helpers.values.contains { $0.id.rawValue == id }
    }
    func runtimeIsPinned(_ id: String) -> Bool {
        guard let runtimeCatalog else { return false }
        return (Array(runtimeCatalog.selections.bundles.values) + Array(runtimeCatalog.selections.helpers.values))
            .contains { $0.id.rawValue == id && $0.pinned }
    }
    func runtimeIsRecommended(_ id: String) -> Bool {
        guard let runtimeCatalog else { return false }
        return runtimeCatalog.catalog.recommendedBundles.values.contains { $0.rawValue == id } ||
            runtimeCatalog.catalog.recommendedHelpers.values.contains { $0.rawValue == id }
    }
    func canRemoveRuntime(_ id: String) -> Bool {
        // Keep the preference and pin when an idle user confirms removal. A
        // later Set Up reinstalls that exact version instead of switching it.
        !dependencyAutoUpdateReservation && (catalogAccess == nil || canChangeRuntimeCatalog)
    }
    func runtimeVersionTarget(_ id: String, pinned: Bool? = nil) throws -> RuntimeCatalogSnapshot {
        guard let current = runtimeCatalog else { throw LauncherError.io("Runtime catalog unavailable") }
        var selections = current.selections
        let value = RuntimeCatalogSelection(id: try SafeIdentifier(id), pinned: pinned ?? !runtimeIsRecommended(id))
        if let bundle = current.catalog.manifest.bundles.first(where: { $0.id.rawValue == id }) {
            selections.bundles[bundle.backend] = value
        } else if let helper = current.catalog.manifest.components.first(where: { $0.id.rawValue == id }),
            selections.helpers[helper.kind] != nil { selections.helpers[helper.kind] = value }
        else { throw LauncherError.io("Unknown runtime selection") }
        return try current.replacingSelections(selections)
    }
    func canUseRuntimeVersion(_ id: String) -> Bool {
        canChangeRuntimeCatalog && (try? runtimeVersionTarget(id)) != nil
    }
    /// The row owns one captured target. Unrelated backend/helper pins survive.
    func useRuntimeVersion(_ id: String, pinned: Bool? = nil) {
        if let task = dependencyAutoUpdateTask {
            task.cancel()
            Task { [weak self] in await task.value; self?.useRuntimeVersion(id, pinned: pinned) }
            return
        }
        guard canChangeRuntimeCatalog, canBeginGameOrRuntimeOperation() else { return }
        do {
            let target = try runtimeVersionTarget(id, pinned: pinned)
            captureRuntimeInstallContext(id, manifest: target.catalog.manifest)
            runtimeCatalogMutationID = id; catalogSelectionGeneration = UUID()
            if case .installed = runtimeSetupItemState(id) {
                beginRuntimeCatalogActivation(target, id: id)
                return
            }
            guard let context = runtimeInstallContexts[id] else { throw LauncherError.io("Unknown runtime installation") }
            let components = context.bundle.map { bundle in context.manifest.components.filter { bundle.components.contains($0.id) } } ?? [context.component]
            let key = "catalog-" + id
            let plan = RuntimeSetupPlan(gameID: key, items: [.init(id: id,
                name: context.bundle?.displayName ?? Self.kindName(context.component.kind), size: RuntimeSetupPlan.total(components.map(\.size)))],
                needsAppleTerms: components.contains { $0.consent != nil && runtimeConsentAccepted[$0.id.rawValue] != true })
            catalogActivationTargets[key] = target
            runtimeSetupChains[key] = RuntimeSetupChain(plan: plan)
            advanceRuntimeSetups()
        } catch { runtimeCatalogMutationID = nil; show(error) }
    }
    func beginRuntimeCatalogActivation(_ target: RuntimeCatalogSnapshot, id: String) {
        guard let catalogAccess else { runtimeCatalogMutationID = nil; return }
        catalogMutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.catalogSelectionGeneration = UUID()
                self.runtimeCatalogMutationID = nil; self.catalogMutationTask = nil
            }
            do {
                try await self.cancelAutomaticCleanupForPinnedSelection(target, id: id)
                let actual = try await catalogAccess.activate(target.selections)
                self.catalogSelectionGeneration = UUID()
                self.applyRuntimeCatalog(actual)
                try await self.scanAndApply()
            } catch {
                if let publication = error as? RuntimeCatalogPublicationFailure, let actual = publication.persistedSnapshot {
                    self.catalogSelectionGeneration = UUID()
                    self.applyRuntimeCatalog(actual)
                } else { await self.reconcileRuntimeCatalog() }
                self.show(error)
            }
        }
    }
    func revokeCatalogSetupActivation(_ id: String) {
        guard runtimeCatalogMutationID == id else { return }
        for key in catalogActivationTargets.keys {
            guard runtimeSetupChains[key]?.plan.items.contains(where: { $0.id == id }) == true else { continue }
            cancelledCatalogSetups.insert(key)
        }
    }
    func finishCatalogSetup(_ key: String, succeeded: Bool) {
        guard let target = catalogActivationTargets.removeValue(forKey: key), let id = runtimeCatalogMutationID else { return }
        let cancelled = cancelledCatalogSetups.remove(key) != nil
        if succeeded && !cancelled { beginRuntimeCatalogActivation(target, id: id) }
        else { runtimeCatalogMutationID = nil }
    }
}
