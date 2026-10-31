// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_SURROUND_AUDIO_BUILD"] != nil))
struct SurroundAudioIntegrationTests {
    @Test(.timeLimit(.minutes(3))) func verifiesInstallsAndLoadsBuiltModuleWithoutWine() async throws {
        let built = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_SURROUND_AUDIO_BUILD"]))
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let manifest = try RuntimeManifest.load(from: repository.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let component = try #require(manifest.components.first { $0.id.rawValue == SurroundAudio.componentID })
        let buildFS = try ContainedFileSystem(root: built)
        let bytes = try buildFS.readFile(at: SafeRelativePath("surround-audio-wine-11.20-1.zip"),
            maxBytes: Int(try #require(component.size)))
        var hash = StreamingHasher(.sha256); hash.update(bytes)
        #expect(Int64(bytes.count) == component.size && hash.finalize() == component.sha256)
        let temp = try TempDir(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
        let cdn = MockCDN()
        cdn.serve(try #require(component.url).path, data: bytes)
        let installer = ComponentInstaller(store: store, consent: ConsentStore(url: paths.consent, root: paths.root),
            fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 4 << 30))
        for try await _ in installer.install(component) { }
        let installedFS = try ContainedFileSystem(root: store.installURL(for: component))
        let original = try buildFS.readFile(at: SurroundAudio.modulePath, maxBytes: 16 << 20)
        #expect(try installedFS.readFile(at: SurroundAudio.modulePath, maxBytes: 16 << 20) == original)
        // This script checks exports and dlopen with abort-only ntdll stubs.
        // It never loads ntdll or invokes a Wine entry point, game or audio device.
        let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", repository.appendingPathComponent("scripts/check-surround-audio.py").path, built.path],
            environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 0, "\(String(decoding: result.stdout + result.stderr, as: UTF8.self))")
        try store.remove(try #require(store.installed().first))
        #expect(try store.installed().isEmpty)
    }
}
