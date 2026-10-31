// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreFoundation
import LauncherCore

public enum StarRailFrameRate: Sendable, Equatable {
    case unlock120, restore
    static let maximumPayloadBytes = 1 << 20

    static func registryKey(for region: Region) -> String {
        switch region {
        case .global: "HKCU\\Software\\Cognosphere\\Star Rail"
        // UNVERIFIED: the CN edition's key has not been confirmed in a real prefix.
        case .mainlandChina: "HKCU\\Software\\miHoYo\\崩坏：星穹铁道"
        }
    }
    public static func rewrite(_ payload: Data, fps: Int) -> Data? {
        guard var object = object(payload) else { return nil }
        object["FPS"] = fps
        guard var result = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        if payload.last == 0 { result.append(0) }
        return result
    }
    static func currentFPS(_ payload: Data) -> Double? {
        (object(payload)?["FPS"] as? NSNumber)?.doubleValue
    }
    private static func object(_ payload: Data) -> [String: Any]? {
        guard payload.count <= maximumPayloadBytes,
            let object = try? JSONSerialization.jsonObject(with: payload.last == 0 ? payload.dropLast() : payload) as? [String: Any],
            let number = object["FPS"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return object
    }
    public static func parseQuery(_ output: String) -> [(name: String, hex: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].hasPrefix("GraphicsSettings_Model_h"), fields[1] == "REG_BINARY" else { return nil }
            return (String(fields[0]), fields.dropFirst(2).joined())
        }
    }
    static func decodeHex(_ hex: String) -> Data? {
        let bytes = Array(hex.utf8)
        guard bytes.count <= maximumPayloadBytes * 2, bytes.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
    static func encodeHex(_ payload: Data) -> String {
        payload.map { String(format: "%02x", $0) }.joined()
    }
}

public enum StarRailFrameRateOutcome: Sendable, Equatable {
    case applied, unchanged, missing, unreadable
}
public struct PreparationOutcome: Sendable, Equatable {
    public let starRailFrameRate: StarRailFrameRateOutcome?
    public init(starRailFrameRate: StarRailFrameRateOutcome? = nil) { self.starRailFrameRate = starRailFrameRate }
}
