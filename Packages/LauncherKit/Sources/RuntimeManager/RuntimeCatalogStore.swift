// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A failed atomic write may already have replaced the file. This value exposes
/// the reconciled visible state; nil means reads must recover before further use.
public struct RuntimeCatalogPublicationFailure: Error, Sendable {
    public let persistedSnapshot: RuntimeCatalogSnapshot?
}

/// Synchronous persistence, invoked only through BlockingIO by the service.
/// Writers may throw after replacement (e.g. parent-directory fsync failure).
/// The service always rereads after a failed write before exposing more state.
public struct RuntimeCatalogStore: Sendable {
    public static let stateLimit = 4 << 20
    private let reader: @Sendable () throws -> Data?
    private let writer: @Sendable (Data) throws -> Void

    public init(root: URL, path: SafeRelativePath = try! SafeRelativePath("runtime-catalog-state.json")) {
        reader = {
            let fs = try ContainedFileSystem(root: root)
            return try RuntimeJSONFile.read(path, in: fs, limit: Self.stateLimit)
        }
        writer = { bytes in
            guard bytes.count <= Self.stateLimit else { throw catalogError("State exceeds size limit") }
            let fs = try ContainedFileSystem(root: root)
            try fs.writeAtomically(bytes, to: path)
        }
    }
    public init(read: @escaping @Sendable () throws -> Data?, write: @escaping @Sendable (Data) throws -> Void) {
        reader = read; writer = write
    }
    func load() throws -> RuntimeCatalogStoredState? {
        guard let bytes = try reader() else { return nil }
        guard bytes.count <= Self.stateLimit else { throw catalogError("State exceeds size limit") }
        let state = try JSONDecoder().decode(RuntimeCatalogStoredState.self, from: bytes)
        guard state.schemaVersion == 1 else { throw catalogError("Unsupported state schema") }
        return state
    }
    func save(_ state: RuntimeCatalogStoredState) throws {
        let bytes = try catalogBytes(state)
        guard bytes.count <= Self.stateLimit else { throw catalogError("State exceeds size limit") }
        try writer(bytes)
    }
}

struct RuntimeCatalogStoredState: Codable, Sendable {
    let schemaVersion: Int
    let catalog: RuntimeCatalog
    let selections: RuntimeCatalogSelections
    init(_ snapshot: RuntimeCatalogSnapshot) {
        schemaVersion = 1; catalog = snapshot.catalog; selections = snapshot.selections
    }
}

/// Share one instance between app setup and launch. Mutations are serialized
/// across filesystem awaits, and publish memory only after atomic persistence.
public actor RuntimeCatalogService {
    private let contract: RuntimeCatalogContract
    private let store: RuntimeCatalogStore?
    private let installedBundleIDs: Set<SafeIdentifier>
    private let installedComponentIDs: Set<SafeIdentifier>
    private var current: RuntimeCatalogSnapshot?
    private var hasPersistedState = false
    private var recoveryRequired = false
    private var recoveryFallback: RuntimeCatalogSnapshot?
    private var mutating = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(baseline: RuntimeManifest, store: RuntimeCatalogStore? = nil,
        installedBundleIDs: Set<SafeIdentifier> = [], installedComponentIDs: Set<SafeIdentifier> = []) {
        contract = RuntimeCatalogContract(baseline); self.store = store
        self.installedBundleIDs = installedBundleIDs; self.installedComponentIDs = installedComponentIDs
    }

    public func snapshot() async throws -> RuntimeCatalogSnapshot {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        return try await loaded()
    }

    /// Validation/refresh only. Existing choices, including unpinned choices,
    /// remain active until an explicit successful installation or rollback.
    @discardableResult public func accept(metadata: Data) async throws -> RuntimeCatalogSnapshot {
        guard metadata.count <= RuntimeCatalog.metadataLimit else { throw catalogError("Metadata exceeds size limit") }
        let update = try JSONDecoder().decode(RuntimeCatalog.self, from: metadata)
        await acquire(); defer { release() }
        try Task.checkCancellation()
        let previous = try await loaded()
        let catalog = try contract.merging(update, into: previous.catalog)
        let next = try RuntimeCatalogSnapshot(catalog: catalog, selections: previous.selections, contract: contract)
        return try await publish(next)
    }

    /// The caller must verify these installed IDs through the runtime stores.
    /// IDs are evidence of a completed install, never merely a download plan.
    @discardableResult public func selectBundle(id: SafeIdentifier, pinned: Bool,
        installedBundleIDs: Set<SafeIdentifier>) async throws -> RuntimeCatalogSnapshot {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        let previous = try await loaded()
        guard installedBundleIDs.contains(id), let bundle = previous.catalog.manifest.bundles.first(where: { $0.id == id }) else {
            throw catalogError("Selected bundle is not verified installed")
        }
        var selections = previous.selections
        selections.bundles[bundle.backend] = RuntimeCatalogSelection(id: id, pinned: pinned)
        return try await publish(RuntimeCatalogSnapshot(catalog: previous.catalog, selections: selections, contract: contract))
    }

    @discardableResult public func selectHelper(id: SafeIdentifier, pinned: Bool,
        installedComponentIDs: Set<SafeIdentifier>) async throws -> RuntimeCatalogSnapshot {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        let previous = try await loaded()
        guard installedComponentIDs.contains(id), let helper = previous.catalog.manifest.component(id: id), catalogHelperKinds.contains(helper.kind) else {
            throw catalogError("Selected helper is not verified installed")
        }
        var selections = previous.selections
        selections.helpers[helper.kind] = RuntimeCatalogSelection(id: id, pinned: pinned)
        return try await publish(RuntimeCatalogSnapshot(catalog: previous.catalog, selections: selections, contract: contract))
    }

    /// Commits a captured setup plan as one transaction. Unchanged selections
    /// need not be installed (e.g. an opt-in FPS helper that was never enabled).
    /// All changed versions must have independently verified installed receipts.
    @discardableResult public func activate(selections: RuntimeCatalogSelections,
        installedBundleIDs: Set<SafeIdentifier>, installedComponentIDs: Set<SafeIdentifier>) async throws -> RuntimeCatalogSnapshot {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        let previous = try await loaded()
        for (backend, selected) in selections.bundles where previous.selections.bundles[backend]?.id != selected.id {
            guard installedBundleIDs.contains(selected.id) else { throw catalogError("Activation bundle is not verified installed") }
        }
        for (kind, selected) in selections.helpers where previous.selections.helpers[kind]?.id != selected.id {
            guard installedComponentIDs.contains(selected.id) else { throw catalogError("Activation helper is not verified installed") }
        }
        return try await publish(RuntimeCatalogSnapshot(catalog: previous.catalog, selections: selections, contract: contract))
    }

    private func loaded() async throws -> RuntimeCatalogSnapshot {
        if recoveryRequired { return try await reconcilePersistedState() }
        if let current { return current }
        try Task.checkCancellation()
        try contract.validate(contract.baseline)
        if let store {
            do {
                let state = try await BlockingIO.run { try store.load() }
                try Task.checkCancellation()
                if let state {
                    let restored = try contract.restoring(state)
                    try Task.checkCancellation()
                    hasPersistedState = true
                    current = restored; return restored
                }
            } catch {
                if error is CancellationError || (error as? LauncherError) == .cancelled || Task.isCancelled { throw error }
                // Startup corruption/unavailability can use bundled defaults.
                // Publication recovery below must instead block until readable.
            }
        }
        try Task.checkCancellation()
        var selections = RuntimeCatalogSelections(
            bundles: contract.baseline.recommendedBundles.mapValues { RuntimeCatalogSelection(id: $0) },
            helpers: contract.baseline.recommendedHelpers.mapValues { RuntimeCatalogSelection(id: $0) })
        for backend in selections.bundles.keys {
            if let recommended = selections.bundles[backend], !installedBundleIDs.contains(recommended.id),
                let working = contract.baseline.manifest.bundles.first(where: { $0.backend == backend && installedBundleIDs.contains($0.id) }) {
                selections.bundles[backend] = RuntimeCatalogSelection(id: working.id)
            }
        }
        for kind in selections.helpers.keys {
            if let recommended = selections.helpers[kind], !installedComponentIDs.contains(recommended.id),
                let working = contract.baseline.manifest.components.first(where: { $0.kind == kind && installedComponentIDs.contains($0.id) }) {
                selections.helpers[kind] = RuntimeCatalogSelection(id: working.id)
            }
        }
        let initial = try RuntimeCatalogSnapshot(catalog: contract.baseline, selections: selections, contract: contract)
        try Task.checkCancellation()
        current = initial; return initial
    }

    private func publish(_ snapshot: RuntimeCatalogSnapshot) async throws -> RuntimeCatalogSnapshot {
        try Task.checkCancellation()
        if let store {
            do {
                try await BlockingIO.run { try store.save(RuntimeCatalogStoredState(snapshot)) }
                hasPersistedState = true
            } catch {
                recoveryFallback = hasPersistedState ? nil : current
                recoveryRequired = true
                current = nil
                // A failed write can already be visible. Reconcile even when
                // the caller was cancelled, retaining the mutation gate.
                let recovered = try? await reconcilePersistedState()
                throw RuntimeCatalogPublicationFailure(persistedSnapshot: recovered)
            }
        }
        // A cancellation after durable publication cannot roll the disk back:
        // memory must reflect the same completed atomic transaction.
        current = snapshot
        return snapshot
    }

    private func reconcilePersistedState() async throws -> RuntimeCatalogSnapshot {
        guard let store else { throw RuntimeCatalogPublicationFailure(persistedSnapshot: nil) }
        let contract = self.contract
        let fallback = recoveryFallback
        let worker = Task.detached {
            try await BlockingIO.run {
                if let state = try store.load() { return (try contract.restoring(state), true) }
                // A first write that failed before publication may still have
                // no state file; only that previously observed absence permits
                // keeping its bundled initial snapshot.
                if let fallback { return (fallback, false) }
                throw catalogError("Published state is unavailable")
            }
        }
        do {
            let (restored, persisted) = try await worker.value
            current = restored; hasPersistedState = persisted
            recoveryRequired = false; recoveryFallback = nil
            return restored
        } catch {
            current = nil
            throw RuntimeCatalogPublicationFailure(persistedSnapshot: nil)
        }
    }

    private func acquire() async {
        if !mutating { mutating = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { mutating = false } else { waiters.removeFirst().resume() }
    }
}
