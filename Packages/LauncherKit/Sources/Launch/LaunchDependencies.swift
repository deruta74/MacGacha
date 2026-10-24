// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

public struct LaunchRuntimeSelection: Sendable {
    public let bundle: InstalledRuntimeBundle
    public let componentIDs: [String]
    public let componentRoots: [ComponentKind: URL]
    public let compatibilityComponentIDs: [ComponentKind: String]
    public init(bundle: InstalledRuntimeBundle, componentIDs: [String], componentRoots: [ComponentKind: URL],
        compatibilityComponentIDs: [ComponentKind: String] = [:]) {
        self.bundle = bundle; self.componentIDs = componentIDs; self.componentRoots = componentRoots
        self.compatibilityComponentIDs = compatibilityComponentIDs
    }
}

public protocol LaunchRuntimeProviding: Sendable {
    func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection
}
public protocol LaunchPrefixProviding: Sendable {
    func prefixURL(game: String, bundle: InstalledRuntimeBundle) async throws -> URL
    func createPrefix(game: String, bundle: InstalledRuntimeBundle) async throws -> URL
}
public protocol LaunchPreparing: Sendable {
    func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws
}

extension PrefixManager: LaunchPrefixProviding {
    public func prefixURL(game: String, bundle: InstalledRuntimeBundle) async throws -> URL {
        try prefixURL(game: game, bundle: bundle.id)
    }
}
extension LaunchPreparation: LaunchPreparing {}

/// Selection validates existing installations; Play never downloads a runtime implicitly.
public struct LiveLaunchRuntimes: LaunchRuntimeProviding {
    private let manifest: RuntimeManifest
    private let manager: RuntimeBundleManager
    private let store: RuntimeStore
    public init(manifest: RuntimeManifest, manager: RuntimeBundleManager, store: RuntimeStore) {
        self.manifest = manifest; self.manager = manager; self.store = store
    }
    public func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection {
        guard let definition = manifest.defaultBundle(for: settings.backend),
            let bundle = try await manager.installed(definition) else { throw LauncherError.io("Install the selected runtime bundle first") }
        let (roots, ids) = try await BlockingIO.run {
            let records = try store.installed()
            var roots: [ComponentKind: URL] = [:], ids: [ComponentKind: String] = [:]
            for component in manifest.components where [.jadeite, .steamShim].contains(component.kind) || component.id.rawValue == Crypt32Fix.componentID {
                if records.contains(where: { $0.kind == component.kind && $0.version == component.version.rawValue }) {
                    roots[component.kind] = store.installURL(for: component); ids[component.kind] = component.id.rawValue
                }
            }
            return (roots, ids)
        }
        return LaunchRuntimeSelection(bundle: bundle, componentIDs: definition.components.map(\.rawValue),
            componentRoots: roots, compatibilityComponentIDs: ids)
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
