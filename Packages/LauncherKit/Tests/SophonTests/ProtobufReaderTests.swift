// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import Testing
@testable import Sophon

@Suite struct ProtobufReaderTests {
    @Test func fixedVectorTenByteVarint() throws {
        // Nine ff bytes contribute 7 one-bits each; 01 contributes bit 63.
        var reader = ProtobufReader(hexBytes("ff ff ff ff ff ff ff ff ff 01"))
        let value = try reader.readVarint()
        #expect(value == UInt64.max)
    }

    @Test func rejectsVarintLongerThanTenBytes() {
        // Ten continuation bytes plus an eleventh terminating byte cannot fit uint64.
        var reader = ProtobufReader(hexBytes("80 80 80 80 80 80 80 80 80 80 00"))
        #expect(throws: LauncherError.io("invalid varint")) { try reader.readVarint() }
    }

    @Test(arguments: ["ff ff ff ff ff ff ff ff ff 02", "80 80 80 80 80 80 80 80 80 81"])
    func rejectsTenthByteAboveOne(hex: String) {
        // Only 00 or 01 is valid in the tenth uint64 byte, with no continuation bit.
        var reader = ProtobufReader(hexBytes(hex))
        #expect(throws: LauncherError.io("invalid varint")) { try reader.readVarint() }
    }

    @Test func rejectsTruncatedVarintAndOverlongLength() {
        // 80 needs another byte; 0a is field 1/bytes, 04 claims four absent bytes.
        var truncated = ProtobufReader(hexBytes("80"))
        #expect(throws: LauncherError.io("truncated protobuf")) { try truncated.readVarint() }
        var length = ProtobufReader(hexBytes("0a 04 61"))
        #expect(throws: LauncherError.io("truncated protobuf")) { try length.nextField() }
        // 0a followed by uint64.max must be checked before converting length to Int.
        var huge = ProtobufReader(hexBytes("0a ff ff ff ff ff ff ff ff ff 01"))
        #expect(throws: LauncherError.io("truncated protobuf")) { try huge.nextField() }
    }

    @Test(arguments: ["0b", "0c", "0e", "0f", "00", "80 80 80 80 10"])
    func rejectsGroupWireTypesAndInvalidTags(hex: String) {
        // Field 1 with wire 3/4 (groups), 6/7 (invalid); field 0; field 2^29 (too large).
        var reader = ProtobufReader(hexBytes(hex))
        #expect(throws: LauncherError.io("invalid protobuf field")) { try reader.nextField() }
    }

    @Test func readerSkipsUnknownFieldsOfEveryWireType() throws {
        // Field 6: 30/0=varint 150; 31/1=fixed64; 32/2=two bytes; 35/5=fixed32.
        // Field 99 uses two-byte keys 98 06/99 06/9a 06/9d 06 for those same wires.
        let data = hexBytes("""
            30 96 01 31 01 02 03 04 05 06 07 08 32 02 aa bb 35 01 02 03 04
            98 06 01 99 06 01 02 03 04 05 06 07 08 9a 06 02 aa bb 9d 06 01 02 03 04
            """)
        var reader = ProtobufReader(data)
        var fields: [Int] = []; var wires: [UInt8] = []
        while let field = try reader.nextField() {
            fields.append(field.number); wires.append(field.wireType)
        }
        #expect(fields == [6, 6, 6, 6, 99, 99, 99, 99])
        #expect(wires == [0, 1, 2, 5, 0, 1, 2, 5])
        #expect(try SophonManifest.decode(data).files.isEmpty)
    }

    @Test(arguments: ["09 00", "0d 00"])
    func rejectsTruncatedFixedWidthFields(hex: String) {
        // 09/0d are field 1 fixed64/fixed32, with only one payload byte.
        var reader = ProtobufReader(hexBytes(hex))
        #expect(throws: LauncherError.io("truncated protobuf")) { try reader.nextField() }
    }

    @Test func nestingIsBounded() throws {
        // Five nested field-1 length-delimited messages, the innermost is empty.
        var reader = ProtobufReader(hexBytes("0a 08 0a 06 0a 04 0a 02 0a 00"))
        for _ in 0..<4 {
            let next = try reader.nextField()
            reader = try reader.child(try #require(next))
        }
        #expect(throws: LauncherError.io("protobuf nesting limit")) {
            let next = try reader.nextField()
            return try reader.child(try #require(next))
        }
    }

    @Test func nonzeroDataStartIndexIsSupported() throws {
        // The leading ff is outside the Data slice; 08 96 01 is field 1, varint 150.
        let data = hexBytes("ff 08 96 01")
        var reader = ProtobufReader(data.dropFirst())
        let next = try reader.nextField()
        let field = try #require(next)
        #expect(field.number == 1)
        #expect(try field.uint64() == 150)
        let end = try reader.nextField()
        #expect(end == nil)
    }
}

func hexBytes(_ hex: String) -> Data {
    Data(hex.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! })
}
