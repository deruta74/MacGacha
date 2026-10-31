// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Suite struct SurroundAudioTests {
    @Test func manifestRoundTripAndABIScope() throws {
        let component = try surroundComponent(Data("zip".utf8))
        let manifest = try RuntimeManifest(components: [component])
        let decoded = try JSONDecoder().decode(RuntimeManifest.self, from: JSONEncoder().encode(manifest))
        let value = try #require(decoded.components.first)
        #expect(value.kind == .surroundAudio)
        #expect(value.id.rawValue == SurroundAudio.componentID)
        #expect(value.kind.idPrefix == "surround-audio")
        #expect(value.kind.rawValue == "surroundAudio")
        #expect(value.license.name == "LGPL-2.1-or-later")
        #expect(value.rootPath == nil && value.wineBinary == nil && value.overlay.isEmpty)
        #expect(SurroundAudio.bundleID == "d3dmetal-wine11.20-gptk4.0b3")
    }

    @Test func installsVerifiesPinsAndRemovesZIP() async throws {
        let temp = try TempDir(); let cdn = MockCDN()
        let bytes = archiveTestData([ArchiveTestEntry("x86_64-unix/winecoreaudio.so", body: "module")], format: .zip)
        let component = try surroundComponent(bytes)
        let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
        cdn.serve("archive", data: bytes)
        let installer = surroundInstaller(store: store, cdn: cdn)
        for try await _ in installer.install(component) { }
        let installed = try #require(store.installed().first)
        #expect(installed.kind == .surroundAudio && installed.version == "wine-11.20-1")
        #expect(installed.archiveDigest == component.sha256)
        let fs = try ContainedFileSystem(root: store.installURL(for: component))
        #expect(try fs.readFile(at: SurroundAudio.modulePath, maxBytes: 1024) == Data("module".utf8))
        do {
            let pins = try RuntimeStore.componentLocks(paths: paths, componentIDs: [SurroundAudio.componentID], mode: .shared)
            #expect(throws: (any Error).self) { try store.remove(installed) }
            withExtendedLifetime(pins) { }
        }
        try store.remove(installed)
        #expect(try store.installed().isEmpty)
    }

    @Test func journalBlocksInstallAndRemovalUntilResolved() async throws {
        let temp = try TempDir(); let cdn = MockCDN(); let paths = AppPaths(root: temp.url)
        let bytes = archiveTestData([ArchiveTestEntry("x86_64-unix/winecoreaudio.so", body: "module")], format: .zip)
        let component = try surroundComponent(bytes); let store = RuntimeStore(paths: paths)
        cdn.serve("archive", data: bytes)
        for try await _ in surroundInstaller(store: store, cdn: cdn).install(component) { }
        let installed = try #require(store.installed().first)
        let fs = try ContainedFileSystem(root: paths.root)
        try fs.createDirectory(at: SafeRelativePath("Games/genshin"))
        try fs.writeAtomically(Data("unresolved".utf8), to: SafeRelativePath("Games/genshin/launch-session.json"))
        #expect(throws: (any Error).self) { try store.remove(installed) }
        await #expect(throws: (any Error).self) {
            for try await _ in surroundInstaller(store: store, cdn: cdn).install(component) { }
        }
        try fs.removeItem(at: SafeRelativePath("Games/genshin/launch-session.json"))
        try store.remove(installed)
        #expect(try store.installed().isEmpty)
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/surroundAudio/wine-11.20-1")) == nil)
    }

    @Test func rejectsUnverifiedArchiveBeforePublication() async throws {
        let temp = try TempDir(); let cdn = MockCDN(); let store = RuntimeStore(paths: AppPaths(root: temp.url))
        let expected = archiveTestData([ArchiveTestEntry("x86_64-unix/winecoreaudio.so", body: "good")], format: .zip)
        var corrupt = expected; corrupt[0] ^= 1
        cdn.serve("archive", data: corrupt)
        await #expect(throws: (any Error).self) {
            for try await _ in surroundInstaller(store: store, cdn: cdn).install(try surroundComponent(expected)) { }
        }
        #expect(try store.installed().isEmpty)
    }
}

private func surroundComponent(_ bytes: Data) throws -> RuntimeComponent {
    var hash = StreamingHasher(.sha256); hash.update(bytes)
    return try RuntimeComponent(id: SafeIdentifier(SurroundAudio.componentID), kind: .surroundAudio,
        version: SafeIdentifier("wine-11.20-1"), sourceMode: .download,
        url: URL(string: "https://fixtures.invalid/archive"), size: Int64(bytes.count), installedSize: 1024,
        sha256: hash.finalize(), archive: .zip,
        license: ComponentLicense(name: "LGPL-2.1-or-later", url: URL(string: "https://fixtures.invalid/license")!,
            redistributable: true, termsRevision: "1"))
}

private func surroundInstaller(store: RuntimeStore, cdn: MockCDN) -> ComponentInstaller {
    ComponentInstaller(store: store, consent: ConsentStore(url: store.paths.consent, root: store.paths.root),
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 4 << 30))
}
