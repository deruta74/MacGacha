// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CryptoKit

public enum RuntimeCatalogSignatureError: Error, Sendable { case rejected }

public struct RuntimeCatalogSignatureVerifier: Sendable {
    private let publicKeys: [Data]
    public init(publicKeys: [Data]) { self.publicKeys = publicKeys }
    public func verify(body: Data, signature: Data?) throws {
        guard let signature, signature.count == 64, !publicKeys.isEmpty,
            publicKeys.contains(where: { bytes in
                guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { return false }
                return key.isValidSignature(signature, for: body)
            }) else { throw RuntimeCatalogSignatureError.rejected }
    }
    public static func decodeDetached(_ bytes: Data) throws -> Data {
        guard bytes.count <= 1024, let text = String(data: bytes, encoding: .utf8),
            let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else {
            throw catalogError("Invalid detached catalog signature")
        }
        return signature
    }
}

public struct RuntimeSignedCatalog: Codable, Sendable {
    public let body: Data
    public let signature: Data
    public init(body: Data, signature: Data) { self.body = body; self.signature = signature }
}
