// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Suite struct ModularD3DMetalTests {
    @Test func twoComponentD3DMetalAssemblesWineThenGraphics() async throws {
        let f = try await MetalFixture.make()
        #expect(try await f.manager.installed(f.bundle) == nil)
        let result = try await f.manager.install(f.bundle)
        for path in MetalFixture.files {
            #expect(try String(contentsOf: result.root.appendingPathComponent(path), encoding: .utf8) == "graphics")
        }
        #expect(try String(contentsOf: result.root.appendingPathComponent("bin/wine.real"), encoding: .utf8) == "wine")
        #expect(try String(contentsOf: result.root.appendingPathComponent("lib/core"), encoding: .utf8) == "wine")
        #expect(!FileManager.default.fileExists(atPath: result.root.appendingPathComponent("graphics-only-secret").path))
        #expect(result.root != f.store.installURL(for: f.manifest.components[0]))
        #expect(try await f.manager.installed(f.bundle)?.root == result.root)
    }

    @Test func missingGraphicsPathFails() async throws {
        let f = try await MetalFixture.make()
        try FileManager.default.removeItem(at: f.store.installURL(for: f.manifest.components[1]).appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"))
        await #expect(throws: (any Error).self) { try await f.manager.install(f.bundle) }
        #expect(try await f.manager.installed(f.bundle) == nil)
    }

    @Test func gptkImportReplacesOnlyFrameworkOnTwoComponentBundle() async throws {
        let f = try await MetalFixture.make(), source = try TempDir()
        let framework = source.url.appendingPathComponent("D3DMetal.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("import".utf8).write(to: framework.appendingPathComponent("D3DMetal"))
        let candidate = GPTKCandidate(root: source.url, d3dmetalFramework: framework, version: "1")
        let result = try await f.manager.install(f.bundle, from: candidate)
        #expect(result.source == .importFromGPTK)
        #expect(try String(contentsOf: result.root.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal"), encoding: .utf8) == "import")
        #expect(try String(contentsOf: result.root.appendingPathComponent("bin/wine"), encoding: .utf8) == "graphics")
        #expect(try String(contentsOf: result.root.appendingPathComponent("lib/core"), encoding: .utf8) == "wine")
    }

    @Test func removalOfTwoComponentBundleKeepsSharedComponents() async throws {
        let f = try await MetalFixture.make()
        let other = try RuntimeBundle(id: SafeIdentifier("other-metal"), displayName: "Other", backend: .d3dmetal, components: f.bundle.components)
        let manifest = try RuntimeManifest(components: f.manifest.components, bundles: [f.bundle, other])
        let manager = f.manager(for: manifest)
        _ = try await manager.install(f.bundle)
        try await manager.remove(f.bundle)
        #expect(try f.store.installed().count == 2)
        #expect(try await manager.installed(f.bundle) == nil)
    }
}

private final class MetalFixture {
    let temp: TempDir
    let manifest: RuntimeManifest
    let store: RuntimeStore
    let consent: ConsentStore
    let installer: ComponentInstaller
    init(temp: consuming TempDir, manifest: RuntimeManifest, store: RuntimeStore, consent: ConsentStore, installer: ComponentInstaller) {
        self.temp = temp; self.manifest = manifest; self.store = store; self.consent = consent; self.installer = installer
    }
    var bundle: RuntimeBundle { manifest.bundles[0] }
    var manager: RuntimeBundleManager { manager(for: manifest) }
    static let files = ["bin/wine", "lib/external/D3DMetal.framework/D3DMetal", "yaagl-d3dmetal-runtime.json"]
        + ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx", "amd_fidelityfx_framegeneration_dx12_native"].map { "lib/wine/x86_64-windows/\($0).dll" }
        + ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx", "nvngx"].map { "lib/wine/x86_64-unix/\($0).so" }
    func manager(for manifest: RuntimeManifest) -> RuntimeBundleManager {
        RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer,
            runner: FakeProcessRunner(), disk: FixedDiskSpace(bytes: 10 << 30))
    }
    static func make() async throws -> MetalFixture {
        let temp = try TempDir(), paths = AppPaths(root: temp.url)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: twoComponentMetalData())
        let store = RuntimeStore(paths: paths), consent = ConsentStore(url: paths.consent, root: temp.url)
        try await consent.accept(.appleGPTK, version: "1", termsRevision: "1")
        let fs = try ContainedFileSystem(root: temp.url)
        for (index, c) in manifest.components.enumerated() {
            let root = store.installURL(for: c)
            for name in index == 0 ? ["bin/wine", "bin/wine.real", "lib/core"] : files + ["graphics-only-secret"] {
                let path = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((index == 0 ? "wine" : "graphics").utf8).write(to: path)
            }
            try RuntimePublication.prepare(c, fs: fs, incoming: RuntimeJSONFile.relativePath(root, root: temp.url))
        }
        let installer = ComponentInstaller(store: store, consent: consent,
            fetcher: ChunkFetcher(http: MockCDN(), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()), extractor: ArchiveExtractor(runner: FakeProcessRunner()), disk: FixedDiskSpace(bytes: 10 << 30))
        return MetalFixture(temp: temp, manifest: manifest, store: store, consent: consent, installer: installer)
    }
}
