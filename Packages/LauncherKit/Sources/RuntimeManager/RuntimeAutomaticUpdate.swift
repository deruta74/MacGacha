// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// A proposed automatic switch. Installation, consent and activation remain separate.
public struct RuntimeAutomaticUpdate: Sendable, Equatable {
    public let familyID: String
    public let previousID: SafeIdentifier
    public let targetID: SafeIdentifier
    public let backend: RuntimeBackend?
    public let kind: ComponentKind?

    public func changedGraphicsVersion(in snapshot: RuntimeCatalogSnapshot, importedFramework: ImportedD3DMetalIdentity? = nil,
        isImported: Bool = false) -> SafeIdentifier? {
        guard backend == .d3dmetal,
            let oldBundle = snapshot.catalog.manifest.bundles.first(where: { $0.id == previousID }),
            let newBundle = snapshot.catalog.manifest.bundles.first(where: { $0.id == targetID }),
            let old = snapshot.catalog.manifest.components.first(where: { $0.kind == .d3dmetal && oldBundle.components.contains($0.id) }),
            let new = snapshot.catalog.manifest.components.first(where: { $0.kind == .d3dmetal && newBundle.components.contains($0.id) }) else { return nil }
        if isImported { return importedFramework?.version == new.version.rawValue ? nil : new.version }
        guard old.version != new.version else { return nil }
        return new.version
    }

    public func selections(in snapshot: RuntimeCatalogSnapshot) throws -> RuntimeCatalogSelections {
        var selections = snapshot.selections
        if let backend {
            guard let current = selections.bundles[backend], !current.pinned, current.id == previousID,
                snapshot.catalog.recommendedBundles[backend] == targetID else { throw catalogError("Automatic bundle target changed") }
            selections.bundles[backend] = .init(id: targetID)
        } else if let kind {
            guard let current = selections.helpers[kind], !current.pinned, current.id == previousID,
                snapshot.catalog.recommendedHelpers[kind] == targetID else { throw catalogError("Automatic helper target changed") }
            selections.helpers[kind] = .init(id: targetID)
        }
        _ = try snapshot.replacingSelections(selections)
        return selections
    }

    public static func candidates(in snapshot: RuntimeCatalogSnapshot, installedBundleIDs: Set<SafeIdentifier>,
        installedComponentIDs: Set<SafeIdentifier>) -> [Self] {
        // Helpers first: an unpinned ABI helper can then make a bundle compatible.
        var result: [Self] = []
        for kind in snapshot.selections.helpers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let current = snapshot.selections.helpers[kind], !current.pinned, installedComponentIDs.contains(current.id),
                let target = snapshot.catalog.recommendedHelpers[kind], target != current.id else { continue }
            let update = Self(familyID: "component-" + kind.rawValue, previousID: current.id, targetID: target, backend: nil, kind: kind)
            if (try? update.selections(in: snapshot)) != nil { result.append(update) }
        }
        for backend in [RuntimeBackend.dxmt, .d3dmetal] {
            guard let current = snapshot.selections.bundles[backend], !current.pinned, installedBundleIDs.contains(current.id),
                let target = snapshot.catalog.recommendedBundles[backend], target != current.id else { continue }
            let update = Self(familyID: "bundle-" + backend.rawValue, previousID: current.id, targetID: target, backend: backend, kind: nil)
            if (try? update.selections(in: snapshot)) != nil { result.append(update) }
        }
        return result
    }
}
