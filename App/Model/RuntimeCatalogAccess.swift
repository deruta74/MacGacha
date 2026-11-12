// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import DownloadEngine

/// One instance is shared by the model and launch services. Construction performs no I/O.
protocol RuntimeCatalogAccess: Sendable {
    func snapshot() async throws -> RuntimeCatalogSnapshot
    func persistSelection() async throws -> RuntimeCatalogSnapshot
    func refresh(force: Bool) async throws -> RuntimeCatalogSnapshot
    func activate(_ selections: RuntimeCatalogSelections) async throws -> RuntimeCatalogSnapshot
}

actor LiveRuntimeCatalogAccess: RuntimeCatalogAccess {
    private let paths: AppPaths
    private let services: any RuntimeServices
    private let baseline: RuntimeManifest?
    private let catalogStore: RuntimeCatalogStore?
    private let fetch: @Sendable () async throws -> RuntimeSignedCatalog
    private let signatureVerifier: RuntimeCatalogSignatureVerifier?
    private let now: @Sendable () -> Date
    private var construction: Task<RuntimeCatalogService, any Error>?
    private var refreshing: Task<RuntimeCatalogSnapshot, any Error>?
    private let ownedHTTP: CatalogHTTPClient?

    init(signatureVerifier: RuntimeCatalogSignatureVerifier? = RuntimeCatalogSigningKeys.verifier,
        paths: AppPaths, services: any RuntimeServices, baseline: RuntimeManifest? = nil,
        now: @escaping @Sendable () -> Date = Date.init, store: RuntimeCatalogStore? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fetch: (@Sendable () async throws -> Data)? = nil) {
        self.paths = paths; self.services = services; self.baseline = baseline; self.now = now; self.catalogStore = store
        self.signatureVerifier = signatureVerifier
        if let fetch { self.fetch = { RuntimeSignedCatalog(body: try await fetch(), signature: Data()) }; ownedHTTP = nil }
        else if let url = Self.debugCatalogURL(arguments: arguments) {
            ownedHTTP = nil
            self.fetch = {
                try await BlockingIO.run {
                    let fs = try ContainedFileSystem(root: url.deletingLastPathComponent())
                    let body = try fs.readFile(at: SafeRelativePath(url.lastPathComponent), maxBytes: RuntimeCatalogFetcher.byteLimit)
                    if signatureVerifier == nil { return RuntimeSignedCatalog(body: body, signature: Data()) }
                    let signature = try fs.readFile(at: SafeRelativePath(url.lastPathComponent + ".sig"), maxBytes: 1024)
                    return try RuntimeSignedCatalog(body: body, signature: RuntimeCatalogSignatureVerifier.decodeDetached(signature))
                }
            }
        }
        else {
            let owned = CatalogHTTPClient(); ownedHTTP = owned
            self.fetch = { try await RuntimeCatalogFetcher(client: owned.client).fetchSigned() }
        }
    }
    deinit { construction?.cancel(); refreshing?.cancel() }

    static func debugCatalogURL(arguments: [String]) -> URL? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-MacGachaDebugCatalog"),
            arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
        #else
        return nil
        #endif
    }

    private func service() async throws -> RuntimeCatalogService {
        if let construction { return try await construction.value }
        let paths = paths, services = services, baseline = baseline, catalogStore = catalogStore, signatureVerifier = signatureVerifier
        let task = Task {
            let manifest: RuntimeManifest
            if let baseline { manifest = baseline } else { manifest = try await BundledRuntimeManifest.load() }
            let scan = try await services.scan()
            let bundles = try await services.scanBundles(manifest)
            try Task.checkCancellation()
            return RuntimeCatalogService(baseline: manifest, store: catalogStore ?? RuntimeCatalogStore(root: paths.root),
                installedBundleIDs: Set(bundles.keys.compactMap { try? SafeIdentifier($0) }),
                installedComponentIDs: Self.componentIDs(scan, manifest: manifest), signatureVerifier: signatureVerifier)
        }
        construction = task
        do { return try await task.value }
        catch { construction = nil; throw error }
    }
    func snapshot() async throws -> RuntimeCatalogSnapshot { try await service().snapshot() }

    func persistSelection() async throws -> RuntimeCatalogSnapshot { try await service().persistSelection() }

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
            let result = try await service.accept(metadata: metadata.body, signature: metadata.signature)
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

enum RuntimeCatalogSigningKeys {
    static var verifier: RuntimeCatalogSignatureVerifier {
        let value = Bundle.main.object(forInfoDictionaryKey: "RuntimeCatalogPublicEdKeys") as? String ?? ""
        let keys = value.split(separator: ",").compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return RuntimeCatalogSignatureVerifier(publicKeys: keys.filter { $0.count == 32 })
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
