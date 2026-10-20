// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
    let store = ConsentStore(url: url, root: directory.url, clock: { date })
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    #expect(await store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    #expect(await !store.isAccepted(.appleGPTK, version: "3.1", termsRevision: "r1"))
    let records = try JSONDecoder().decode([ConsentRecord].self, from: Data(contentsOf: url))
    #expect(records.count == 1)
    #expect(records[0].acceptedAt == date)
    #expect(records[0].termsRevision == "r1")
    let reopened = ConsentStore(url: url, root: directory.url)
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
    let store = ConsentStore(url: url, root: directory.url)
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
    let store = ConsentStore(url: url, root: directory.url, clock: { Date(timeIntervalSince1970: 1000) })
    let legacy: [String: Any] = ["kind": "appleGPTK", "componentVersion": "3.0", "acceptedAt": 0,
        "noticeDigest": ["algorithm": "sha256", "hex": AppleNotice.bodyDigest.hex]]
    let data = try JSONSerialization.data(withJSONObject: [legacy])
    do { _ = try JSONDecoder().decode([ConsentRecord].self, from: data); Issue.record("Legacy records must fail closed") }
    catch DecodingError.keyNotFound(let key, _) { #expect(key.stringValue == "termsRevision") }
    for corrupt in [Data("{broken".utf8), data] {
        for revoking in [false, true] {
            try await expectConsentRecovery(store, url: url, corrupt: corrupt, revoking: revoking)
        }
    }
    await #expect(throws: LauncherError.unsafePath("../escape")) {
        try await store.accept(.appleGPTK, version: "../escape", termsRevision: "r1")
    }
}

@Test
func appleNoticeUsesMacGachaAndHashesExactBody() {
    #expect(AppleNotice.title == "Apple Game Porting Toolkit License")
    #expect(AppleNotice.body == "D3DMetal and the Game Porting Toolkit are © Apple Inc. and are licensed under Apple's terms. MacGacha is not affiliated with, endorsed by, or supported by Apple. By continuing, you confirm that you have read and accept Apple's Game Porting Toolkit license terms and that you will use this component in accordance with them. You can decline and use DXMT instead, or import Game Porting Toolkit that you downloaded from Apple yourself.")
    #expect(AppleNotice.termsURL.absoluteString == "https://developer.apple.com/games/game-porting-toolkit/")
    #expect(AppleNotice.bodyDigest.hex == "b0cce478203436c55f39fb392be297c5eae0a9c373829ffb6c26a626114a71f5")
}

@Test
func consentValidatesDecodedRecordsAndRejectsUnsafeDestinations() async throws {
    let directory = try TempDir()
    let target = directory.url.appendingPathComponent("original.json")
    let original = Data("preserved".utf8)
    try original.write(to: target)
    let symlink = directory.url.appendingPathComponent("consent.json")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let store = ConsentStore(url: symlink, root: directory.url)
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: LauncherError.unsafePath(symlink.path)) { try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(try Data(contentsOf: target) == original)
    let valid = try ConsentRecord(kind: .appleGPTK, componentVersion: "3.0", noticeDigest: AppleNotice.bodyDigest,
        termsRevision: "r1", acceptedAt: Date())
    let encoded = try JSONEncoder().encode(valid)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for (key, value, error) in [("componentVersion", "../escape", LauncherError.unsafePath("../escape")), ("termsRevision", "", .io("Invalid terms revision"))] {
        var invalid = object
        invalid[key] = value
        let data = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: error) { try JSONDecoder().decode(ConsentRecord.self, from: data) }
    }
}

@Test
func consentRejectsNonFileURLStorage() async throws {
    let directory = try TempDir()
    let file = directory.url.appendingPathComponent("consent.json")
    let valid = ConsentStore(url: file, root: directory.url)
    try await valid.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
    var remote = URLComponents()
    remote.scheme = "https"
    remote.host = "example.test"
    remote.path = file.path
    let invalid = ConsentStore(url: try #require(remote.url), root: directory.url)
    #expect(await !invalid.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    await #expect(throws: LauncherError.io("Runtime JSON requires file URLs")) { try await invalid.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(await valid.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
}

@Test
func consentRecoversOversizedAndDuplicateRecords() async throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("consent.json")
    let record = try ConsentRecord(kind: .appleGPTK, componentVersion: "3.0", noticeDigest: AppleNotice.bodyDigest,
        termsRevision: "r1", acceptedAt: Date())
    let store = ConsentStore(url: url, root: directory.url, clock: { Date(timeIntervalSince1970: 1000) })
    for corrupt in [try JSONEncoder().encode([record, record]), Data(repeating: 32, count: 65_537)] {
        for revoking in [false, true] {
            try await expectConsentRecovery(store, url: url, corrupt: corrupt, revoking: revoking)
        }
    }
}

private func expectConsentRecovery(_ store: ConsentStore, url: URL, corrupt: Data, revoking: Bool) async throws {
    try corrupt.write(to: url)
    let parent = url.deletingLastPathComponent()
    let before = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
    #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
    #expect(try Data(contentsOf: url) == corrupt)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() == before)
    if revoking { try await store.revoke(.appleGPTK) }
    else { try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1") }
    #expect(await store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1") == !revoking)
    let records = try JSONDecoder().decode([ConsentRecord].self, from: Data(contentsOf: url))
    #expect(records.count == (revoking ? 0 : 1))
    let after = try FileManager.default.contentsOfDirectory(atPath: parent.path)
    let newBackups = after.filter { !before.contains($0) && $0.hasPrefix("consent.json.corrupt-") }
    let backup = try #require(newBackups.count == 1 ? newBackups.first : nil)
    #expect(try Data(contentsOf: parent.appendingPathComponent(backup)) == corrupt)
}

@Test
func consentRefusesDeepAncestorSymlinksAndOutOfRootTargets() async throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let target = outside.url.appendingPathComponent("nested/deeper/consent.json")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("[]".utf8)
    try original.write(to: target)
    try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("safe"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("safe/link"), withDestinationURL: outside.url)
    let redirected = directory.url.appendingPathComponent("safe/link/nested/deeper/consent.json")
    for url in [redirected, target] {
        let store = ConsentStore(url: url, root: directory.url)
        #expect(await !store.isAccepted(.appleGPTK, version: "3.0", termsRevision: "r1"))
        do {
            try await store.accept(.appleGPTK, version: "3.0", termsRevision: "r1")
            Issue.record("Consent writes must stay below the trusted root without symlinks")
        } catch LauncherError.unsafePath {}
        do {
            try await store.revoke(.appleGPTK)
            Issue.record("Consent revocation must refuse redirected paths")
        } catch LauncherError.unsafePath {}
        #expect(try Data(contentsOf: target) == original)
    }
}
