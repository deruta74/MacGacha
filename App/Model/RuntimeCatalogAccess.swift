// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import DownloadEngine

/// One instance is shared by the model and launch services. Construction performs no I/O.
protocol RuntimeCatalogAccess: Sendable {
    func snapshot() async throws -> RuntimeCatalogSnapshot
    func refresh(force: Bool) async throws -> RuntimeCatalogSnapshot
    func activate(_ selections: RuntimeCatalogSelections) async throws -> RuntimeCatalogSnapshot
}

actor LiveRuntimeCatalogAccess: RuntimeCatalogAccess {
    private let paths: AppPaths
    private let services: any RuntimeServices
    private let baseline: RuntimeManifest?
    private let catalogStore: RuntimeCatalogStore?
    private let fetch: @Sendable () async throws -> Data
    private let now: @Sendable () -> Date
    private var construction: Task<RuntimeCatalogService, any Error>?
    private var refreshing: Task<RuntimeCatalogSnapshot, any Error>?
    private let ownedHTTP: CatalogHTTPClient?

    init(paths: AppPaths, services: any RuntimeServices, baseline: RuntimeManifest? = nil,
        now: @escaping @Sendable () -> Date = Date.init, store: RuntimeCatalogStore? = nil,
        fetch: (@Sendable () async throws -> Data)? = nil) {
        self.paths = paths; self.services = services; self.baseline = baseline; self.now = now; self.catalogStore = store
        if let fetch { self.fetch = fetch; ownedHTTP = nil }
        else {
            let owned = CatalogHTTPClient(); ownedHTTP = owned
            self.fetch = { try await RuntimeCatalogFetcher(client: owned.client).fetch() }
        }
    }
    deinit { construction?.cancel(); refreshing?.cancel() }

    private func service() async throws -> RuntimeCatalogService {
        if let construction { return try await construction.value }
        let paths = paths, services = services, baseline = baseline, catalogStore = catalogStore
        let task = Task {
            let manifest: RuntimeManifest
            if let baseline { manifest = baseline } else { manifest = try await BundledRuntimeManifest.load() }
            let scan = try await services.scan()
            let bundles = try await services.scanBundles(manifest)
            try Task.checkCancellation()
            return RuntimeCatalogService(baseline: manifest, store: catalogStore ?? RuntimeCatalogStore(root: paths.root),
                installedBundleIDs: Set(bundles.keys.compactMap { try? SafeIdentifier($0) }),
                installedComponentIDs: Self.componentIDs(scan, manifest: manifest))
        }
        construction = task
        do { return try await task.value }
        catch { construction = nil; throw error }
    }
    func snapshot() async throws -> RuntimeCatalogSnapshot { try await service().snapshot() }

    func refresh(force: Bool) async throws -> RuntimeCatalogSnapshot {
        if let refreshing { return try await refreshing.value }
        let service = try await service(), paths = paths, now = now(), fetch = fetch
        let task = Task {
            let current = try await service.snapshot()
            let recent = try? await BlockingIO.run {
                let fs = try ContainedFileSystem(root: paths.root)
                let bytes = try fs.readFile(at: SafeRelativePath("RuntimeCatalog/last-check.json"), maxBytes: 1024)
                let date = try JSONDecoder().decode(Date.self, from: bytes)
                let age = now.timeIntervalSince(date)
                return age.isFinite && age >= 0 && age < 24 * 60 * 60
            }
            if !force && recent == true { return current }
            let metadata = try await fetch()
            try Task.checkCancellation()
            let result = try await service.accept(metadata: metadata)
            try await BlockingIO.run {
                let fs = try ContainedFileSystem(root: paths.root)
                try fs.writeAtomically(JSONEncoder().encode(now), to: SafeRelativePath("RuntimeCatalog/last-check.json"))
            }
            return result
        }
        refreshing = task
        defer { refreshing = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func activate(_ selections: RuntimeCatalogSelections) async throws -> RuntimeCatalogSnapshot {
        let service = try await service(), current = try await service.snapshot()
        let bundles = try await services.scanBundles(current.catalog.manifest)
        let scan = try await services.scan()
        try Task.checkCancellation()
        return try await service.activate(selections: selections,
            installedBundleIDs: Set(bundles.keys.compactMap { try? SafeIdentifier($0) }),
            installedComponentIDs: Self.componentIDs(scan, manifest: current.catalog.manifest))
    }
    private static func componentIDs(_ scan: RuntimeScan, manifest: RuntimeManifest) -> Set<SafeIdentifier> {
        Set(manifest.components.filter { component in
            scan.components.contains { $0.kind == component.kind && $0.version == component.version.rawValue }
        }.map(\.id))
    }
}

private final class CatalogHTTPClient: Sendable {
    let client: URLSessionHTTPClient
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
        client = URLSessionHTTPClient(configuration: configuration, sessionCount: 1,
            highWaterMark: 128 << 10, lowWaterMark: 32 << 10, redirectPolicy: RuntimeCatalogFetcher.allows)
    }
    deinit { client.invalidate() }
}
