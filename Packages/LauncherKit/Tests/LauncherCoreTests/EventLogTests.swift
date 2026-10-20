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
    for index in 0..<20 { await log.log(.info, "test", "record \(index) token=secret " + String(repeating: "x", count: 100)) }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 3)
    #expect(files.contains { $0.lastPathComponent == "macgacha.1.log" })
    for (name, index) in [("macgacha.log", 19), ("macgacha.1.log", 18), ("macgacha.2.log", 17)] {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        #expect(text.contains("record \(index) token=<redacted>"))
        #expect(text.split(separator: "\n").count == 1)
    }
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
func eventLogTinyLimitWithMultibyteTextCompletes() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for limit in [1, 32, 64, 100, 129] {
        let log = EventLog(directory: directory, maxFileBytes: limit)
        await log.log(.info, "é", String(repeating: "é", count: 101))
    }
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

@Test
func eventLogOmitsInputsAboveOneMiBBeforeRedaction() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let value = String(repeating: "x", count: (1 << 20) + 1)
    await EventLog(directory: directory).log(.info, "test", value, metadata: ["detail": value])
    let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("macgacha.log"))) as? [String: Any])
    #expect(record["message"] as? String == "<omitted 1048577 bytes>")
    #expect((record["metadata"] as? [String: String])?["detail"] == "<omitted 1048577 bytes>")
}

@Test
func eventLogSortsBeforeSelectingMetadataAndPreservesProcessedKeyCollisions() async throws {
    let directory = try eventLogTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var metadata: [String: String] = [:]
    for index in 0..<256 { metadata[String(format: "key%03d", index)] = "value" }
    let log = EventLog(directory: directory)
    await log.log(.info, "test", "sorted", metadata: metadata)
    var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("macgacha.log"))) as? [String: Any])
    let values = try #require(record["metadata"] as? [String: String])
    #expect(values.keys.sorted() == metadata.keys.sorted().prefix(128).map { $0 })
    let prefix = String(repeating: "k", count: 1024)
    let collisions = Dictionary(uniqueKeysWithValues: (1...3).map { (prefix + String($0), "value\($0)") })
    let collisionDirectory = directory.appendingPathComponent("collisions")
    await EventLog(directory: collisionDirectory).log(.info, "test", "collisions", metadata: collisions)
    record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: collisionDirectory.appendingPathComponent("macgacha.log"))) as? [String: Any])
    let result = try #require(record["metadata"] as? [String: String])
    #expect(result[prefix] == "value1")
    #expect(result[prefix + "#2"] == "value2")
    #expect(result[prefix + "#3"] == "value3")
}

private func eventLogTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
