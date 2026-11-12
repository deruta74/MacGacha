// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

@MainActor extension AppModel {
    func refreshAutomaticRetention() async throws {
        let paths = paths
        let state = try await BlockingIO.run { try RuntimeAutomaticUpdateStore(paths: paths).load() }
        for record in state.replacements {
            if runtimeIsSelected(record.replacementID) && !runtimeIsPinned(record.previousID) {
                dependencyAutoUpdates[record.familyID] = .keepingPrevious(id: record.replacementID)
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
        if case .keepingPrevious = dependencyAutoUpdates[family] { dependencyAutoUpdates[family] = nil }
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
