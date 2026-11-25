// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

public struct LaunchRuntimeSelection: Sendable {
    public let bundle: InstalledRuntimeBundle
    /// Compiled recipe identity; installation, journal and pins retain the actual bundle ID.
    public let runtimeProfileID: String
    public let componentIDs: [String]
    public let componentRoots: [ComponentKind: URL]
    public let compatibilityComponentIDs: [ComponentKind: String]
    public init(bundle: InstalledRuntimeBundle, componentIDs: [String], componentRoots: [ComponentKind: URL],
        compatibilityComponentIDs: [ComponentKind: String] = [:], runtimeProfileID: String? = nil) {
        self.bundle = bundle; self.runtimeProfileID = runtimeProfileID ?? bundle.id.rawValue
        self.componentIDs = componentIDs; self.componentRoots = componentRoots
        self.compatibilityComponentIDs = compatibilityComponentIDs
    }
}

public protocol LaunchRuntimeProviding: Sendable {
    func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection
    func selection(for configuration: LaunchConfiguration) async throws -> LaunchRuntimeSelection
}

extension LaunchRuntimeProviding {
    public func selection(for configuration: LaunchConfiguration) async throws -> LaunchRuntimeSelection {
        let result = try await selection(for: configuration.settings)
        guard configuration.matches(result) else { throw LaunchConfigurationError.previousUnavailable }
        return result
    }
}

extension LaunchConfiguration {
    func selectingPrevious(in captured: RuntimeCatalogSnapshot) throws -> RuntimeCatalogSnapshot {
        // Pins govern persistent choices. A one-shot trial may pair unused helpers
        // for the old ABI, while every helper actually used remains exact.
        var unpinned = captured.selections
        for (kind, selected) in unpinned.helpers { unpinned.helpers[kind] = .init(id: selected.id) }
        let compatible = try captured.replacingSelections(unpinned).selectingBundle(id: SafeIdentifier(bundleID), pinned: false)
        var selections = compatible.selections
        for (kind, id) in compatibilityComponentIDs { selections.helpers[kind] = .init(id: try SafeIdentifier(id)) }
        return try compatible.replacingSelections(selections)
    }
    func matches(_ selection: LaunchRuntimeSelection) -> Bool {
        bundleID == selection.bundle.id.rawValue && runtimeDigest == selection.bundle.digest &&
            runtimeProfileID == selection.runtimeProfileID && Set(componentIDs) == Set(selection.componentIDs) &&
            compatibilityComponentIDs.allSatisfy { selection.compatibilityComponentIDs[$0.key] == $0.value }
    }
}
public protocol LaunchPrefixProviding: Sendable {
    func prefixURL(game: String, bundle: InstalledRuntimeBundle) async throws -> URL
    func createPrefix(game: String, bundle: InstalledRuntimeBundle) async throws -> URL
}
public protocol LaunchPreparing: Sendable {
    @discardableResult func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome
}

extension PrefixManager: LaunchPrefixProviding {
    public func prefixURL(game: String, bundle: InstalledRuntimeBundle) async throws -> URL {
        try prefixURL(game: game, bundle: bundle.id)
    }
}
extension LaunchPreparation: LaunchPreparing {}

/// Selection validates existing installations; Play never downloads a runtime implicitly.
public struct LiveLaunchRuntimes: LaunchRuntimeProviding {
    private let manifest: RuntimeManifest?
    private let paths: AppPaths?
    private let snapshot: (@Sendable () async throws -> RuntimeCatalogSnapshot)?
    private let manager: RuntimeBundleManager
    private let store: RuntimeStore
    public init(manifest: RuntimeManifest, manager: RuntimeBundleManager, store: RuntimeStore) {
        self.manifest = manifest; self.paths = nil; self.snapshot = nil; self.manager = manager; self.store = store
    }
    public init(paths: AppPaths, manager: RuntimeBundleManager, store: RuntimeStore, snapshot: @escaping @Sendable () async throws -> RuntimeCatalogSnapshot) {
        self.manifest = nil; self.paths = paths; self.snapshot = snapshot; self.manager = manager; self.store = store
    }
    public func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection {
        try await selection(for: settings, snapshot: try await snapshot?())
    }
    public func selection(for configuration: LaunchConfiguration) async throws -> LaunchRuntimeSelection {
        var current = try await snapshot?()
        if let captured = current { current = try configuration.selectingPrevious(in: captured) }
        let result = try await selection(for: configuration.settings, snapshot: current)
        guard configuration.matches(result) else { throw LaunchConfigurationError.previousUnavailable }
        return result
    }
    private func selection(for settings: LaunchSettings, snapshot current: RuntimeCatalogSnapshot?) async throws -> LaunchRuntimeSelection {
        guard let manifest = current?.manifest ?? manifest else { throw LauncherError.io("Runtime catalog unavailable") }
        let selectedManager: RuntimeBundleManager
        if let paths {
            let consent = ConsentStore(url: paths.consent, root: paths.root)
            selectedManager = RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: ComponentInstaller(store: store, consent: consent))
        } else { selectedManager = manager }
        guard let definition = manifest.defaultBundle(for: settings.backend),
            let bundle = try await selectedManager.installed(definition) else { throw LaunchConfigurationError.runtimeUnavailable }
        let (roots, ids) = try await BlockingIO.run {
            let records = try store.installed()
            var roots: [ComponentKind: URL] = [:], ids: [ComponentKind: String] = [:]
            for component in manifest.components where [.jadeite, .steamShim, .crypt32Fix, .surroundAudio, .genshinFps].contains(component.kind) {
                if let current {
                    guard current.helper(kind: component.kind, for: definition.id)?.id == component.id else { continue }
                } else if ![ComponentKind.jadeite, .steamShim].contains(component.kind) &&
                    ![Crypt32Fix.componentID, SurroundAudio.recommendedComponentID(for: definition.id.rawValue), GenshinFps.componentID].contains(component.id.rawValue) { continue }
                if records.contains(where: { $0.kind == component.kind && $0.version == component.version.rawValue }) {
                    roots[component.kind] = store.installURL(for: component); ids[component.kind] = component.id.rawValue
                }
            }
            return (roots, ids)
        }
        return LaunchRuntimeSelection(bundle: bundle, componentIDs: definition.components.map(\.rawValue),
            componentRoots: roots, compatibilityComponentIDs: ids, runtimeProfileID: current?.profile(for: definition.id)?.rawValue)
    }
}

package protocol LaunchSessionProxy: Sendable {
    var port: UInt16 { get }
    func stop() async
}
extension SessionProxy: LaunchSessionProxy {}

package struct ClockSessionLogTicker: SessionLogTicker {
    let clock: any Clock<Duration>
    package func start(_ action: @escaping @Sendable () -> Void) -> LogTickCancellation {
        let clock = clock
        let worker = Task {
            do {
                while !Task.isCancelled {
                    try await clock.sleep(for: .seconds(5))
                    try Task.checkCancellation()
                    try await BlockingIO.run { action() }
                }
            } catch { }
        }
        return LogTickCancellation { worker.cancel() }
    }
}

extension Optional where Wrapped == LaunchConfiguration {
    func mapSelection(using runtimes: any LaunchRuntimeProviding, settings: LaunchSettings) async throws -> LaunchRuntimeSelection {
        if let configuration = self { return try await runtimes.selection(for: configuration) }
        return try await runtimes.selection(for: settings)
    }
}
