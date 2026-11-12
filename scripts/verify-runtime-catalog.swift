#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 3 else { exit(1) }
let keys = (ProcessInfo.processInfo.environment["RUNTIME_CATALOG_PUBLIC_ED_KEYS"] ?? "")
    .split(separator: ",").compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
let body = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let text = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
guard text.utf8.count <= 1024, let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
    signature.count == 64, keys.contains(where: { bytes in
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { return false }
        return key.isValidSignature(signature, for: body)
    }) else { fputs("Catalog signature rejected\n", stderr); exit(1) }
