#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3,
    let secret = ProcessInfo.processInfo.environment["RUNTIME_CATALOG_ED_PRIVATE_KEY"],
    let raw = Data(base64Encoded: secret), raw.count == 32 else {
    fputs("Missing catalog signing key or arguments\n", stderr); exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
let accepted = (ProcessInfo.processInfo.environment["RUNTIME_CATALOG_PUBLIC_ED_KEYS"] ?? "")
    .split(separator: ",").compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
guard accepted.contains(key.publicKey.rawRepresentation) else {
    fputs("Catalog signing key is not in the configured public key list\n", stderr); exit(1)
}
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let signature = try key.signature(for: bytes)
try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
