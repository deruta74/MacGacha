// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Synthetic protobuf fixtures only; never used by the production reader.
public struct ProtobufWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func varint(_ field: UInt32, _ value: UInt64) {
        appendVarint(UInt64(field) << 3)
        appendVarint(value)
    }

    public mutating func bytes(_ field: UInt32, _ value: Data) {
        appendVarint(UInt64(field) << 3 | 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: UInt32, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 128 {
            data.append(UInt8(remaining & 127) | 128)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}
