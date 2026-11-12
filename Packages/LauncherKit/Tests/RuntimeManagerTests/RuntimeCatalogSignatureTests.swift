// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CryptoKit
import Testing
import LauncherCore
import Synchronization
@testable import RuntimeManager

@Suite struct RuntimeCatalogSignatureTests {
    @Test func serviceVerifiesCachedProofAndRejectsDifferentBytesAtSameRevision() async throws {
        let baseline = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "manifest-0.2.6", withExtension: "json", subdirectory: "Fixtures"))))
        let body = try Data(contentsOf: #require(Bundle.module.url(forResource: "catalog-r2", withExtension: "json", subdirectory: "Fixtures")))
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let disk = Mutex<Data?>(nil)
        let store = RuntimeCatalogStore(read: { disk.withLock { $0 } }, write: { data in disk.withLock { $0 = data } })
        let verifier = RuntimeCatalogSignatureVerifier(publicKeys: [key.publicKey.rawRepresentation])
        let service = RuntimeCatalogService(baseline: baseline, store: store, signatureVerifier: verifier)
        await #expect(throws: (any Error).self) { try await service.accept(metadata: body) }
        _ = try await service.accept(metadata: body, signature: key.signature(for: body))
        let changed = body + Data("\n".utf8)
        await #expect(throws: (any Error).self) { try await service.accept(metadata: changed, signature: key.signature(for: changed)) }
        let rotated = RuntimeCatalogService(baseline: baseline, store: store,
            signatureVerifier: RuntimeCatalogSignatureVerifier(publicKeys: [other.publicKey.rawRepresentation, key.publicKey.rawRepresentation]))
        #expect(try await rotated.snapshot().catalog.revision == 2)
        let rejected = RuntimeCatalogService(baseline: baseline, store: store,
            signatureVerifier: RuntimeCatalogSignatureVerifier(publicKeys: [other.publicKey.rawRepresentation]))
        await #expect(throws: (any Error).self) { try await rejected.snapshot() }
        var object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        object["revision"] = 3
        let newer = try JSONSerialization.data(withJSONObject: object)
        let refreshed = try await rejected.accept(metadata: newer, signature: other.signature(for: newer))
        #expect(refreshed.catalog.revision == 3)
    }
    @Test func validMissingWrongKeyTamperedAndRotation() throws {
        let first = Curve25519.Signing.PrivateKey(), second = Curve25519.Signing.PrivateKey()
        let bytes = Data("catalog".utf8), signature = try first.signature(for: bytes)
        let verifier = RuntimeCatalogSignatureVerifier(publicKeys: [first.publicKey.rawRepresentation])
        try verifier.verify(body: bytes, signature: signature)
        #expect(throws: (any Error).self) { try verifier.verify(body: bytes, signature: nil) }
        #expect(throws: (any Error).self) { try verifier.verify(body: Data("tampered".utf8), signature: signature) }
        #expect(throws: (any Error).self) { try RuntimeCatalogSignatureVerifier(publicKeys: [second.publicKey.rawRepresentation]).verify(body: bytes, signature: signature) }
        try RuntimeCatalogSignatureVerifier(publicKeys: [second.publicKey.rawRepresentation, first.publicKey.rawRepresentation]).verify(body: bytes, signature: signature)
    }
}
