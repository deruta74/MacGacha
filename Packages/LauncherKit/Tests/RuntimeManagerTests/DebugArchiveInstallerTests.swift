// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import TestSupport
@testable import RuntimeManager

@Suite struct DebugArchiveInstallerTests {
    @Test func matchingArchiveUsesLocalBytesOnlyInDebug() async throws {
        let f = try DebugArchiveFixture()
        try f.bytes.write(to: f.archive)
        for try await _ in f.installer.install(f.component) { }
        #expect(try f.store.installed().count == 1)
        #if DEBUG
        #expect(f.cdn.requestLog.isEmpty)
        #else
        #expect(f.cdn.requestLog.count == 1)
        #endif
    }

    #if DEBUG
    @Test(arguments: ["digest", "size"])
    func mismatchedLocalArchiveFailsWithoutNetworkFallback(mismatch: String) async throws {
        let f = try DebugArchiveFixture()
        let invalid = mismatch == "size" ? Data(f.bytes.dropLast()) : Data(repeating: 0, count: f.bytes.count)
        try invalid.write(to: f.archive)
        do {
            for try await _ in f.installer.install(f.component) { }
            Issue.record("Mismatched local archive was installed")
        } catch {
            #expect((error as? LauncherError)?.logCase == (mismatch == "size" ? "sizeMismatch" : "digestMismatch"))
        }
        #expect(f.cdn.requestLog.isEmpty)
        #expect(try f.store.installed().isEmpty)
    }

    @Test func stagingRelocationRetainsLocalArchiveSource() async throws {
        let f = try DebugArchiveFixture()
        try f.bytes.write(to: f.archive)
        let stage = RuntimeStore(paths: AppPaths(root: f.root.url.appendingPathComponent("stage")))
        for try await _ in f.installer.relocated(to: stage).install(f.component) { }
        #expect(try stage.installed().count == 1)
        #expect(try f.store.installed().isEmpty)
        #expect(f.cdn.requestLog.isEmpty)
    }
    #endif

    @Test(arguments: ["missing", "different-name", "directory"])
    func absentRegularArchiveUsesNormalDownload(source: String) async throws {
        let f = try DebugArchiveFixture()
        if source == "different-name" { try f.bytes.write(to: f.archive.deletingLastPathComponent().appendingPathComponent("other.zip")) }
        if source == "directory" { try FileManager.default.createDirectory(at: f.archive, withIntermediateDirectories: false) }
        for try await _ in f.installer.install(f.component) { }
        #expect(f.cdn.requestLog.count == 1)
        #expect(try f.store.installed().count == 1)
    }
}

private final class DebugArchiveFixture {
    let root: TempDir
    let archive: URL
    let bytes: Data
    let component: RuntimeComponent
    let cdn: MockCDN
    let store: RuntimeStore
    let installer: ComponentInstaller

    init() throws {
        root = try TempDir()
        let directory = root.url.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archive = directory.appendingPathComponent("surround.zip")
        bytes = archiveTestData([ArchiveTestEntry("x86_64-unix/winecoreaudio.so", body: "local audio module")], format: .zip)
        var hash = StreamingHasher(.sha256); hash.update(bytes)
        component = try RuntimeComponent(id: SafeIdentifier("surround-audio-test"), kind: .surroundAudio,
            version: SafeIdentifier("test"), sourceMode: .download, url: URL(string: "https://fixtures.invalid/surround.zip"),
            size: Int64(bytes.count), installedSize: 1024, sha256: hash.finalize(), archive: .zip,
            license: ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!, redistributable: true, termsRevision: "1"))
        cdn = MockCDN(); cdn.serve("surround.zip", data: bytes)
        let paths = AppPaths(root: root.url.appendingPathComponent("app"))
        store = RuntimeStore(paths: paths)
        installer = ComponentInstaller(store: store, consent: ConsentStore(url: paths.consent, root: paths.root),
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 4 << 30),
            debugArchiveDirectory: directory)
    }
}
