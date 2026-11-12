// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import RuntimeManager
import TestSupport

@Suite struct RuntimeCatalogTests {
    @Test func pinnedOldD3DMetalWithNewHelpersIsValidSelection() async throws {
        let fixture = try CatalogFixture()
        let service = RuntimeCatalogService(baseline: fixture.baseline)
        let old = try SafeIdentifier(SurroundAudio.bundleID)
        let snapshot = try await service.selectBundle(id: old, pinned: true, installedBundleIDs: [old])
        #expect(snapshot.selections.bundles[.d3dmetal]?.pinned == true)
        #expect(snapshot.selectedHelper(for: .surroundAudio)?.id.rawValue == SurroundAudio.componentID)
    }
    @Test func revision2AcceptedByCurrentBaseline() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("App/Resources/runtime-manifest.json")))
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json")))
        try RuntimeCatalogContract(manifest).validate(catalog)
        #expect(catalog.revision == 2)
        #expect(catalog.recommendedBundles[.dxmt]?.rawValue == "dxmt-wine11.20mg1.0-dxmt0.80")
    }

    @Test func initialMigrationCanBePersistedBeforeInstalledEvidenceChanges() async throws {
        let f = try CatalogFixture(), bytes = Mutex<Data?>(nil), writes = Mutex(0)
        let old = try f.component(kind: .surroundAudio, version: "wine-11.20-1")
        let baseline = try RuntimeManifest(components: f.baseline.components + [old], bundles: f.baseline.bundles)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
            bytes.withLock { $0 = data }; writes.withLock { $0 += 1 }
        })
        let service = RuntimeCatalogService(baseline: baseline, store: store, installedComponentIDs: [old.id])
        #expect(try await service.snapshot().selectedHelper(for: .surroundAudio)?.id == old.id)
        #expect(bytes.withLock { $0 } == nil)
        _ = try await service.persistSelection()
        _ = try await service.persistSelection()
        #expect(writes.withLock { $0 } == 1)
        let reopened = RuntimeCatalogService(baseline: baseline, store: store, installedComponentIDs: [try SafeIdentifier(SurroundAudio.componentID)])
        #expect(try await reopened.snapshot().selectedHelper(for: .surroundAudio)?.id == old.id)
    }

    @Test func initialPersistenceFailureDoesNotClaimDurabilityAndCanRetry() async throws {
        let f = try CatalogFixture(), bytes = Mutex<Data?>(nil), fail = Mutex(true)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
            if fail.withLock({ $0 }) { throw LauncherError.io("before publication") }
            bytes.withLock { $0 = data }
        })
        let service = RuntimeCatalogService(baseline: f.baseline, store: store)
        let initial = try await service.snapshot()
        await #expect(throws: RuntimeCatalogPublicationFailure.self) { try await service.persistSelection() }
        #expect(bytes.withLock { $0 } == nil)
        #expect(try await service.snapshot().selections == initial.selections)
        fail.withLock { $0 = false }
        _ = try await service.persistSelection()
        #expect(bytes.withLock { $0 } != nil)
    }

    @Test func trustedBaselinePromotingRemoteBundlePreservesOriginalProfileAndPin() async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in bytes.withLock { $0 = data } })
        let original = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let update = try fixture.update(revision: 7)
        _ = try await original.accept(metadata: JSONEncoder().encode(update))
        let promoted = try #require(update.manifest.bundles.first { $0.id.rawValue == "dxmt-next" })
        _ = try await original.selectBundle(id: promoted.id, pinned: true, installedBundleIDs: [promoted.id])
        let saved = bytes.withLock { $0 }
        let evolved = try RuntimeManifest(components: fixture.baseline.components, bundles: [promoted] + fixture.baseline.bundles)
        let reopened = RuntimeCatalogService(baseline: evolved, store: store)
        let restored = try await reopened.snapshot()
        #expect(restored.selectedBundle(for: .dxmt)?.id == promoted.id)
        #expect(restored.selections.bundles[.dxmt]?.pinned == true)
        #expect(restored.catalog.revision == 7)
        #expect(try restored.profile(for: SafeIdentifier("dxmt-next"))?.rawValue == "dxmt-test")
        #expect(restored.catalog.manifest.bundles.count == 3)
        #expect(bytes.withLock { $0 } == saved)
        let rewritten = RuntimeCatalog(revision: 8, manifest: restored.catalog.manifest,
            bundleBindings: RuntimeCatalog.bundled(evolved).bundleBindings, helperBindings: restored.catalog.helperBindings,
            recommendedBundles: restored.catalog.recommendedBundles, recommendedHelpers: restored.catalog.recommendedHelpers)
        await #expect(throws: (any Error).self) { try await reopened.accept(metadata: JSONEncoder().encode(rewritten)) }
        #expect(try await reopened.snapshot().catalog.revision == 7)
    }

    @Test func decodedCacheMigrationFailureDoesNotSilentlyResetOrOverwriteState() async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in bytes.withLock { $0 = data } })
        let original = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await original.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let next = try SafeIdentifier("dxmt-next")
        _ = try await original.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
        let saved = bytes.withLock { $0 }
        let old = fixture.baseline.bundles[0]
        let changed = try RuntimeBundle(id: old.id, displayName: "Changed immutable descriptor", backend: old.backend, components: old.components)
        let incompatible = try RuntimeManifest(components: fixture.baseline.components, bundles: [changed, fixture.baseline.bundles[1]])
        let reopened = RuntimeCatalogService(baseline: incompatible, store: store)
        await #expect(throws: (any Error).self) { try await reopened.snapshot() }
        await #expect(throws: (any Error).self) { try await reopened.accept(metadata: JSONEncoder().encode(fixture.update(revision: 2))) }
        #expect(bytes.withLock { $0 } == saved)
    }

    @Test func selectionPreviewDoesNotActivateOrRequireInstalledEvidence() async throws {
        let fixture = try CatalogFixture()
        let service = RuntimeCatalogService(baseline: fixture.baseline)
        let current = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let proposed = try current.replacingSelections(current.recommendedSelections)
        #expect(proposed.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-next")
        #expect(current.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
    }

    @Test(arguments: ["swift", "launcher", "task"])
    func cancelledInitialLoadDoesNotCacheFallback(cancellation: String) async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let savedStore = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in bytes.withLock { $0 = data } })
        let original = RuntimeCatalogService(baseline: fixture.baseline, store: savedStore)
        _ = try await original.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let next = try SafeIdentifier("dxmt-next")
        _ = try await original.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
        let firstRead = Mutex(true)
        let store = RuntimeCatalogStore(read: {
            if firstRead.withLock({ first in let result = first; first = false; return result }) {
                if cancellation == "swift" { throw CancellationError() }
                if cancellation == "launcher" { throw LauncherError.cancelled }
            }
            return bytes.withLock { $0 }
        }, write: { data in bytes.withLock { $0 = data } })
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let cancelled = Task {
            if cancellation == "task" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await service.snapshot()
        }
        await #expect(throws: (any Error).self) { try await cancelled.value }
        let restored = try await service.snapshot()
        #expect(restored.selectedBundle(for: .dxmt)?.id == next)
        #expect(restored.selections.bundles[.dxmt]?.pinned == true)
        #expect(restored.catalog.revision == 1)
    }

    @Test func trustedBaselineExpansionRetainsRemoteActivePinAndHistory() async throws {
        let fixture = try CatalogFixture()
        let store = RuntimeCatalogStore(root: fixture.temp.url)
        let original = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await original.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let next = try SafeIdentifier("dxmt-next")
        _ = try await original.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
        let added = try RuntimeBundle(id: SafeIdentifier("dxmt-new-compiled-profile"), displayName: "New compiled profile",
            backend: .dxmt, components: fixture.baseline.bundles[0].components)
        let evolved = try RuntimeManifest(components: fixture.baseline.components, bundles: fixture.baseline.bundles + [added])
        let reopened = RuntimeCatalogService(baseline: evolved, store: store)
        let restored = try await reopened.snapshot()
        #expect(restored.selectedBundle(for: .dxmt)?.id == next)
        #expect(restored.selections.bundles[.dxmt]?.pinned == true)
        #expect(restored.catalog.revision == 1)
        #expect(restored.catalog.manifest.bundles.contains { $0.id == added.id })
        #expect(restored.helper(kind: .genshinFps, for: added.id)?.id == restored.selectedHelper(for: .genshinFps)?.id)
        let preview = try restored.replacingSelections(restored.selections)
        #expect(preview.helper(kind: .genshinFps, for: added.id)?.id == restored.selectedHelper(for: .genshinFps)?.id)
        let before = RuntimeCatalog.bundled(fixture.baseline).helperBindings.first { $0.componentID.rawValue == GenshinFps.componentID }
        let after = restored.catalog.helperBindings.first { $0.componentID.rawValue == GenshinFps.componentID }
        #expect(before?.profileIDs == after?.profileIDs)
        let refreshed = try await reopened.accept(metadata: JSONEncoder().encode(fixture.update(revision: 2)))
        #expect(refreshed.selections.bundles[.dxmt]?.pinned == true)
        #expect(refreshed.selectedBundle(for: .dxmt)?.id == next)
        let changedBindings = RuntimeCatalog(revision: 3, manifest: refreshed.catalog.manifest,
            bundleBindings: refreshed.catalog.bundleBindings, helperBindings: RuntimeCatalog.bundled(evolved).helperBindings,
            recommendedBundles: refreshed.catalog.recommendedBundles, recommendedHelpers: refreshed.catalog.recommendedHelpers)
        await #expect(throws: (any Error).self) { try await reopened.accept(metadata: JSONEncoder().encode(changedBindings)) }
        #expect(try await reopened.snapshot().catalog.revision == 2)
    }

    @Test func cancelledPublisherStillReconcilesReplacedBytes() async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let operation = Mutex<Task<RuntimeCatalogSnapshot, any Error>?>(nil)
        let store = RuntimeCatalogStore(read: {
            try Task.checkCancellation()
            return bytes.withLock { $0 }
        }, write: { data in
            bytes.withLock { $0 = data }
            if let task = operation.withLock({ $0 }) {
                task.cancel()
                throw LauncherError.cancelled
            }
        })
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let next = try SafeIdentifier("dxmt-next")
        let (start, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in start {
                return try await service.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
            }
            throw CancellationError()
        }
        operation.withLock { $0 = task }
        continuation.yield(()); continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Cancelled publication must report its failure")
        } catch let error as RuntimeCatalogPublicationFailure {
            #expect(error.persistedSnapshot?.selectedBundle(for: .dxmt)?.id == next)
        }
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id == next)
        operation.withLock { $0 = nil }
    }

    @Test func postRenameWriteFailureReconcilesActualSnapshotBeforeNextMutation() async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let fail = Mutex(false)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in
            bytes.withLock { $0 = data }
            if fail.withLock({ $0 }) { throw LauncherError.io("directory fsync failed after rename") }
        })
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let next = try SafeIdentifier("dxmt-next")
        fail.withLock { $0 = true }
        do {
            _ = try await service.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
            Issue.record("Post-rename publication must report its write failure")
        } catch let error as RuntimeCatalogPublicationFailure {
            #expect(error.persistedSnapshot?.selectedBundle(for: .dxmt)?.id == next)
            #expect(error.persistedSnapshot?.selections.bundles[.dxmt]?.pinned == true)
        }
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id == next)
        fail.withLock { $0 = false }
        let helper = try SafeIdentifier(SurroundAudio.componentID)
        _ = try await service.selectHelper(id: helper, pinned: true, installedComponentIDs: [helper])
        let reopened = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let restored = try await reopened.snapshot()
        #expect(restored.selectedBundle(for: .dxmt)?.id == next)
        #expect(restored.selections.bundles[.dxmt]?.pinned == true)
        #expect(restored.selections.helpers[.surroundAudio]?.pinned == true)
    }

    @Test func failedPostRenameReadBlocksSnapshotsAndMutationsUntilRecovery() async throws {
        let fixture = try CatalogFixture()
        let bytes = Mutex<Data?>(nil)
        let failWrite = Mutex(false)
        let failRead = Mutex(false)
        let store = RuntimeCatalogStore(read: {
            if failRead.withLock({ $0 }) { throw LauncherError.io("unavailable recovery read") }
            return bytes.withLock { $0 }
        }, write: { data in
            bytes.withLock { $0 = data }
            if failWrite.withLock({ $0 }) {
                failRead.withLock { $0 = true }
                throw LauncherError.io("directory fsync failed after rename")
            }
        })
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        failWrite.withLock { $0 = true }
        let next = try SafeIdentifier("dxmt-next")
        do {
            _ = try await service.selectBundle(id: next, pinned: true, installedBundleIDs: [next])
            Issue.record("Post-rename write must fail")
        } catch let error as RuntimeCatalogPublicationFailure {
            #expect(error.persistedSnapshot == nil)
        }
        let afterFailure = bytes.withLock { $0 }
        await #expect(throws: (any Error).self) { try await service.snapshot() }
        await #expect(throws: (any Error).self) {
            try await service.selectBundle(id: fixture.baseline.bundles[0].id, pinned: false,
                installedBundleIDs: [fixture.baseline.bundles[0].id])
        }
        #expect(bytes.withLock { $0 } == afterFailure)
        failRead.withLock { $0 = false }
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id == next)
        #expect(try await service.snapshot().selections.bundles[.dxmt]?.pinned == true)
    }

    @Test func repositoryCatalogAcceptsPublishedShape() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let baseline = try RuntimeManifest.load(from: root.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let bytes = try Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json"))
        let service = RuntimeCatalogService(baseline: baseline)
        let snapshot = try await service.accept(metadata: bytes)
        #expect(snapshot.catalog.revision >= 1)
        #expect(snapshot.selectedHelper(for: .surroundAudio)?.id == snapshot.catalog.recommendedHelpers[.surroundAudio])
        let migrated = RuntimeCatalogService(baseline: baseline,
            installedComponentIDs: [try SafeIdentifier("surround-audio-wine-11.20-1")])
        #expect(try await migrated.snapshot().selectedHelper(for: .surroundAudio)?.id.rawValue == "surround-audio-wine-11.20-1")
    }

    @Test func incompatibleKnownHelperAndBundleCannotBeSelectedTogether() async throws {
        let fixture = try CatalogFixture()
        let alternate = try RuntimeBundle(id: SafeIdentifier("dxmt-alternate"), displayName: "Alternate",
            backend: .dxmt, components: fixture.baseline.bundles[0].components)
        let baseline = try RuntimeManifest(components: fixture.baseline.components, bundles: fixture.baseline.bundles + [alternate])
        let next = try fixture.component(kind: .genshinFps, version: "3")
        let catalog = RuntimeCatalog.bundled(baseline)
        let update = RuntimeCatalog(revision: 1,
            manifest: try RuntimeManifest(components: baseline.components + [next], bundles: baseline.bundles),
            bundleBindings: catalog.bundleBindings,
            helperBindings: catalog.helperBindings + [RuntimeCatalogHelperBinding(componentID: next.id, profileIDs: fixture.baseline.bundles.map(\.id))],
            recommendedBundles: catalog.recommendedBundles,
            recommendedHelpers: catalog.recommendedHelpers.merging([.genshinFps: next.id]) { _, new in new })
        let service = RuntimeCatalogService(baseline: baseline)
        _ = try await service.accept(metadata: JSONEncoder().encode(update))
        _ = try await service.selectHelper(id: next.id, pinned: true, installedComponentIDs: [next.id])
        let current = try await service.snapshot()
        var incompatible = current.selections
        incompatible.bundles[.dxmt] = RuntimeCatalogSelection(id: alternate.id)
        #expect(throws: (any Error).self) { try current.replacingSelections(incompatible) }
        await #expect(throws: (any Error).self) {
            try await service.selectBundle(id: alternate.id, pinned: true, installedBundleIDs: [alternate.id])
        }
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
    }

    @Test func refreshRetainsActiveHistoryAndPinAcrossRestart() async throws {
        let fixture = try CatalogFixture()
        let store = RuntimeCatalogStore(root: fixture.temp.url)
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let initial = try await service.snapshot()
        #expect(initial.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
        let update = try fixture.update(revision: 1)
        let refreshed = try await service.accept(metadata: JSONEncoder().encode(update))
        #expect(refreshed.catalog.manifest.bundles.count == 3)
        #expect(refreshed.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
        #expect(refreshed.recommendedBundle(for: .dxmt)?.id.rawValue == "dxmt-next")
        #expect(refreshed.manifest.bundles.map(\.id).contains(try SafeIdentifier("dxmt-next")) == false)
        _ = try await service.selectBundle(id: SafeIdentifier("dxmt-next"), pinned: false,
            installedBundleIDs: [SafeIdentifier("dxmt-next")])
        _ = try await service.selectBundle(id: SafeIdentifier("dxmt-test"), pinned: true,
            installedBundleIDs: [SafeIdentifier("dxmt-test")])
        let second = try #require(String(data: JSONEncoder().encode(fixture.update(revision: 2)), encoding: .utf8))
            .replacingOccurrences(of: "dxmt-next", with: "dxmt-future")
        _ = try await service.accept(metadata: Data(second.utf8))
        let reopened = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let saved = try await reopened.snapshot()
        #expect(saved.selections.bundles[.dxmt]?.pinned == true)
        #expect(saved.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
        #expect(saved.catalog.revision == 2)
        #expect(try saved.profile(for: SafeIdentifier("dxmt-next"))?.rawValue == "dxmt-test")
        #expect(saved.catalog.manifest.bundles.count == 4)
        #expect(saved.recommendedBundle(for: .dxmt)?.id.rawValue == "dxmt-future")
    }

    @Test func concurrentSelectionWritesDoNotLoseOneAnother() async throws {
        let fixture = try CatalogFixture()
        let store = RuntimeCatalogStore(root: fixture.temp.url)
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let bundle = try SafeIdentifier("dxmt-next")
        let helper = try SafeIdentifier(SurroundAudio.componentID)
        async let bundleWrite = service.selectBundle(id: bundle, pinned: true, installedBundleIDs: [bundle])
        async let helperWrite = service.selectHelper(id: helper, pinned: true, installedComponentIDs: [helper])
        _ = try await (bundleWrite, helperWrite)
        let reopened = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        let snapshot = try await reopened.snapshot()
        #expect(snapshot.selections.bundles[.dxmt] == RuntimeCatalogSelection(id: bundle, pinned: true))
        #expect(snapshot.selections.helpers[.surroundAudio] == RuntimeCatalogSelection(id: helper, pinned: true))
    }

    @Test func corruptAndUnavailableStoreUseBaselineWithoutDeletingBytes() async throws {
        let fixture = try CatalogFixture()
        let path = fixture.temp.url.appendingPathComponent("runtime-catalog-state.json")
        try Data("broken".utf8).write(to: path)
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: RuntimeCatalogStore(root: fixture.temp.url))
        #expect(try await service.snapshot().catalog.revision == 0)
        #expect(try Data(contentsOf: path) == Data("broken".utf8))
        let unavailable = RuntimeCatalogStore(read: { throw LauncherError.io("offline") }, write: { _ in })
        #expect(try await RuntimeCatalogService(baseline: fixture.baseline, store: unavailable).snapshot().catalog.revision == 0)
    }

    @Test func immutableIDsAndRevisionRollbackAreRejected() async throws {
        let fixture = try CatalogFixture()
        let service = RuntimeCatalogService(baseline: fixture.baseline)
        let update = try fixture.update(revision: 2)
        _ = try await service.accept(metadata: JSONEncoder().encode(update))
        await #expect(throws: (any Error).self) {
            try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        }
        for attack in ["component", "bundle", "binding", "sameRevision"] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
            object["revision"] = attack == "sameRevision" ? 2 : 3
            if attack == "component" {
                var manifest = object["manifest"] as! [String: Any]
                var components = manifest["components"] as! [[String: Any]]
                components[0]["size"] = 101
                manifest["components"] = components; object["manifest"] = manifest
            } else if attack == "bundle" {
                var manifest = object["manifest"] as! [String: Any]
                var bundles = manifest["bundles"] as! [[String: Any]]
                bundles[0]["summary"] = "changed identity"
                manifest["bundles"] = bundles; object["manifest"] = manifest
            } else {
                object["recommendedBundles"] = ["dxmt": "dxmt-test", "d3dmetal": SurroundAudio.bundleID]
                if attack == "binding" {
                    var bindings = object["bundleBindings"] as! [[String: Any]]
                    bindings[0]["profileID"] = SurroundAudio.bundleID
                    object["bundleBindings"] = bindings
                }
            }
            let bytes = try JSONSerialization.data(withJSONObject: object)
            await #expect(throws: (any Error).self) { try await service.accept(metadata: bytes) }
        }
        #expect(try await service.snapshot().catalog.revision == 2)
    }

    @Test func rejectsUnknownProfilesHTTPAndUnsafeCompatibilityChanges() async throws {
        let fixture = try CatalogFixture()
        let source = try JSONEncoder().encode(fixture.update(revision: 1))
        for attack in ["profile", "http", "environment", "wineBinary", "helperProfile", "contract", "schema", "oversize"] {
            let service = RuntimeCatalogService(baseline: fixture.baseline)
            var object = try #require(JSONSerialization.jsonObject(with: source) as? [String: Any])
            if attack == "profile" {
                var bindings = object["bundleBindings"] as! [[String: Any]]
                bindings[0]["profileID"] = "unknown-profile"; object["bundleBindings"] = bindings
            } else if attack == "helperProfile" {
                var bindings = object["helperBindings"] as! [[String: Any]]
                let index = bindings.firstIndex { $0["componentID"] as? String == SurroundAudio.componentID }!
                bindings[index]["profileIDs"] = ["dxmt-test"]; object["helperBindings"] = bindings
            } else if attack == "contract" { object["clientContract"] = "unknown" }
            else if attack == "schema" { object["schemaVersion"] = 2 }
            else if attack != "oversize" {
                var manifest = object["manifest"] as! [String: Any]
                if attack == "environment" {
                    var bundles = manifest["bundles"] as! [[String: Any]]
                    bundles[0]["environment"] = ["DYLD_INSERT_LIBRARIES": "remote"]
                    manifest["bundles"] = bundles
                } else {
                    var components = manifest["components"] as! [[String: Any]]
                    let index = components.firstIndex { $0["kind"] as? String == "wine" }!
                    components[index][attack == "http" ? "url" : "wineBinary"] = attack == "http" ? "http://fixtures.invalid/wine" : "bin/remote-command"
                    manifest["components"] = components
                }
                object["manifest"] = manifest
            }
            let bytes = attack == "oversize" ? Data(repeating: 32, count: (1 << 20) + 1) : try JSONSerialization.data(withJSONObject: object)
            await #expect(throws: (any Error).self) { try await service.accept(metadata: bytes) }
            #expect(try await service.snapshot().catalog.revision == 0)
        }
    }

    @Test func failedInstallationCannotActivateAndSuccessfulUpdateIsExplicit() async throws {
        let fixture = try CatalogFixture()
        let service = RuntimeCatalogService(baseline: fixture.baseline)
        let snapshot = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        await #expect(throws: (any Error).self) {
            try await service.activate(selections: snapshot.recommendedSelections, installedBundleIDs: [], installedComponentIDs: [])
        }
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
        let activated = try await service.activate(selections: snapshot.recommendedSelections,
            installedBundleIDs: Set(snapshot.recommendedSelections.bundles.values.map(\.id)),
            installedComponentIDs: Set(snapshot.recommendedSelections.helpers.values.map(\.id)))
        #expect(activated.selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-next")
    }

    @Test func helperBindingsAndInstalledMigrationPreserveWorkingRevision() async throws {
        let fixture = try CatalogFixture()
        let old = try fixture.component(kind: .surroundAudio, version: "wine-11.20-1")
        let baseline = try RuntimeManifest(components: fixture.baseline.components + [old], bundles: fixture.baseline.bundles)
        let service = RuntimeCatalogService(baseline: baseline, installedComponentIDs: [old.id])
        let snapshot = try await service.snapshot()
        #expect(try snapshot.helper(kind: .surroundAudio, for: SafeIdentifier(SurroundAudio.bundleID))?.id == old.id)
        #expect(try snapshot.helper(kind: .surroundAudio, for: SafeIdentifier("dxmt-test")) == nil)
        #expect(snapshot.selectedHelper(for: .surroundAudio)?.id == old.id)
    }

    @Test func failedAtomicWriteLeavesMemoryAndDiskSelectionUnchanged() async throws {
        let fixture = try CatalogFixture()
        let saved = Mutex<Data?>(nil)
        let fail = Mutex(false)
        let store = RuntimeCatalogStore(read: { saved.withLock { $0 } }, write: { bytes in
            if fail.withLock({ $0 }) { throw LauncherError.io("injected atomic failure") }
            saved.withLock { $0 = bytes }
        })
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: store)
        _ = try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        let previous = saved.withLock { $0 }
        fail.withLock { $0 = true }
        await #expect(throws: (any Error).self) {
            try await service.selectBundle(id: SafeIdentifier("dxmt-next"), pinned: true,
                installedBundleIDs: [SafeIdentifier("dxmt-next")])
        }
        #expect(saved.withLock { $0 } == previous)
        #expect(try await service.snapshot().selectedBundle(for: .dxmt)?.id.rawValue == "dxmt-test")
    }

    @Test func containedStoreRejectsSymlinkWithoutTouchingTarget() async throws {
        let fixture = try CatalogFixture()
        let outside = try TempDir()
        let target = outside.url.appendingPathComponent("private.json")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.temp.url.appendingPathComponent("runtime-catalog-state.json"), withDestinationURL: target)
        let service = RuntimeCatalogService(baseline: fixture.baseline, store: RuntimeCatalogStore(root: fixture.temp.url))
        #expect(try await service.snapshot().catalog.revision == 0)
        await #expect(throws: (any Error).self) {
            try await service.accept(metadata: JSONEncoder().encode(fixture.update(revision: 1)))
        }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
    }
}

private final class CatalogFixture {
    let temp: TempDir
    let baseline: RuntimeManifest
    init() throws {
        let dxmt = try JSONDecoder().decode(RuntimeManifest.self, from: bundleManifestData())
        let apple = try Self.makeComponent(kind: .d3dmetal, version: "test")
        let surround = try Self.makeComponent(kind: .surroundAudio, version: SurroundAudio.version)
        let fps = try Self.makeComponent(kind: .genshinFps, version: "2")
        let bundle = try RuntimeBundle(id: SafeIdentifier(SurroundAudio.bundleID), displayName: "D3DMetal", backend: .d3dmetal, components: [apple.id])
        baseline = try RuntimeManifest(components: dxmt.components + [apple, surround, fps], bundles: dxmt.bundles + [bundle])
        temp = try TempDir()
    }
    func component(kind: ComponentKind, version: String) throws -> RuntimeComponent { try Self.makeComponent(kind: kind, version: version) }
    static func makeComponent(kind: ComponentKind, version: String) throws -> RuntimeComponent {
        try RuntimeComponent(id: SafeIdentifier("\(kind.idPrefix)-\(version)"), kind: kind, version: SafeIdentifier(version),
            sourceMode: .download, url: URL(string: "https://fixtures.invalid/\(kind.idPrefix)-\(version).zip")!,
            size: 100, installedSize: 1000, sha256: Digest(algorithm: .sha256, hex: String(repeating: "a", count: 64)), archive: .zip,
            license: ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!, redistributable: kind != .d3dmetal, termsRevision: "1"),
            consent: kind == .d3dmetal ? .appleGPTK : nil, rootPath: kind == .d3dmetal ? SafeRelativePath("wine") : nil,
            wineBinary: kind == .d3dmetal ? SafeRelativePath("bin/wine") : nil)
    }
    func update(revision: UInt64) throws -> RuntimeCatalog {
        let next = try RuntimeBundle(id: SafeIdentifier("dxmt-next"), displayName: "DXMT next", backend: .dxmt, components: baseline.bundles[0].components)
        let manifest = try RuntimeManifest(components: baseline.components, bundles: [next, baseline.bundles[1]])
        return try RuntimeCatalog(revision: revision, manifest: manifest,
            bundleBindings: [RuntimeCatalogBundleBinding(bundleID: next.id, profileID: baseline.bundles[0].id),
                RuntimeCatalogBundleBinding(bundleID: baseline.bundles[1].id, profileID: baseline.bundles[1].id)],
            helperBindings: [RuntimeCatalogHelperBinding(componentID: SafeIdentifier(SurroundAudio.componentID), profileIDs: [baseline.bundles[1].id]),
                RuntimeCatalogHelperBinding(componentID: SafeIdentifier(GenshinFps.componentID), profileIDs: baseline.bundles.map(\.id))],
            recommendedBundles: [.dxmt: next.id, .d3dmetal: baseline.bundles[1].id],
            recommendedHelpers: [.surroundAudio: SafeIdentifier(SurroundAudio.componentID), .genshinFps: SafeIdentifier(GenshinFps.componentID)])
    }
}
