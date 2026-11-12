// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

@MainActor extension AppModel {
    func refreshAutomaticRetention() async throws {
        let paths = paths
        let state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
        dependencyHasRetainedVersions = !state.replacements.isEmpty
        for record in state.replacements {
            if runtimeIsSelected(record.replacementID) && !runtimeIsPinned(record.previousID) {
                dependencyAutoUpdates[record.familyID] = .keepingPrevious(id: record.previousID)
            }
        }
    }

    func cancelAutomaticCleanupForPinnedSelection(_ target: RuntimeCatalogSnapshot, id: String) async throws {
        guard let selected = (Array(target.selections.bundles.values) + Array(target.selections.helpers.values))
            .first(where: { $0.id.rawValue == id }), selected.pinned else { return }
        let family: String
        if let bundle = target.catalog.manifest.bundles.first(where: { $0.id.rawValue == id }) { family = "bundle-" + bundle.backend.rawValue }
        else if let component = target.catalog.manifest.components.first(where: { $0.id.rawValue == id }) { family = "component-" + component.kind.rawValue }
        else { return }
        let paths = paths
        try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).cancelCleanup(familyID: family) }
        let retained = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
        dependencyHasRetainedVersions = !retained.replacements.isEmpty
        dependencyAutoUpdates[family] = nil
    }

    /// Called under the catalog mutation reservation after successful activation
    /// and a fresh receipt scan. Failed or cancelled activation never gets here.
    func retainPreviousRuntimeOnAutomaticReturn(from previous: RuntimeCatalogSnapshot,
        to actual: RuntimeCatalogSnapshot, id: String) async throws {
        let before: RuntimeCatalogSelection?, after: RuntimeCatalogSelection?
        let recommended: SafeIdentifier?, family: String
        if let bundle = actual.catalog.manifest.bundles.first(where: { $0.id.rawValue == id }) {
            before = previous.selections.bundles[bundle.backend]
            after = actual.selections.bundles[bundle.backend]
            recommended = actual.catalog.recommendedBundles[bundle.backend]
            family = "bundle-" + bundle.backend.rawValue
        } else if let helper = actual.catalog.manifest.components.first(where: { $0.id.rawValue == id }) {
            before = previous.selections.helpers[helper.kind]
            after = actual.selections.helpers[helper.kind]
            recommended = actual.catalog.recommendedHelpers[helper.kind]
            family = "component-" + helper.kind.rawValue
        } else { return }
        guard let before, let after, before.pinned, !after.pinned,
            after.id == recommended, after.id.rawValue == id, before.id != after.id else { return }
        let previousID = before.id.rawValue
        guard installedBundles[previousID] != nil || installed.contains(where: {
            "\($0.kind.idPrefix)-\($0.version)" == previousID
        }) else { return }
        let paths = paths
        try await BlockingIO.run {
            try RuntimeAutomaticUpdateStore(paths: paths).retain(familyID: family,
                previousID: previousID, replacementID: id)
        }
        dependencyHasRetainedVersions = true
        dependencyAutoUpdates[family] = .keepingPrevious(id: previousID)
    }

    func cleanupAutomaticReplacements() async throws {
        let paths = paths
        var state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
        // Retire A before B in A -> B -> C, releasing each predecessor reference.
        for record in state.replacements where record.verified {
            try await waitForDependencyActivation()
            try Task.checkCancellation()
            guard let snapshot = runtimeCatalog else { return }
            guard state.replacements.contains(where: { $0.id == record.id }) else { continue }
            let familyPinned = snapshot.selections.bundles.contains { "bundle-" + $0.key.rawValue == record.familyID && $0.value.pinned }
                || snapshot.selections.helpers.contains { "component-" + $0.key.rawValue == record.familyID && $0.value.pinned }
            if familyPinned || runtimeIsPinned(record.previousID) || runtimeIsPinned(record.replacementID) {
                try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).cancelCleanup(familyID: record.familyID) }
                state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
                dependencyHasRetainedVersions = !state.replacements.isEmpty
                dependencyAutoUpdates[record.familyID] = nil
                continue
            }
            let otherRecords = state.replacements.filter { $0.id != record.id }
            let referenced = Set(snapshot.selections.bundles.values.map { $0.id.rawValue }
                + snapshot.selections.helpers.values.map { $0.id.rawValue }
                + otherRecords.flatMap { [$0.previousID, $0.replacementID] })
            guard !referenced.contains(record.previousID) else {
                postDependencyUpdate("Automatic cleanup kept referenced version", familyID: record.familyID)
                continue
            }
            runtimeCatalogMutationID = "automatic-cleanup"
            defer { runtimeCatalogMutationID = nil }
            do {
                let manifest = snapshot.catalog.manifest
                if let bundle = manifest.bundles.first(where: { $0.id.rawValue == record.previousID }) {
                    try await services.remove(bundle, manifest: manifest)
                    try await scanAndApply()
                    let retainedBundleIDs = Set(installedBundles.keys).union(referenced)
                    let componentReferences = Set(manifest.bundles.filter { retainedBundleIDs.contains($0.id.rawValue) }
                        .flatMap { $0.components.map(\.rawValue) }).union(referenced)
                    for componentID in bundle.components where !componentReferences.contains(componentID.rawValue) {
                        if let descriptor = manifest.component(id: componentID),
                            let component = installed.first(where: { $0.kind == descriptor.kind && $0.version == descriptor.version.rawValue }) {
                            try await services.remove(component)
                        }
                    }
                } else if let descriptor = manifest.components.first(where: { $0.id.rawValue == record.previousID }),
                    let component = installed.first(where: { $0.kind == descriptor.kind && $0.version == descriptor.version.rawValue }) {
                    try await services.remove(component)
                }
                try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).removeReplacement(id: record.id) }
                state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
                dependencyHasRetainedVersions = !state.replacements.isEmpty
                if !state.replacements.contains(where: { $0.familyID == record.familyID }) { dependencyAutoUpdates[record.familyID] = nil }
                try await scanAndApply()
                postDependencyUpdate("Automatic cleanup removed replaced version", familyID: record.familyID)
            } catch {
                postDependencyUpdate("Automatic cleanup kept replaced version", familyID: record.familyID)
                if Task.isCancelled { throw LauncherError.cancelled }
            }
        }
    }
}
