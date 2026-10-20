import Foundation
import Testing
import LauncherCore

@Test
func safePathRejects() {
    for raw in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a\\b", "a\u{0}b"] {
        #expect(throws: LauncherError.unsafePath(raw)) {
            try SafeRelativePath(raw)
        }
    }
}

@Test
func safePathAccepts() throws {
    let raw = "GenshinImpact_Data/StreamingAssets/a b/ü.blk"
    let path = try SafeRelativePath(raw)
    #expect(path.components == ["GenshinImpact_Data", "StreamingAssets", "a b", "ü.blk"])
    #expect(path.description == raw)
    let encoded = try JSONEncoder().encode(path)
    #expect(try JSONDecoder().decode(String.self, from: encoded) == raw)
    #expect(try JSONDecoder().decode(SafeRelativePath.self, from: encoded) == path)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(path.resolved(against: root).standardizedFileURL.path.hasPrefix(root.path + "/"))
}
