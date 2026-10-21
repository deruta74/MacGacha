// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// A bounded protobuf cursor. Length-delimited values share their input storage;
/// no untrusted length is used for an allocation or an unchecked Int conversion.
struct ProtobufReader {
    static let maximumNesting = 4
    private let data: Data
    private var position: Int
    private let depth: Int

    init(_ data: Data, depth: Int = 0) {
        self.data = data
        position = data.startIndex
        self.depth = depth
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard position < data.endIndex else { throw LauncherError.io("truncated protobuf") }
            let byte = data[position]
            position += 1
            guard index < 9 || byte <= 1 else { throw LauncherError.io("invalid varint") }
            result |= UInt64(byte & 0x7f) << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw LauncherError.io("invalid varint")
    }

    mutating func nextField() throws -> Field? {
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard position < data.endIndex else { return nil }
        let key = try readVarint()
        let number = key >> 3
        let wire = UInt8(key & 7)
        guard number > 0, number <= 0x1fff_ffff else { throw LauncherError.io("invalid protobuf field") }
        let value: Value
        switch wire {
        case 0: value = .varint(try readVarint())
        case 1: value = .fixed64(try readBytes(count: 8))
        case 2:
            let length = try readVarint()
            guard length <= UInt64(data.endIndex - position) else { throw LauncherError.io("truncated protobuf") }
            value = .bytes(try readBytes(count: Int(length)))
        case 5: value = .fixed32(try readBytes(count: 4))
        default: throw LauncherError.io("invalid protobuf field")
        }
        return Field(number: Int(number), value: value)
    }

    func child(_ field: Field) throws -> ProtobufReader {
        let bytes = try field.bytes()
        guard depth < Self.maximumNesting else { throw LauncherError.io("protobuf nesting limit") }
        return ProtobufReader(bytes, depth: depth + 1)
    }

    private mutating func readBytes(count: Int) throws -> Data {
        guard count <= data.endIndex - position else { throw LauncherError.io("truncated protobuf") }
        defer { position += count }
        return data[position..<(position + count)]
    }

    enum Value: Equatable {
        case varint(UInt64), fixed64(Data), bytes(Data), fixed32(Data)
    }

    struct Field: Equatable {
        let number: Int
        let value: Value
        var wireType: UInt8 {
            switch value { case .varint: 0; case .fixed64: 1; case .bytes: 2; case .fixed32: 5 }
        }
        func uint64() throws -> UInt64 {
            guard case .varint(let value) = value else { throw LauncherError.io("wrong wire type") }
            return value
        }
        func int64() throws -> Int64 {
            let value = try uint64()
            guard value <= UInt64(Int64.max) else { throw LauncherError.io("integer overflow") }
            return Int64(value)
        }
        func bytes() throws -> Data {
            guard case .bytes(let data) = value else { throw LauncherError.io("wrong wire type") }
            return data
        }
        func string() throws -> String {
            guard let text = String(data: try bytes(), encoding: .utf8) else { throw LauncherError.io("invalid UTF-8") }
            return text
        }
    }
}
