import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport

@Test
func consentRequiresMatchingVersionAndNotice() async throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("state/consent.json")
    let date = Date(timeIntervalSince1970: 1000)
    let store = ConsentStore(url: url, clock: { date })
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    #expect(await store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    #expect(await !store.isAccepted(.appleGPTK, version: "3.1", termsRevision: "r1"))
    let records = try JSONDecoder().decode([ConsentRecord].self, from: Data(contentsOf: url))
    #expect(records.count == 1)
    #expect(records[0].acceptedAt == date)
    #expect(records[0].termsRevision == "r1")
    let reopened = ConsentStore(url: url)
    #expect(await reopened.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    let old = try ConsentRecord(kind: .appleGPTK, componentVersion: "3.0",
        noticeDigest: Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), termsRevision: "r1", acceptedAt: date)
    try JSONEncoder().encode([old]).write(to: url, options: .atomic)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    try await store.revoke(.appleGPTK)
    #expect(await !reopened.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
}

@Test
func consentRequiresCurrentTermsRevision() async throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("consent.json")
    let store = ConsentStore(url: url)
    try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r2"))
    try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r2")
    #expect(await store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r2"))
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    #expect(try JSONDecoder().decode([ConsentRecord].self, from: Data(contentsOf: url)).count == 1)
}

@Test
func consentFailsClosedForMalformedAndLegacyRecords() async throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("consent.json")
    let store = ConsentStore(url: url)
    try Data("{broken".utf8).write(to: url)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: (any Error).self) { try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(try Data(contentsOf: url) == Data("{broken".utf8))
    let legacy: [String: Any] = ["kind": "appleGPTK", "componentVersion": "3.0", "acceptedAt": 0,
        "noticeDigest": ["algorithm": "sha256", "hex": AppleNotice.bodyDigest.hex]]
    let data = try JSONSerialization.data(withJSONObject: [legacy])
    try data.write(to: url)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    #expect(throws: (any Error).self) { try JSONDecoder().decode([ConsentRecord].self, from: data) }
    await #expect(throws: (any Error).self) { try await store.accept(.appleGPTK, version: "../escape", termsRevision: "r1") }
}

@Test
func appleNoticeUsesMacGachaAndHashesExactBody() {
    #expect(AppleNotice.title == "Apple Game Porting Toolkit License")
    #expect(AppleNotice.body.contains("MacGacha is not affiliated with"))
    #expect(!AppleNotice.body.contains("Wayfarer"))
    #expect(AppleNotice.termsURL.absoluteString == "https://developer.apple.com/games/game-porting-toolkit/")
    var hasher = StreamingHasher(.sha256)
    hasher.update(Data(AppleNotice.body.utf8))
    #expect(AppleNotice.bodyDigest == hasher.finalize())
}

@Test
func consentValidatesDecodedRecordsAndRejectsUnsafeDestinations() async throws {
    let directory = try TempDir()
    let target = directory.url.appendingPathComponent("original.json")
    let original = Data("preserved".utf8)
    try original.write(to: target)
    let symlink = directory.url.appendingPathComponent("consent.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let store = ConsentStore(url: symlink)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: (any Error).self) { try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(try Data(contentsOf: target) == original)
    let valid = try ConsentRecord(kind: .appleGPTK, componentVersion: "3.0", noticeDigest: AppleNotice.bodyDigest,
        termsRevision: "r1", acceptedAt: Date())
    let encoded = try JSONEncoder().encode(valid)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for (key, value) in [("componentVersion", "../escape"), ("termsRevision", "")] {
        var invalid = object
        invalid[key] = value
        let data = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ConsentRecord.self, from: data) }
    }
}

@Test
func consentRejectsNonFileURLStorage() async throws {
    let directory = try TempDir()
    let file = directory.url.appendingPathComponent("consent.json")
    let valid = ConsentStore(url: file)
    try await valid.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    var remote = URLComponents()
    remote.scheme = "https"
    remote.host = "example.test"
    remote.path = file.path
    let invalid = ConsentStore(url: try #require(remote.url))
    #expect(await !invalid.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: (any Error).self) { try await invalid.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(await valid.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
}

@Test
func consentRejectsOversizedAndDuplicateRecords() async throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("consent.json")
    let record = try ConsentRecord(kind: .appleGPTK, componentVersion: "3.0", noticeDigest: AppleNotice.bodyDigest,
        termsRevision: "r1", acceptedAt: Date())
    try JSONEncoder().encode([record, record]).write(to: url)
    let store = ConsentStore(url: url)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    try Data(repeating: 32, count: 65_537).write(to: url)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: (any Error).self) { try await store.revoke(.appleGPTK) }
}
