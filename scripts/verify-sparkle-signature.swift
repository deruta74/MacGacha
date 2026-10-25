// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import CryptoKit
import Foundation

private enum VerificationError: Error { case invalidSignature }

private func verify(_ data: Data, publicKey: String, signature: String) throws -> Bool {
    guard let key = Data(base64Encoded: publicKey), let signature = Data(base64Encoded: signature),
        key.count == 32, signature.count == 64 else { throw VerificationError.invalidSignature }
    return try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: data)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-check"] {
        // Public RFC 8032 test vector 1; no private key is stored or generated.
        let key = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
        let wrongKey = "PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="
        let signature = "5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=="
        guard try verify(Data(), publicKey: key, signature: signature),
            !(try verify(Data([1]), publicKey: key, signature: signature)),
            !(try verify(Data(), publicKey: wrongKey, signature: signature)) else { throw VerificationError.invalidSignature }
        print("Sparkle signature verifier self-check passed")
    } else {
        guard arguments.count == 3 else { throw VerificationError.invalidSignature }
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]), options: .mappedIfSafe)
        guard try verify(data, publicKey: arguments[1], signature: arguments[2]) else { throw VerificationError.invalidSignature }
    }
} catch {
    FileHandle.standardError.write(Data("error: Update signature does not match the app's public key or archive\n".utf8))
    exit(1)
}
