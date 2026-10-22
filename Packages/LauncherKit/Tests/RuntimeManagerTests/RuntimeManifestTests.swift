// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport

@Test
func loadsBundledShapeManifest() throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("manifest.json")
    try manifestFixtureData().write(to: url)
    let manifest = try RuntimeManifest.load(from: url)
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.components.map(\.kind) == [.wine, .dxmt, .d3dmetal])
    #expect(manifest.components[0].id.rawValue == "wine-11.0")
    #expect(manifest.components[0].version.rawValue == "11.0")
    #expect(manifest.components[0].installedSize == 1000)
    #expect(manifest.components[2].consent == .appleGPTK)
    #expect(manifest.components[2].license.termsRevision == "2026-10")
    let decoded = try JSONDecoder().decode(RuntimeManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.components.count == 3)
}

@Test
func rejectsDownloadWithoutHash() throws {
    let data = try manifestFixtureData { $0[0].removeValue(forKey: "sha256") }
    #expect(throws: LauncherError.io("Download runtime is missing URL, sizes, SHA-256 or archive format")) { try JSONDecoder().decode(RuntimeManifest.self, from: data) }
}

@Test
func rejectsNonRedistributableWithoutConsent() throws {
    let data = try manifestFixtureData { $0[2].removeValue(forKey: "consent") }
    #expect(throws: LauncherError.consentRequired("d3dmetal")) { try JSONDecoder().decode(RuntimeManifest.self, from: data) }
}

@Test
func rejectsUnknownSchemaVersion() throws {
    let directory = try TempDir()
    let url = directory.url.appendingPathComponent("manifest.json")
    let object: [String: Any] = ["schemaVersion": 1, "components": []]
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    #expect(throws: LauncherError.io("Unsupported runtime manifest schema")) { try RuntimeManifest.load(from: url) }
    #expect(throws: LauncherError.io("Unsupported runtime manifest schema")) { try RuntimeManifest(schemaVersion: 1, components: []) }
}

@Test(arguments: ["url", "size", "installedSize", "sha256", "archive"])
func manifestDownloadRequiresEveryField(field: String) throws {
    let data = try manifestFixtureData { $0[0].removeValue(forKey: field) }
    #expect(throws: LauncherError.io("Download runtime is missing URL, sizes, SHA-256 or archive format")) {
        try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

@Test(arguments: ["download", "import"])
func d3dmetalRequiresAppleConsentRegardlessOfRedistributability(mode: String) throws {
    let data = try manifestFixtureData {
        $0[2]["sourceMode"] = mode
        if mode == "import" {
            for key in ["url", "size", "installedSize", "sha256", "archive"] { $0[2].removeValue(forKey: key) }
        }
        $0[2].removeValue(forKey: "consent")
        var license = $0[2]["license"] as! [String: Any]
        license["redistributable"] = true
        $0[2]["license"] = license
    }
    #expect(throws: LauncherError.consentRequired("d3dmetal")) {
        try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
    let nonApple = try manifestFixtureData {
        var license = $0[0]["license"] as! [String: Any]
        license["redistributable"] = false
        $0[0]["license"] = license
    }
    #expect(throws: LauncherError.consentRequired("wine")) {
        try JSONDecoder().decode(RuntimeManifest.self, from: nonApple)
    }
}

@Test
func manifestRejectsUnsafeIdentifiersAndInvalidSizes() throws {
    for version in ["../escape", ".preview"] {
        let data = try manifestFixtureData {
            $0[0]["version"] = version
            $0[0]["id"] = "wine-\(version)"
        }
        let unsafe = version == ".preview" ? version : "wine-\(version)"
        #expect(throws: LauncherError.unsafePath(unsafe)) { try JSONDecoder().decode(RuntimeManifest.self, from: data) }
    }
    let badID = try manifestFixtureData { $0[0]["id"] = "../wine" }
    #expect(throws: LauncherError.unsafePath("../wine")) { try JSONDecoder().decode(RuntimeManifest.self, from: badID) }
    let changes: [((inout [String: Any]) -> Void, LauncherError)] = [
        ({ $0["size"] = -1 }, .io("Runtime sizes must be nonnegative")),
        ({ $0["installedSize"] = -1 }, .io("Runtime sizes must be nonnegative")),
        ({ $0["sha256"] = ["algorithm": "md5", "hex": String(repeating: "a", count: 32)] }, .io("Runtime digest must use SHA-256")),
        ({ $0["url"] = "relative/path" }, .io("Runtime URLs must be absolute HTTP(S) URLs without credentials")),
    ]
    for (change, error) in changes {
        let data = try manifestFixtureData { change(&$0[0]) }
        #expect(throws: error) { try JSONDecoder().decode(RuntimeManifest.self, from: data) }
    }
    let legacy = try manifestFixtureData {
        $0[0]["license"] = ["name": "License", "url": "https://example.test/license", "redistributable": true]
    }
    do { _ = try JSONDecoder().decode(RuntimeManifest.self, from: legacy); Issue.record("Missing termsRevision must fail") }
    catch DecodingError.keyNotFound(let key, _) { #expect(key.stringValue == "termsRevision") }
}

@Test(arguments: [ComponentKind.wine, .dxmt], [false, true])
func appleConsentIsRejectedForNonAppleComponents(kind: ComponentKind, redistributable: Bool) throws {
    let data = try manifestFixtureData {
        let index = kind == .wine ? 0 : 1
        $0[index]["consent"] = "appleGPTK"
        var license = $0[index]["license"] as! [String: Any]
        license["redistributable"] = redistributable
        $0[index]["license"] = license
    }
    #expect(throws: LauncherError.consentRequired(kind.rawValue)) {
        try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

@Test(arguments: [ComponentKind.wine, .dxmt])
func nonRedistributableNonAppleComponentsHaveNoValidConsent(kind: ComponentKind) throws {
    let data = try manifestFixtureData {
        let index = kind == .wine ? 0 : 1
        $0[index].removeValue(forKey: "consent")
        var license = $0[index]["license"] as! [String: Any]
        license["redistributable"] = false
        $0[index]["license"] = license
    }
    #expect(throws: LauncherError.consentRequired(kind.rawValue)) {
        try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

@Test
func manifestAcceptsImportWithoutDownloadFields() throws {
    let data = try manifestFixtureData {
        $0[2]["sourceMode"] = "import"
        for key in ["url", "size", "installedSize", "sha256", "archive"] { $0[2].removeValue(forKey: key) }
    }
    let component = try JSONDecoder().decode(RuntimeManifest.self, from: data).components[2]
    #expect(component.sourceMode == .importFromGPTK)
    #expect(component.url == nil)
    #expect(component.installedSize == nil)
    #expect(component.consent == .appleGPTK)
}

@Test
func manifestRequiresKindVersionIDAndUniqueCaseInsensitiveDestinations() throws {
    let mismatch = try manifestFixtureData { $0[0]["id"] = "wrong-11.0" }
    #expect(throws: LauncherError.io("Runtime component ID must be <kind>-<version>")) { try JSONDecoder().decode(RuntimeManifest.self, from: mismatch) }
    for version in ["11.0", "Release", "release"] {
        let collision = try manifestFixtureData {
            $0[0]["version"] = version == "11.0" ? "11.0" : "Release"
            $0[0]["id"] = "wine-\($0[0]["version"]!)"
            var duplicate = $0[0]
            duplicate["version"] = version
            duplicate["id"] = "wine-\(version)"
            $0.append(duplicate)
        }
        #expect(throws: LauncherError.io(version == "release" ? "Colliding runtime install destinations" : "Duplicate runtime component ID")) { try JSONDecoder().decode(RuntimeManifest.self, from: collision) }
    }
}

@Test
func manifestFileLoaderRejectsNonFileURLs() throws {
    let directory = try TempDir()
    let file = directory.url.appendingPathComponent("manifest.json")
    try manifestFixtureData().write(to: file)
    var remote = URLComponents()
    remote.scheme = "https"
    remote.host = "example.test"
    remote.path = file.path
    let url = try #require(remote.url)
    #expect(throws: LauncherError.unsafePath(url.deletingLastPathComponent().absoluteString)) { try RuntimeManifest.load(from: url) }
}

@Test
func manifestRejectsDuplicatesAndOversizedFiles() throws {
    let data = try manifestFixtureData { $0.append($0[0]) }
    #expect(throws: LauncherError.io("Duplicate runtime component ID")) { try JSONDecoder().decode(RuntimeManifest.self, from: data) }
    let directory = try TempDir()
    let file = directory.url.appendingPathComponent("huge.json")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 2 << 20)
    try handle.close()
    #expect(throws: LauncherError.fileTooLarge(path: file.path, limit: 1 << 20)) { try RuntimeManifest.load(from: file) }
}

private func manifestFixtureData(_ modify: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
    var components: [[String: Any]] = ["wine", "dxmt", "d3dmetal"].map { kind in
        ["id": "\(kind)-11.0", "kind": kind, "version": "11.0", "sourceMode": "download",
         "url": "https://example.test/\(kind).tar.gz", "size": 100, "installedSize": 1000,
         "sha256": ["algorithm": "sha256", "hex": String(repeating: "a", count: 64)], "archive": "tar.gz",
         "license": ["name": "License", "url": "https://example.test/license", "redistributable": kind != "d3dmetal",
             "termsRevision": "2026-10"]]
    }
    components[2]["consent"] = "appleGPTK"
    modify(&components)
    return try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "components": components])
}
