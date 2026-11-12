// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
@testable import RuntimeManager

@Suite struct RuntimeCatalogCompatibilityTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    @Test func oldBaselineAcceptsRevision2() throws {
        let baseline = try JSONDecoder().decode(RuntimeManifest.self, from: fixture("manifest-0.2.6"))
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: fixture("catalog-r2"))
        try RuntimeCatalogContract(baseline).validate(catalog)
        #expect(catalog.revision == 2)
    }
    @Test func oldBaselineRejectsRevision3() throws {
        let baseline = try JSONDecoder().decode(RuntimeManifest.self, from: fixture("manifest-0.2.6"))
        let catalog = try JSONDecoder().decode(RuntimeCatalog.self, from: Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json")))
        #expect(throws: (any Error).self) { try RuntimeCatalogContract(baseline).validate(catalog) }
    }
    @Test func serviceWithOldBaselineKeepsRevision2AndSelectionsAfterRejectingRevision3() async throws {
        let baseline = try JSONDecoder().decode(RuntimeManifest.self, from: fixture("manifest-0.2.6"))
        let bytes = Mutex<Data?>(nil)
        let store = RuntimeCatalogStore(read: { bytes.withLock { $0 } }, write: { data in bytes.withLock { $0 = data } })
        let service = RuntimeCatalogService(baseline: baseline, store: store)
        _ = try await service.accept(metadata: fixture("catalog-r2"))
        let old = try SafeIdentifier("dxmt-wine11.0cx-dxmt0.80")
        let pinned = try await service.selectBundle(id: old, pinned: true, installedBundleIDs: [old])
        let saved = bytes.withLock { $0 }
        let newer = try Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json"))
        await #expect(throws: (any Error).self) { try await service.accept(metadata: newer) }
        #expect(bytes.withLock { $0 } == saved)
        let reopened = RuntimeCatalogService(baseline: baseline, store: store)
        #expect(try await reopened.snapshot().catalog.revision == 2)
        #expect(try await reopened.snapshot().selections == pinned.selections)
    }
    @Test func newBaselineAcceptsRevision3() async throws {
        let baseline = try RuntimeManifest.load(from: root.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let service = RuntimeCatalogService(baseline: baseline)
        let catalog = try await service.accept(metadata: Data(contentsOf: root.appendingPathComponent("RuntimeCatalog/runtime-catalog.json")))
        #expect(catalog.catalog.revision == 3)
        #expect(catalog.recommendedBundle(for: .d3dmetal)?.components.count == 2)
    }
}
