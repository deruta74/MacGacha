import Foundation
import Testing
import LauncherCore

@Test
func eventLogRedactsAndRotates() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = EventLog(directory: directory, maxFileBytes: 300, keepFiles: 3)
    await log.log(.error, "download", "failed: token=secret", metadata: ["TOKEN": "opaque", "version": "1"])
    let first = try String(contentsOf: directory.appendingPathComponent("macgacha.log"), encoding: .utf8)
    #expect(!first.contains("secret"))
    #expect(!first.contains("opaque"))
    #expect(first.contains("<redacted>"))
    let record = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    #expect(record["level"] as? String == "error")
    #expect(record["category"] as? String == "download")
    #expect(ISO8601DateFormatter().date(from: try #require(record["ts"] as? String)) != nil)
    #expect((record["metadata"] as? [String: String])?["version"] == "1")
    for index in 0..<20 { await log.log(.info, "test", "record \(index) token=secret") }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count <= 3)
    #expect(files.contains { $0.lastPathComponent == "macgacha.1.log" })
    for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 300)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        for line in data.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
    }
}

@Test
func eventLogBoundsOversizedRecordsAndHandlesInvalidLimits() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = EventLog(directory: directory, maxFileBytes: 1024, keepFiles: 1)
    await log.log(.warning, "token=category-secret", String(repeating: "é", count: 10_000),
        metadata: ["password": String(repeating: "secret", count: 10_000)])
    let data = try Data(contentsOf: directory.appendingPathComponent("macgacha.log"))
    #expect(data.count <= 1024)
    #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
    _ = try JSONSerialization.jsonObject(with: data)
    let invalid = EventLog(directory: directory.appendingPathComponent("invalid"), maxFileBytes: 0, keepFiles: 0)
    await invalid.log(.info, "test", "must not crash")
}

@Test
func eventLogRedactsBeforeBoundingMetadataKeys() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = EventLog(directory: directory, maxFileBytes: 1024)
    await log.log(.info, "test", "metadata", metadata: ["a": String(repeating: "x", count: 506), "password": "private-value"])
    let text = try String(contentsOf: directory.appendingPathComponent("macgacha.log"), encoding: .utf8)
    #expect(!text.contains("priva"))
}

@Test(arguments: [1, 2, 3])
func eventLogDoesNotRemoveDirectoriesDuringRotation(keepFiles: Int) async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unrelated = directory.appendingPathComponent("macgacha.1.log", isDirectory: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    let marker = unrelated.appendingPathComponent("keep")
    try Data("preserved".utf8).write(to: marker)
    try Data(repeating: 120, count: 200).write(to: directory.appendingPathComponent("macgacha.log"))
    await EventLog(directory: directory, maxFileBytes: 200, keepFiles: keepFiles).log(.info, "test", "rotate")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let current = try String(contentsOf: directory.appendingPathComponent("macgacha.log"), encoding: .utf8)
    #expect(current.contains("rotate"))
}

@Test
func eventLogRedactsBeforeTruncatingMessagesAndMetadata() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = #"{"\u0074oken":"planted-secret","padding":""# + String(repeating: "x", count: 6000) + "\"}"
    let log = EventLog(directory: directory, maxFileBytes: 1024, keepFiles: 2)
    await log.log(.info, "test", input)
    await log.log(.info, "test", "metadata", metadata: ["detail": input])
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("planted-secret"))
    }
}

@Test
func eventLogTinyLimitWithMultibyteTextReturnsPromptly() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = ContinuousClock()
    let started = clock.now
    for limit in [1, 32, 64, 100, 129] {
        let log = EventLog(directory: directory, maxFileBytes: limit)
        await log.log(.info, "é", String(repeating: "é", count: 101))
    }
    #expect(started.duration(to: clock.now) < .seconds(3))
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("\u{FFFD}"))
        for line in text.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
    }
}

@Test
func eventLogSerializesConcurrentWriters() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = EventLog(directory: directory)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<100 { group.addTask { await log.log(.debug, "parallel", "record \(index)") } }
    }
    let data = try Data(contentsOf: directory.appendingPathComponent("macgacha.log"))
    #expect(data.split(separator: 10).count == 100)
}

private func eventLogTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
