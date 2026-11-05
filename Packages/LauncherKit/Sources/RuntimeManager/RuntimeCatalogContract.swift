// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// All authority comes from the app's bundled manifest. Remote profiles only
/// assert compatibility with these layouts, environment and helper scopes.
struct RuntimeCatalogContract: Sendable {
    let baseline: RuntimeCatalog
    init(_ manifest: RuntimeManifest) { baseline = .bundled(manifest) }

    func validate(_ catalog: RuntimeCatalog) throws {
        guard catalog.schemaVersion == 1, catalog.clientContract == RuntimeCatalog.clientContract else {
            throw catalogError("Unsupported contract")
        }
        guard catalog.bundleBindings.count <= 64, catalog.helperBindings.count <= 256,
            Set(catalog.bundleBindings.map(\.bundleID)).count == catalog.bundleBindings.count,
            Set(catalog.helperBindings.map(\.componentID)).count == catalog.helperBindings.count,
            Set(catalog.bundleBindings.map(\.bundleID)) == Set(catalog.manifest.bundles.map(\.id)),
            Set(catalog.recommendedBundles.keys) == Set(baseline.recommendedBundles.keys),
            Set(catalog.recommendedHelpers.keys) == Set(baseline.recommendedHelpers.keys) else {
            throw catalogError("Invalid bindings or recommendations")
        }
        for component in catalog.manifest.components {
            guard component.url.map({ $0.scheme?.lowercased() == "https" }) ?? true,
                component.license.url.scheme?.lowercased() == "https",
                baseline.manifest.components.contains(where: { compatibleLayout(component, $0) }) else {
                throw catalogError("Unsupported component layout or URL")
            }
        }
        for binding in catalog.bundleBindings {
            guard let profile = baseline.manifest.bundles.first(where: { $0.id == binding.profileID }),
                let bundle = catalog.manifest.bundles.first(where: { $0.id == binding.bundleID }),
                bundle.backend == profile.backend, bundle.environment == profile.environment,
                bundle.components.count == profile.components.count else {
                throw catalogError("Unknown or incompatible bundle profile")
            }
            for id in bundle.components {
                guard let component = catalog.manifest.component(id: id),
                    profile.components.compactMap({ baseline.manifest.component(id: $0) })
                        .contains(where: { compatibleLayout(component, $0) }) else {
                    throw catalogError("Incompatible bundle component")
                }
            }
        }
        let helpers = catalog.manifest.components.filter { catalogHelperKinds.contains($0.kind) }
        guard Set(helpers.map(\.id)) == Set(catalog.helperBindings.map(\.componentID)) else {
            throw catalogError("Missing helper binding")
        }
        for binding in catalog.helperBindings {
            guard let component = catalog.manifest.component(id: binding.componentID), catalogHelperKinds.contains(component.kind),
                !binding.profileIDs.isEmpty, binding.profileIDs.count <= 64,
                Set(binding.profileIDs).count == binding.profileIDs.count else { throw catalogError("Invalid helper binding") }
            for profile in binding.profileIDs {
                guard baseline.helperBindings.contains(where: { known in
                    baseline.manifest.component(id: known.componentID)?.kind == component.kind && known.profileIDs.contains(profile)
                }) else { throw catalogError("Unsupported helper compatibility") }
            }
        }
        let recommended = RuntimeCatalogSelections(
            bundles: catalog.recommendedBundles.mapValues { RuntimeCatalogSelection(id: $0) },
            helpers: catalog.recommendedHelpers.mapValues { RuntimeCatalogSelection(id: $0) })
        try validate(recommended, in: catalog)
    }

    func validate(_ selections: RuntimeCatalogSelections, in catalog: RuntimeCatalog) throws {
        guard Set(selections.bundles.keys) == Set(baseline.recommendedBundles.keys),
            Set(selections.helpers.keys) == Set(baseline.recommendedHelpers.keys) else {
            throw catalogError("Incomplete selection")
        }
        for (backend, selection) in selections.bundles {
            guard let bundle = catalog.manifest.bundles.first(where: { $0.id == selection.id }), bundle.backend == backend,
                let profile = catalog.bundleBindings.first(where: { $0.bundleID == selection.id })?.profileID else {
                throw catalogError("Unknown selected bundle")
            }
            for (kind, helper) in selections.helpers {
                // A helper scoped to D3DMetal is irrelevant to DXMT. A helper
                // required by this profile must support the selected revision.
                let applicable = baseline.helperBindings.contains { known in
                    baseline.manifest.component(id: known.componentID)?.kind == kind && known.profileIDs.contains(profile)
                }
                if applicable {
                    guard (catalog.helperBindings + baseline.helperBindings).contains(where: {
                        $0.componentID == helper.id && $0.profileIDs.contains(profile)
                    }) else {
                        throw catalogError("Selected helper is incompatible with bundle")
                    }
                }
            }
        }
        for (kind, selection) in selections.helpers {
            guard catalogHelperKinds.contains(kind), catalog.manifest.component(id: selection.id)?.kind == kind else {
                throw catalogError("Unknown selected helper")
            }
        }
    }

    /// A newer app can add trusted compiled profiles without rewriting the
    /// immutable remote binding history. App-owned helper/profile extensions
    /// remain separate and are consulted by snapshot compatibility lookups.
    func restoring(_ state: RuntimeCatalogStoredState) throws -> RuntimeCatalogSnapshot {
        try validate(state.catalog)
        let components = try merge(state.catalog.manifest.components, baseline.manifest.components, id: { $0.id })
        let bundles = try merge(state.catalog.manifest.bundles, baseline.manifest.bundles, id: { $0.id })
        // A later app can bundle an already-known remote release. bundled()
        // generates a self-profile for it, but the persisted release retains
        // its original supported compiled profile. Strict descriptor merging
        // above proves that this is the identical bundle, not identity reuse.
        let existingBundleIDs = Set(state.catalog.bundleBindings.map(\.bundleID))
        let bindings = state.catalog.bundleBindings + baseline.bundleBindings.filter { !existingBundleIDs.contains($0.bundleID) }
        var helpers = state.catalog.helperBindings
        for compiled in baseline.helperBindings {
            if let old = helpers.first(where: { $0.componentID == compiled.componentID }) {
                guard Set(old.profileIDs).isSubset(of: Set(compiled.profileIDs)) else {
                    throw catalogError("Compiled helper compatibility regressed")
                }
            } else { helpers.append(compiled) }
        }
        let catalog = RuntimeCatalog(revision: state.catalog.revision,
            manifest: try RuntimeManifest(components: components, bundles: bundles), bundleBindings: bindings,
            helperBindings: helpers, recommendedBundles: state.catalog.recommendedBundles,
            recommendedHelpers: state.catalog.recommendedHelpers)
        try validate(catalog)
        return try RuntimeCatalogSnapshot(catalog: catalog, selections: state.selections, contract: self)
    }

    func merging(_ update: RuntimeCatalog, into history: RuntimeCatalog) throws -> RuntimeCatalog {
        try validate(update)
        guard update.revision >= history.revision else { throw catalogError("Revision regression") }
        let components = try merge(history.manifest.components, update.manifest.components, id: { $0.id })
        let bundles = try merge(history.manifest.bundles, update.manifest.bundles, id: { $0.id })
        let bindings = try merge(history.bundleBindings, update.bundleBindings, id: { $0.bundleID })
        let helpers = try merge(history.helperBindings, update.helperBindings, id: { $0.componentID })
        if update.revision == history.revision {
            guard components.count == history.manifest.components.count, bundles.count == history.manifest.bundles.count,
                bindings.count == history.bundleBindings.count, helpers.count == history.helperBindings.count,
                update.recommendedBundles == history.recommendedBundles, update.recommendedHelpers == history.recommendedHelpers else {
                throw catalogError("Changed catalog at same revision")
            }
        }
        let merged = RuntimeCatalog(revision: update.revision,
            manifest: try RuntimeManifest(components: components, bundles: bundles), bundleBindings: bindings,
            helperBindings: helpers, recommendedBundles: update.recommendedBundles, recommendedHelpers: update.recommendedHelpers)
        try validate(merged)
        return merged
    }

    private func merge<T: Encodable>(_ old: [T], _ new: [T], id: (T) -> SafeIdentifier) throws -> [T] {
        var result = old
        let previous = Dictionary(uniqueKeysWithValues: old.map { (id($0), $0) })
        for value in new {
            if let existing = previous[id(value)] {
                guard try catalogBytes(existing) == catalogBytes(value) else { throw catalogError("Immutable identity changed") }
            } else { result.append(value) }
        }
        return result
    }

    private func compatibleLayout(_ component: RuntimeComponent, _ compiled: RuntimeComponent) -> Bool {
        component.kind == compiled.kind && component.sourceMode == compiled.sourceMode && component.consent == compiled.consent
            && component.license.redistributable == compiled.license.redistributable
            && (component.rootPath == nil) == (compiled.rootPath == nil)
            && component.wineBinary == compiled.wineBinary
            && (try? catalogBytes(component.overlay)) == (try? catalogBytes(compiled.overlay))
    }
}
