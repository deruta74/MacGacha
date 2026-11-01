// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Suite struct GenshinFpsTests {
    @Test func manifestRoundTripAndComponentIdentity() throws {
        let component = try fpsComponent(Data("zip".utf8))
        let manifest = try RuntimeManifest(components: [component])
        let decoded = try JSONDecoder().decode(RuntimeManifest.self, from: JSONEncoder().encode(manifest))
        let value = try #require(decoded.components.first)
        #expect(value.id.rawValue == "genshin-fps-unlock-1")
        #expect(value.kind == .genshinFps && value.kind.rawValue == "genshinFps")
        #expect(value.kind.idPrefix == "genshin-fps-unlock")
        #expect(value.version.rawValue == GenshinFps.version)
        #expect(value.rootPath == (try SafeRelativePath("x86_64-windows")))
        #expect(value.license.name == "GPL-3.0-only" && value.license.redistributable)
        #expect(value.consent == nil && value.wineBinary == nil && value.overlay.isEmpty)
        #expect(throws: (any Error).self) {
            _ = try RuntimeComponent(id: SafeIdentifier("genshinFps-1"), kind: .genshinFps,
                version: SafeIdentifier("1"), sourceMode: .download, url: component.url, size: component.size,
                installedSize: component.installedSize, sha256: component.sha256, archive: .zip, license: component.license)
        }
    }

    @Test(arguments: GameDefinition.all)
    func eligibilityIsOnlyGenshinAndHasNoBackendRestriction(game: GameDefinition) {
        #expect(GenshinFps.applies(to: game.id) == (game.family == .genshin))
        #expect(!GenshinFps.applies(to: "unknown"))
    }

    @Test func installsSelectedRootVerifiesPinsAndRemoves() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), cdn = MockCDN()
        let store = RuntimeStore(paths: paths), bytes = fpsArchive()
        let component = try fpsComponent(bytes)
        cdn.serve("archive", data: bytes)
        for try await _ in fpsInstaller(store, cdn).install(component) { }
        let installed = try #require(store.installed().first)
        #expect(installed.kind == .genshinFps && installed.version == "1")
        #expect(installed.archiveDigest == component.sha256)
        let fs = try ContainedFileSystem(root: store.installURL(for: component))
        #expect(try fs.readFile(at: GenshinFps.injectorPath, maxBytes: 100) == Data("injector".utf8))
        #expect(try fs.readFile(at: GenshinFps.stubPath, maxBytes: 100) == Data("stub".utf8))
        #expect(try fs.itemType(at: SafeRelativePath("README.md")) == nil)
        do {
            let pins = try RuntimeStore.componentLocks(paths: paths, componentIDs: [GenshinFps.componentID], mode: .shared)
            #expect(throws: (any Error).self) { try store.remove(installed) }
            withExtendedLifetime(pins) { }
        }
        try store.remove(installed)
        #expect(try store.installed().isEmpty)
    }

    @Test func unresolvedJournalBlocksInstallAndRemoval() async throws {
        let temp = try TempDir(), paths = AppPaths(root: temp.url), cdn = MockCDN()
        let store = RuntimeStore(paths: paths), bytes = fpsArchive(), component = try fpsComponent(bytes)
        cdn.serve("archive", data: bytes)
        for try await _ in fpsInstaller(store, cdn).install(component) { }
        let installed = try #require(store.installed().first)
        let fs = try ContainedFileSystem(root: paths.root)
        try fs.createDirectory(at: SafeRelativePath("Games/genshin"))
        try fs.writeAtomically(Data("unresolved".utf8), to: SafeRelativePath("Games/genshin/launch-session.json"))
        #expect(throws: (any Error).self) { try store.remove(installed) }
        await #expect(throws: (any Error).self) {
            for try await _ in fpsInstaller(store, cdn).install(component) { }
        }
        try fs.removeItem(at: SafeRelativePath("Games/genshin/launch-session.json"))
        try store.remove(installed)
        #expect(try store.installed().isEmpty)
    }

    @Test func rejectsChangedArchiveBeforePublication() async throws {
        let temp = try TempDir(), cdn = MockCDN(), store = RuntimeStore(paths: AppPaths(root: temp.url))
        let bytes = fpsArchive(); var corrupt = bytes; corrupt[0] ^= 1
        cdn.serve("archive", data: corrupt)
        await #expect(throws: (any Error).self) {
            for try await _ in fpsInstaller(store, cdn).install(try fpsComponent(bytes)) { }
        }
        #expect(try store.installed().isEmpty)
    }
}

private func fpsArchive() -> Data {
    archiveTestData([ArchiveTestEntry("x86_64-windows/fpsstub.dll", body: "stub"),
        ArchiveTestEntry("x86_64-windows/fpsinject.exe", body: "injector"),
        ArchiveTestEntry("README.md", body: "docs")], format: .zip)
}
private func fpsComponent(_ bytes: Data) throws -> RuntimeComponent {
    var hash = StreamingHasher(.sha256); hash.update(bytes)
    return try RuntimeComponent(id: SafeIdentifier(GenshinFps.componentID), kind: .genshinFps,
        version: SafeIdentifier("1"), sourceMode: .download, url: URL(string: "https://fixtures.invalid/archive"),
        size: Int64(bytes.count), installedSize: 1024, sha256: hash.finalize(), archive: .zip,
        license: ComponentLicense(name: "GPL-3.0-only", url: URL(string: "https://fixtures.invalid/license")!,
            redistributable: true, termsRevision: "1"), rootPath: SafeRelativePath("x86_64-windows"))
}
private func fpsInstaller(_ store: RuntimeStore, _ cdn: MockCDN) -> ComponentInstaller {
    ComponentInstaller(store: store, consent: ConsentStore(url: store.paths.consent, root: store.paths.root),
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 4 << 30))
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_GENSHIN_FPS_BUILD"] != nil))
struct GenshinFpsBuiltArchiveTests {
    @Test(.timeLimit(.minutes(1))) func installsPinnedBuiltArchiveWithoutExecutingEitherBinary() async throws {
        let built = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_GENSHIN_FPS_BUILD"]))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let manifest = try RuntimeManifest.load(from: repository.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let component = try #require(manifest.components.first { $0.id.rawValue == GenshinFps.componentID })
        let buildFS = try ContainedFileSystem(root: built)
        let bytes = try buildFS.readFile(at: SafeRelativePath("genshin-fps-unlock-1.zip"), maxBytes: Int(try #require(component.size)))
        var hash = StreamingHasher(.sha256); hash.update(bytes)
        #expect(Int64(bytes.count) == component.size && hash.finalize() == component.sha256)
        let temp = try TempDir(), store = RuntimeStore(paths: AppPaths(root: temp.url)), cdn = MockCDN()
        cdn.serve(try #require(component.url).path, data: bytes)
        for try await _ in fpsInstaller(store, cdn).install(component) { }
        let fs = try ContainedFileSystem(root: store.installURL(for: component))
        for path in [GenshinFps.injectorPath, GenshinFps.stubPath] {
            let original = try buildFS.readFile(at: SafeRelativePath("x86_64-windows/\(path)"), maxBytes: 4 << 20)
            #expect(original.prefix(2) == Data("MZ".utf8))
            #expect(try fs.readFile(at: path, maxBytes: 4 << 20) == original)
        }
        // Only archive extraction runs. Neither PE file nor Wine is executed.
        try store.remove(try #require(store.installed().first))
        #expect(try store.installed().isEmpty)
    }
}
