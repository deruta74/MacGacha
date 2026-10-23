// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Suite struct CompatibilityComponentTests {
    @Test func manifestDecodesCompatComponents() throws {
        let components = try ["jadeite", "steamShim"].map { try compatibilityComponent($0) }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 3, "components": components])
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        #expect(manifest.schemaVersion == 3)
        #expect(manifest.components.map { $0.kind.rawValue } == ["jadeite", "steamShim"])
        #expect(manifest.components[0].sha256?.hex == "12d4c37b09d3e81640536fd68c2c62913fc4b4a90c0183e4dec845e4934a9858")
        #expect(manifest.components[0].rootPath == nil)
        #expect(manifest.components[1].kind == .steamShim)
        #expect(manifest.component(id: try SafeIdentifier("jadeite-4.1.0"))?.kind == .jadeite)
        #expect(manifest.component(id: try SafeIdentifier("absent")) == nil)
        #expect(try JSONDecoder().decode(RuntimeManifest.self, from: JSONEncoder().encode(manifest)).components.count == 2)
    }

    @Test(arguments: ["jadeite", "steamShim"], ["wineBinary", "overlay", "consent"])
    func compatComponentRejectsRuntimeLayout(kind: String, field: String) throws {
        var component = try compatibilityComponent(kind)
        _ = try JSONDecoder().decode(RuntimeComponent.self, from: JSONSerialization.data(withJSONObject: component))
        switch field {
        case "wineBinary": component[field] = "bin/wine"
        case "overlay": component[field] = [["source": "dll", "destination": "lib/wine/x86_64-windows"]]
        default: component[field] = "appleGPTK"
        }
        let bytes = try JSONSerialization.data(withJSONObject: component)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RuntimeComponent.self, from: bytes) }
    }

    @Test func crossOverDXMTBundleValidates() throws {
        let bytes = try bundleManifestData { object in
            var components = object["components"] as! [[String: Any]]
            components[0]["id"] = "wine-11.0-1-crossover"; components[0]["version"] = "11.0-1-crossover"
            object["schemaVersion"] = 3; object["components"] = components
            object["bundles"] = [["id": "dxmt-wine11.0cx-dxmt0.80", "displayName": "DXMT", "backend": "dxmt",
                "components": ["wine-11.0-1-crossover", "dxmt-1"]]]
        }
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: bytes)
        #expect(manifest.bundles[0].components[0].rawValue == "wine-11.0-1-crossover")
        #expect(manifest.defaultBundle(for: .dxmt)?.id == manifest.bundles[0].id)
        #expect(manifest.defaultBundle(for: .d3dmetal) == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["jadeite", "steamShim"])
    func installsAndRemovesCompatibilityZIP(kind: String) async throws {
        let temp = try TempDir(); let paths = AppPaths(root: temp.url)
        let cdn = MockCDN(); let store = RuntimeStore(paths: paths)
        let prefix = kind == "jadeite" ? "" : "steam-shim-proton-10.0-4/"
        let leaf = kind == "jadeite" ? "jadeite.exe" : "steam64.exe"
        let bytes = archiveTestData([ArchiveTestEntry(prefix + leaf, body: "pe"),
            ArchiveTestEntry(prefix + "LICENSE.txt", body: "license")], format: .zip)
        var object = try compatibilityComponent(kind)
        var hash = StreamingHasher(.sha256); hash.update(bytes)
        object["sha256"] = ["algorithm": "sha256", "hex": hash.finalize().hex]
        object["size"] = bytes.count; object["installedSize"] = 9
        let component = try JSONDecoder().decode(RuntimeComponent.self, from: JSONSerialization.data(withJSONObject: object))
        cdn.serve("archive", data: bytes)
        let installer = ComponentInstaller(store: store, consent: ConsentStore(url: paths.consent, root: temp.url),
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 4 << 30))
        for try await _ in installer.install(component) { }
        #expect(try Data(contentsOf: store.installURL(for: component).appendingPathComponent(leaf)) == Data("pe".utf8))
        let installed = try #require(store.installed().first)
        #expect(installed.kind == component.kind)
        try store.remove(installed)
        #expect(try store.installed().isEmpty)
    }

    @Test func rootedZIPSelectsNormalizedMembersLiterally() async throws {
        let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
        let archive = temp.url.appendingPathComponent("archive")
        try archiveTestData([ArchiveTestEntry("./shim/steam64.exe", body: "pe"),
            ArchiveTestEntry("./shim/literal*file", body: "notice"),
            ArchiveTestEntry("shim-other/extra", body: "outside")], format: .zip).write(to: archive)
        try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive: SafeRelativePath("archive"),
            archiveFS: fs, archiveURL: archive, format: .zip, fs: fs, target: SafeRelativePath("out"),
            expandedLimit: 1000, rootPath: SafeRelativePath("shim"))
        #expect(try fs.readFile(at: SafeRelativePath("out/steam64.exe"), maxBytes: 10) == Data("pe".utf8))
        #expect(try fs.readFile(at: SafeRelativePath("out/literal*file"), maxBytes: 10) == Data("notice".utf8))
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("out")).map(\.description).sorted() == ["out/literal*file", "out/steam64.exe"])
    }
}

private func compatibilityComponent(_ kind: String) throws -> [String: Any] {
    let jadeite = kind == "jadeite"
    var result: [String: Any] = ["id": jadeite ? "jadeite-4.1.0" : "steam-shim-proton-10.0-4", "kind": kind,
        "version": jadeite ? "4.1.0" : "proton-10.0-4", "sourceMode": "download",
        "url": "https://fixtures.invalid/archive", "size": 100, "installedSize": 1000, "archive": "zip",
        "sha256": ["algorithm": "sha256", "hex": "12d4c37b09d3e81640536fd68c2c62913fc4b4a90c0183e4dec845e4934a9858"],
        "license": ["name": jadeite ? "MIT" : "BSD-3-Clause", "url": "https://fixtures.invalid/license",
            "redistributable": true, "termsRevision": "1"]]
    if !jadeite { result["rootPath"] = "steam-shim-proton-10.0-4" }
    return result
}
