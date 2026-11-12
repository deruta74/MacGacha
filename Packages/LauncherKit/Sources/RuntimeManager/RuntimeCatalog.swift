// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A profile names a recipe/layout compiled into this app. Metadata can select
/// another immutable release using that profile, but cannot define a new recipe.
public struct RuntimeCatalogBundleBinding: Codable, Sendable {
    public let bundleID: SafeIdentifier
    public let profileID: SafeIdentifier
    public init(bundleID: SafeIdentifier, profileID: SafeIdentifier) {
        self.bundleID = bundleID; self.profileID = profileID
    }
}

public struct RuntimeCatalogHelperBinding: Codable, Sendable {
    public let componentID: SafeIdentifier
    public let profileIDs: [SafeIdentifier]
    public init(componentID: SafeIdentifier, profileIDs: [SafeIdentifier]) {
        self.componentID = componentID; self.profileIDs = profileIDs
    }
}

/// The wire catalog is deliberately data-only. Component IDs, bundle IDs and
/// compatibility bindings are immutable, including entries absent from a later catalog.
public struct RuntimeCatalog: Codable, Sendable {
    public static let clientContract = "macgacha-runtime-v1"
    public static let metadataLimit = 1 << 20
    public let schemaVersion: Int
    public let revision: UInt64
    public let clientContract: String
    public let manifest: RuntimeManifest
    public let bundleBindings: [RuntimeCatalogBundleBinding]
    public let helperBindings: [RuntimeCatalogHelperBinding]
    public let recommendedBundles: [RuntimeBackend: SafeIdentifier]
    public let recommendedHelpers: [ComponentKind: SafeIdentifier]

    public init(schemaVersion: Int = 1, revision: UInt64, clientContract: String = Self.clientContract,
        manifest: RuntimeManifest, bundleBindings: [RuntimeCatalogBundleBinding],
        helperBindings: [RuntimeCatalogHelperBinding], recommendedBundles: [RuntimeBackend: SafeIdentifier],
        recommendedHelpers: [ComponentKind: SafeIdentifier]) {
        self.schemaVersion = schemaVersion; self.revision = revision; self.clientContract = clientContract
        self.manifest = manifest; self.bundleBindings = bundleBindings; self.helperBindings = helperBindings
        self.recommendedBundles = recommendedBundles; self.recommendedHelpers = recommendedHelpers
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, revision, clientContract, manifest, bundleBindings, helperBindings, recommendedBundles, recommendedHelpers
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundleNames = try c.decode([String: SafeIdentifier].self, forKey: .recommendedBundles)
        let helperNames = try c.decode([String: SafeIdentifier].self, forKey: .recommendedHelpers)
        var bundles: [RuntimeBackend: SafeIdentifier] = [:]
        var helpers: [ComponentKind: SafeIdentifier] = [:]
        for (key, value) in bundleNames {
            guard let backend = RuntimeBackend(rawValue: key) else { throw catalogError("Unknown backend") }
            bundles[backend] = value
        }
        for (key, value) in helperNames {
            guard let kind = ComponentKind(rawValue: key) else { throw catalogError("Unknown helper kind") }
            helpers[kind] = value
        }
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion), revision: try c.decode(UInt64.self, forKey: .revision),
            clientContract: try c.decode(String.self, forKey: .clientContract), manifest: try c.decode(RuntimeManifest.self, forKey: .manifest),
            bundleBindings: try c.decode([RuntimeCatalogBundleBinding].self, forKey: .bundleBindings),
            helperBindings: try c.decode([RuntimeCatalogHelperBinding].self, forKey: .helperBindings),
            recommendedBundles: bundles, recommendedHelpers: helpers)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(revision, forKey: .revision)
        try c.encode(clientContract, forKey: .clientContract); try c.encode(manifest, forKey: .manifest)
        try c.encode(bundleBindings, forKey: .bundleBindings); try c.encode(helperBindings, forKey: .helperBindings)
        try c.encode(Dictionary(uniqueKeysWithValues: recommendedBundles.map { ($0.key.rawValue, $0.value) }), forKey: .recommendedBundles)
        try c.encode(Dictionary(uniqueKeysWithValues: recommendedHelpers.map { ($0.key.rawValue, $0.value) }), forKey: .recommendedHelpers)
    }

    /// Builds the app-owned starting catalog; array order retains the bundled recommendation.
    public static func bundled(_ manifest: RuntimeManifest) -> Self {
        var bundles: [RuntimeBackend: SafeIdentifier] = [:]
        for bundle in manifest.bundles where bundles[bundle.backend] == nil { bundles[bundle.backend] = bundle.id }
        var helpers: [ComponentKind: SafeIdentifier] = [:]
        let bindings = manifest.components.filter { catalogHelperKinds.contains($0.kind) }.map { component in
            if helpers[component.kind] == nil { helpers[component.kind] = component.id }
            let profiles = manifest.bundles.filter { bundle in
                switch component.kind {
                case .crypt32Fix: return (component.id.rawValue == Crypt32Fix.componentID ? Crypt32Fix.bundleIDs : [Crypt32Fix.bundleID]).contains(bundle.id.rawValue)
                case .surroundAudio: return (component.id.rawValue == SurroundAudio.componentID ? SurroundAudio.bundleIDs : [SurroundAudio.bundleID]).contains(bundle.id.rawValue)
                default: return true
                }
            }.map(\.id)
            return RuntimeCatalogHelperBinding(componentID: component.id, profileIDs: profiles)
        }
        return Self(revision: 0, manifest: manifest,
            bundleBindings: manifest.bundles.map { RuntimeCatalogBundleBinding(bundleID: $0.id, profileID: $0.id) },
            helperBindings: bindings, recommendedBundles: bundles, recommendedHelpers: helpers)
    }
}

public struct RuntimeCatalogSelection: Codable, Sendable, Equatable {
    public let id: SafeIdentifier
    public let pinned: Bool
    public init(id: SafeIdentifier, pinned: Bool = false) { self.id = id; self.pinned = pinned }
}

public struct RuntimeCatalogSelections: Codable, Sendable, Equatable {
    public var bundles: [RuntimeBackend: RuntimeCatalogSelection]
    public var helpers: [ComponentKind: RuntimeCatalogSelection]
    public init(bundles: [RuntimeBackend: RuntimeCatalogSelection], helpers: [ComponentKind: RuntimeCatalogSelection]) {
        self.bundles = bundles; self.helpers = helpers
    }
}

public struct RuntimeCatalogSnapshot: Sendable {
    /// Full validated historical catalog for version rows and explicit rollback.
    public let catalog: RuntimeCatalog
    public let selections: RuntimeCatalogSelections
    /// Only active versions, shared by setup and launch. Refresh never changes it.
    public let manifest: RuntimeManifest
    private let contract: RuntimeCatalogContract
    private let compiledHelperBindings: [RuntimeCatalogHelperBinding]
    /// Captures and validates a proposed setup/launch selection without I/O or
    /// activation. Installing and committing this plan remain separate actions.
    public func replacingSelections(_ selections: RuntimeCatalogSelections) throws -> RuntimeCatalogSnapshot {
        try RuntimeCatalogSnapshot(catalog: catalog, selections: selections, contract: contract)
    }
    public var recommendedSelections: RuntimeCatalogSelections {
        RuntimeCatalogSelections(bundles: catalog.recommendedBundles.mapValues { RuntimeCatalogSelection(id: $0) },
            helpers: catalog.recommendedHelpers.mapValues { RuntimeCatalogSelection(id: $0) })
    }
    public func selectedBundle(for backend: RuntimeBackend) -> RuntimeBundle? {
        selections.bundles[backend].flatMap { selection in catalog.manifest.bundles.first { $0.id == selection.id } }
    }
    public func selectedHelper(for kind: ComponentKind) -> RuntimeComponent? {
        selections.helpers[kind].flatMap { catalog.manifest.component(id: $0.id) }
    }
    public func recommendedBundle(for backend: RuntimeBackend) -> RuntimeBundle? {
        catalog.recommendedBundles[backend].flatMap { id in catalog.manifest.bundles.first { $0.id == id } }
    }
    public func recommendedHelper(for kind: ComponentKind) -> RuntimeComponent? {
        catalog.recommendedHelpers[kind].flatMap { catalog.manifest.component(id: $0) }
    }
    public func profile(for bundleID: SafeIdentifier) -> SafeIdentifier? {
        catalog.bundleBindings.first { $0.bundleID == bundleID }?.profileID
    }
    public func helper(kind: ComponentKind, for bundleID: SafeIdentifier) -> RuntimeComponent? {
        guard let profile = profile(for: bundleID), let component = selectedHelper(for: kind),
            (catalog.helperBindings + compiledHelperBindings).contains(where: {
                $0.componentID == component.id && $0.profileIDs.contains(profile)
            }) else { return nil }
        return component
    }

    init(catalog: RuntimeCatalog, selections: RuntimeCatalogSelections, contract: RuntimeCatalogContract) throws {
        try contract.validate(selections, in: catalog)
        let bundles = [RuntimeBackend.dxmt, .d3dmetal].compactMap { backend in
            selections.bundles[backend].flatMap { selected in catalog.manifest.bundles.first { $0.id == selected.id } }
        }
        let ids = Set(bundles.flatMap(\.components) + selections.helpers.values.map(\.id))
        self.catalog = catalog; self.selections = selections
        self.contract = contract
        compiledHelperBindings = contract.baseline.helperBindings
        manifest = try RuntimeManifest(components: catalog.manifest.components.filter { ids.contains($0.id) }, bundles: bundles)
    }
}

let catalogHelperKinds: Set<ComponentKind> = [.jadeite, .steamShim, .crypt32Fix, .surroundAudio, .genshinFps]
func catalogError(_ message: String) -> LauncherError { .io("Runtime catalog: " + message) }

func catalogBytes(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
