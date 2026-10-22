// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACGACHA_RUNTIME_FIXTURES"] != nil))
struct RuntimeBundleIntegrationTests {
    @Test(.timeLimit(.minutes(10)), arguments: ["dxmt", "d3dmetal"])
    func pinnedBundleCreatesD3D11Device(backend: String) async throws {
        let fixtures = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_RUNTIME_FIXTURES"]))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try RuntimeManifest.load(from: repository.appendingPathComponent("App/Resources/runtime-manifest.json"))
        let bundle = try #require(manifest.bundles.first { $0.backend.rawValue == backend })
        let temp = try TempDir(); let paths = AppPaths(root: temp.url)
        let store = RuntimeStore(paths: paths); let consent = ConsentStore(url: paths.consent, root: paths.root)
        for c in manifest.components where bundle.components.contains(c.id) && c.consent != nil {
            try await consent.accept(.appleGPTK, version: c.version.rawValue, termsRevision: c.license.termsRevision)
        }
        let runner = SystemProcessRunner()
        let installer = ComponentInstaller(store: store, consent: consent,
            fetcher: ChunkFetcher(http: RuntimeFixtureHTTP(root: fixtures), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            extractor: ArchiveExtractor(runner: runner), disk: SystemDiskSpaceProbe())
        let manager = RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer, runner: runner)
        let runtime = try await manager.install(bundle)
        let version = try await runner.run(runtime.wineBinary, arguments: ["--version"], environment: [:], currentDirectory: nil)
        #expect(version.exitCode == 0)
        print("\(backend) version: \(String(decoding: version.stdout, as: UTF8.self))")
        let prefix = try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "probe", bundle: runtime)
        let environment = ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree=d;mshtml=d"]
        let result = try await runner.run(runtime.wineBinary, arguments: [fixtures.appendingPathComponent("d3d11probe.exe").path],
            environment: environment, currentDirectory: nil)
        let output = String(decoding: result.stdout, as: UTF8.self)
        print("\(backend) probe: \(output) stderr: \(String(decoding: result.stderr.suffix(4096), as: UTF8.self))")
        #expect(result.exitCode == 0)
        let level = output.components(separatedBy: "feature_level=0x").dropFirst().first?
            .prefix { $0.isHexDigit }
        #expect(level.flatMap { UInt32($0, radix: 16) } ?? 0 >= 0xb000)
        if backend == "dxmt" { #expect(output.contains("Apple")) }
        if backend == "d3dmetal" {
            let candidateRoot = runtime.root.appendingPathComponent("lib/external")
            let candidate = GPTKCandidate(root: candidateRoot,
                d3dmetalFramework: candidateRoot.appendingPathComponent("D3DMetal.framework"), version: "4.0b3")
            let imported = try await manager.install(bundle, from: candidate)
            #expect(imported.source == .importFromGPTK)
            #expect(imported.root != runtime.root)
            #expect(imported.digest != runtime.digest)
            let importedPrefix = try await manager.createPrefix(game: "import-probe", bundle: bundle)
            let importedEnvironment = ["WINEPREFIX": importedPrefix.path, "WINEDEBUG": "-all",
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree=d;mshtml=d"]
            let importedResult = try await runner.run(imported.wineBinary, arguments: [fixtures.appendingPathComponent("d3d11probe.exe").path],
                environment: importedEnvironment, currentDirectory: nil)
            #expect(importedResult.exitCode == 0)
            #expect(String(decoding: importedResult.stdout, as: UTF8.self).contains("feature_level=0xb000"))
            _ = try await runner.run(imported.root.appendingPathComponent("bin/wineserver"), arguments: ["-k"],
                environment: importedEnvironment, currentDirectory: nil)
        }
        // Stop only this isolated prefix's wineserver before removing its files.
        _ = try await runner.run(runtime.root.appendingPathComponent("bin/wineserver"), arguments: ["-k"],
            environment: environment, currentDirectory: nil)
    }
}

/// Resolves the pinned remote basename to a local fixture; never creates a network session.
private struct RuntimeFixtureHTTP: HTTPClient {
    let root: URL
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: root)
            let path = try SafeRelativePath(url.lastPathComponent)
            let size = try #require(try fs.size(at: path))
            let handle = try fs.openForReading(at: path)
            try handle.seek(toOffset: UInt64(offset ?? 0))
            let reader = RuntimeFixtureReader(handle)
            return (HTTPResponseHead(status: offset == nil ? 200 : 206, contentLength: size - (offset ?? 0)),
                HTTPBody(next: { try await reader.next() }, onCancel: {}))
        }
    }
}

private actor RuntimeFixtureReader {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    deinit { try? handle.close() }
    func next() async throws -> Data? {
        let handle = handle
        return try await BlockingIO.run {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            return data.isEmpty ? nil : data
        }
    }
}
