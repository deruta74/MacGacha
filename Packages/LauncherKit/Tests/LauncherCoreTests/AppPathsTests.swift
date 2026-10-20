import Foundation
import Testing
import LauncherCore

@Test
func appPathsLayout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let paths = AppPaths(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(paths.root == root)
    #expect(paths.runtimes.path == root.appendingPathComponent("Runtimes").path)
    #expect(paths.prefixes.path == root.appendingPathComponent("Prefixes").path)
    #expect(paths.logs.path == root.appendingPathComponent("Logs").path)
    #expect(paths.consent.path == root.appendingPathComponent("consent.json").path)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try paths.ensureExists(paths.runtimes)
    try paths.ensureExists(paths.runtimes)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: paths.runtimes.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(!FileManager.default.fileExists(atPath: paths.prefixes.path))
}
