import Foundation
import Testing
import LauncherCore

@Test(arguments: ["wine-11.0", "DXMT_1.2", ".preview", String(repeating: "a", count: 128)])
func safeIdentifierRoundTrips(raw: String) throws {
    let identifier = try SafeIdentifier(raw)
    #expect(identifier.rawValue == raw)
    #expect(identifier.description == raw)
    #expect(try JSONDecoder().decode(SafeIdentifier.self, from: JSONEncoder().encode(identifier)) == identifier)
}

@Test(arguments: ["", ".", "..", "../escape", "/absolute", "a/b", "a\\b", "a b", "é", "a\u{0301}",
    "a\0b", "name\n", String(repeating: "a", count: 129)])
func safeIdentifierRejectsUnsafeInputAndDecoding(raw: String) throws {
    #expect(throws: LauncherError.unsafePath(raw)) { try SafeIdentifier(raw) }
    let data = try JSONEncoder().encode(raw)
    #expect(throws: LauncherError.unsafePath(raw)) { try JSONDecoder().decode(SafeIdentifier.self, from: data) }
}
