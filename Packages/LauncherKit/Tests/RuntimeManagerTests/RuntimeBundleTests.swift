// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport
import Launch

@Test func schemaTwoBundlesDecodeAndRejectOldSchema() throws {
    let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: bundleManifestData())
    #expect(manifest.schemaVersion == 2)
    #expect(throws: LauncherError.io("Unsupported runtime manifest schema")) {
        try JSONDecoder().decode(RuntimeManifest.self, from: Data(#"{"schemaVersion":1,"components":[]}"#.utf8))
    }
}

@Test(arguments: ["unknown", "backend", "rootPath", "wineBinary", "overlay", "consent"])
func bundleManifestRejectsInvalidLayoutAndReferences(attack: String) throws {
    let bytes = try bundleManifestData { object in
        var components = object["components"] as! [[String: Any]]
        var bundles = object["bundles"] as! [[String: Any]]
        switch attack {
        case "unknown": bundles[0]["components"] = ["missing"]
        case "backend": bundles[0]["backend"] = "d3dmetal"
        case "rootPath": components[0]["rootPath"] = "../wine"
        case "wineBinary": components[0]["wineBinary"] = "/bin/wine"
        case "overlay": components[1]["overlay"] = [["source": "x86_64-windows", "destination": "../lib"]]
        default: components[0]["consent"] = "appleGPTK"
        }
        object["components"] = components; object["bundles"] = bundles
    }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RuntimeManifest.self, from: bytes) }
}

func bundleManifestData(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object: [String: Any] = ["schemaVersion": 2, "components": [
        ["id": "wine-1", "kind": "wine", "version": "1", "rootPath": "wine", "wineBinary": "bin/wine"],
        ["id": "dxmt-1", "kind": "dxmt", "version": "1", "rootPath": "v1", "overlay": [["source": "x86_64-windows", "destination": "lib/wine/x86_64-windows"]]]
    ].map { fields -> [String: Any] in
        var c = fields as [String: Any]
        c.merge(["sourceMode": "download", "url": "https://fixtures.invalid/\(fields["id"]!)", "size": 100, "installedSize": 1000,
            "sha256": ["algorithm": "sha256", "hex": String(repeating: "a", count: 64)], "archive": "tar.gz",
            "license": ["name": "Fixture", "url": "https://fixtures.invalid/license", "redistributable": true, "termsRevision": "1"]]) { _, new in new }
        return c
    }, "bundles": [["id": "dxmt-test", "displayName": "DXMT", "backend": "dxmt", "components": ["wine-1", "dxmt-1"], "environment": [:]]]]
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

@Test(.timeLimit(.minutes(1))) func bundleAssemblyOverlaysRebuildsAndKeepsComponentsIndependent() async throws {
    let fixture = try BundleFixture()
    #expect(try await fixture.manager.installed(fixture.bundle) == nil)
    let first = try await fixture.manager.install(fixture.bundle)
    #expect(try Data(contentsOf: first.root.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")) == Data("dxmt".utf8))
    #expect(try Data(contentsOf: fixture.store.installURL(for: fixture.manifest.components[0]).appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")) == Data("stub".utf8))
    #expect(try await fixture.manager.installed(fixture.bundle)?.digest == first.digest)
    // A reinstall has a new publication identity even if the archive digest is unchanged.
    for try await _ in fixture.installer.install(fixture.manifest.components[1]) { }
    #expect(try await fixture.manager.installed(fixture.bundle) == nil)
    let next = try await fixture.manager.install(fixture.bundle)
    #expect(next.digest != first.digest)
    try await fixture.manager.remove(fixture.bundle)
    #expect(try await fixture.manager.installed(fixture.bundle) == nil)
    #expect(try fixture.store.installed().isEmpty)
}

@Test(.timeLimit(.minutes(1)), arguments: [ComponentInstaller.PublishPoint.beforePublish, .afterPublish])
func bundlePublicationFailureIsAtomicAndRetryable(point: ComponentInstaller.PublishPoint) async throws {
    let fixture = try BundleFixture()
    let manager = fixture.makeManager(failurePoint: { if $0 == point { throw LauncherError.io("assembly crash") } })
    await #expect(throws: LauncherError.io("assembly crash")) { try await manager.install(fixture.bundle) }
    #expect((try await fixture.manager.installed(fixture.bundle) != nil) == (point == .afterPublish))
    _ = try await fixture.manager.install(fixture.bundle)
    #expect(try await fixture.manager.installed(fixture.bundle) != nil)
}

@Test(.timeLimit(.minutes(1))) func bundleAssemblyHoldsStoreLeaseAndBudgetsCopyFallback() async throws {
    let fixture = try BundleFixture()
    for c in fixture.manifest.components { for try await _ in fixture.installer.install(c) { } }
    let manager = fixture.makeManager(disk: FixedDiskSpace(bytes: 0))
    await #expect(throws: (any Error).self) { try await manager.install(fixture.bundle) }
    #expect(try await fixture.manager.installed(fixture.bundle) == nil)
    let fs = try ContainedFileSystem(root: fixture.temp.url)
    let lock = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.lock"))
    await #expect(throws: LauncherError.busy("install root in use")) { try await fixture.manager.install(fixture.bundle) }
    withExtendedLifetime(lock) {}
}

@Test(.timeLimit(.minutes(1)), arguments: ["missing", "escaping"])
func selectedArchiveRootIsRequiredAndContained(attack: String) async throws {
    let fixture = try BundleFixture()
    let c = fixture.manifest.components[0]
    let entries = attack == "missing" ? [ArchiveTestEntry("other/file", body: "bad")] :
        [ArchiveTestEntry("wine/bin/wine", type: .symlink, link: "../../outside"), ArchiveTestEntry("outside", body: "bad")]
    let bytes = archiveTestData(entries, format: .tarGZ)
    let replacement = try bundleComponent(c, bytes: bytes)
    fixture.cdn.serve(c.id.rawValue, data: bytes)
    await #expect(throws: (any Error).self) { for try await _ in fixture.installer.install(replacement) { } }
    #expect(try fixture.store.installed().isEmpty)
}

final class BundleFixture {
    let temp: TempDir
    let manifest: RuntimeManifest
    let bundle: RuntimeBundle
    let cdn: MockCDN
    let store: RuntimeStore
    let consent: ConsentStore
    let installer: ComponentInstaller
    var manager: RuntimeBundleManager { makeManager() }
    init() throws {
        temp = try TempDir(); cdn = MockCDN()
        let shape = try JSONDecoder().decode(RuntimeManifest.self, from: bundleManifestData())
        let wine = archiveTestData([ArchiveTestEntry("wine/bin/wine", body: "wine"), ArchiveTestEntry("wine/lib/wine/x86_64-windows/d3d11.dll", body: "stub"), ArchiveTestEntry("ignored", body: "ignore")], format: .tarGZ)
        let dxmt = archiveTestData([ArchiveTestEntry("v1/x86_64-windows/d3d11.dll", body: "dxmt")], format: .tarGZ)
        let components = try zip(shape.components, [wine, dxmt]).map { try bundleComponent($0, bytes: $1) }
        manifest = try RuntimeManifest(components: components, bundles: shape.bundles); bundle = shape.bundles[0]
        cdn.serve("wine-1", data: wine); cdn.serve("dxmt-1", data: dxmt)
        let paths = AppPaths(root: temp.url); store = RuntimeStore(paths: paths)
        consent = ConsentStore(url: paths.consent, root: temp.url)
        installer = ComponentInstaller(store: store, consent: consent, fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
            extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 10 << 30))
    }
    func makeManager(disk: any DiskSpaceProbe = FixedDiskSpace(bytes: 10 << 30),
        failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void = { _ in }) -> RuntimeBundleManager {
        RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer,
            runner: SystemProcessRunner(), disk: disk, failurePoint: failurePoint)
    }
}

func bundleComponent(_ c: RuntimeComponent, bytes: Data) throws -> RuntimeComponent {
    var hash = StreamingHasher(.sha256); hash.update(bytes)
    return try RuntimeComponent(id: c.id, kind: c.kind, version: c.version, sourceMode: c.sourceMode,
        url: c.url, size: Int64(bytes.count), installedSize: c.installedSize, sha256: hash.finalize(), archive: c.archive,
        license: c.license, consent: c.consent, rootPath: c.rootPath, wineBinary: c.wineBinary, overlay: c.overlay)
}

@Test(.timeLimit(.minutes(1))) func bundlePrefixUsesBundleIdentityWin10AndUpgradesInPlace() async throws {
    let fixture = try BundleFixture()
    let runtime = try await fixture.manager.install(fixture.bundle)
    let runner = FakeProcessRunner()
    let prefixes = PrefixManager(paths: AppPaths(root: fixture.temp.url), runner: runner, inspector: IdlePrefixInspector())
    let url = try await prefixes.createPrefix(game: "genshin", bundle: runtime)
    #expect(url == (try prefixes.prefixURL(game: "genshin", bundle: runtime.id)))
    #expect(url.lastPathComponent == "genshin-dxmt-test")
    #expect(runner.invocations.map(\.arguments) == [["wineboot", "--init"], ["winecfg", "-v", "win10"]])
    #expect(runner.invocations.allSatisfy { $0.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;mscoree=d;mshtml=d" })
    try Data("save".utf8).write(to: url.appendingPathComponent("save"))
    _ = try await prefixes.createPrefix(game: "genshin", bundle: runtime)
    #expect(runner.invocations.count == 2)
    for try await _ in fixture.installer.install(fixture.manifest.components[1]) { }
    let changed = try await fixture.manager.install(fixture.bundle)
    _ = try await prefixes.createPrefix(game: "genshin", bundle: changed)
    #expect(runner.invocations.map(\.arguments).suffix(2) == [["wineboot", "-u"], ["winecfg", "-v", "win10"]])
    #expect(try Data(contentsOf: url.appendingPathComponent("save")) == Data("save".utf8))
    let marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent(".macgacha-prefix.json"))) as? [String: Any])
    #expect(marker["bundleID"] as? String == runtime.id.rawValue)
    #expect((marker["runtimeDigest"] as? [String: String])?["hex"] == changed.digest.hex)
}

@Test(.timeLimit(.minutes(1))) func bundleMetalConsentAndSignatureFailurePreventPublication() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let cdn = MockCDN(); let consent = ConsentStore(url: paths.consent, root: paths.root)
    let bytes = archiveTestData([ArchiveTestEntry("wine/bin/wine", body: "wine"),
        ArchiveTestEntry("wine/lib/external/D3DMetal.framework/D3DMetal", body: "unsigned")], format: .tarGZ)
    var hash = StreamingHasher(.sha256); hash.update(bytes)
    let c = try RuntimeComponent(id: SafeIdentifier("d3dmetal-1"), kind: .d3dmetal, version: SafeIdentifier("1"), sourceMode: .download,
        url: URL(string: "https://fixtures.invalid/metal")!, size: Int64(bytes.count), installedSize: 1000, sha256: hash.finalize(), archive: .tarGZ,
        license: ComponentLicense(name: "Apple", url: AppleNotice.termsURL, redistributable: false, termsRevision: "pinned"),
        consent: .appleGPTK, rootPath: SafeRelativePath("wine"), wineBinary: SafeRelativePath("bin/wine"))
    let bundle = try RuntimeBundle(id: SafeIdentifier("metal-test"), displayName: "D3DMetal", backend: .d3dmetal, components: [c.id])
    let manifest = try RuntimeManifest(components: [c], bundles: [bundle])
    let installer = ComponentInstaller(store: store, consent: consent,
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 10 << 30))
    let manager = RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer)
    await #expect(throws: LauncherError.consentRequired(c.id.rawValue)) { try await manager.install(bundle) }
    #expect(cdn.requestLog.isEmpty)
    try await consent.accept(.appleGPTK, version: "1", termsRevision: "pinned")
    cdn.serve("metal", data: bytes)
    await #expect(throws: LauncherError.io("D3DMetal signature verification failed")) { try await manager.install(bundle) }
    #expect(try store.installed().isEmpty)
    #expect(try await manager.installed(bundle) == nil)
}

@Test(.timeLimit(.minutes(1))) func componentRemovalCannotRaceBundlePublication() async throws {
    let fixture = try BundleFixture()
    for c in fixture.manifest.components { for try await _ in fixture.installer.install(c) { } }
    let installed = try #require(fixture.store.installed().first)
    let store = fixture.store
    let manager = fixture.makeManager(failurePoint: { point in
        if point == .beforePublish {
            #expect(throws: LauncherError.busy("install root in use")) { try store.remove(installed) }
        }
    })
    _ = try await manager.install(fixture.bundle)
    #expect(try await manager.installed(fixture.bundle) != nil)
}

@Test(.timeLimit(.minutes(1))) func bundlePrefixLeaseProtectsComponentsDuringWineboot() async throws {
    let fixture = try BundleFixture()
    _ = try await fixture.manager.install(fixture.bundle)
    let store = fixture.store
    let installed = try #require(store.installed().first)
    let runner = FakeProcessRunner { _ in
        #expect(throws: LauncherError.busy("install root in use")) { try store.remove(installed) }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
    let manager = RuntimeBundleManager(manifest: fixture.manifest, store: store, consent: fixture.consent,
        installer: fixture.installer, runner: runner)
    _ = try await manager.createPrefix(game: "protected", bundle: fixture.bundle)
    #expect(runner.invocations.count == 2)
}

@Test(.timeLimit(.minutes(1))) func blockedBundlePublicationDoesNotStarveCancellation() async throws {
    let fixture = try BundleFixture()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    let manager = fixture.makeManager(failurePoint: { point in
        if point == .beforePublish {
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
    })
    let bundle = fixture.bundle
    let worker = Task { try await manager.install(bundle) }
    defer { worker.cancel(); release.signal() }
    for await _ in entered.stream { break }
    worker.cancel(); release.signal()
    await #expect(throws: LauncherError.cancelled) { try await worker.value }
    #expect(try await fixture.manager.installed(bundle) == nil)
    _ = try await fixture.manager.install(bundle)
}

@Test(arguments: ["w*", "w?", "w[ine]", "w]ine"])
func rootedArchiveRejectsPatternRoots(root: String) async throws {
    let temp = try TempDir()
    let fs = try ContainedFileSystem(root: temp.url)
    let bytes = archiveTestData([ArchiveTestEntry("\(root)/bin/wine", body: "wine"),
        ArchiveTestEntry("wrong/bin/extra", body: "foreign")], format: .tarGZ)
    try bytes.write(to: temp.url.appendingPathComponent("archive"))
    await #expect(throws: (any Error).self) {
        try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive: SafeRelativePath("archive"),
            archiveFS: fs, archiveURL: temp.url.appendingPathComponent("archive"), format: .tarGZ,
            fs: fs, target: SafeRelativePath("out"), expandedLimit: 1000, rootPath: SafeRelativePath(root))
    }
    #expect(try fs.itemType(at: SafeRelativePath("out")) == nil)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(RuntimeManifest.self, from: bundleManifestData { object in
            var components = object["components"] as! [[String: Any]]
            components[0]["rootPath"] = root; object["components"] = components
        })
    }
}

@Test(arguments: [false, true])
func rootedArchiveNormalizesMembersAndHardlinkTargets(hardlink: Bool) async throws {
    let temp = try TempDir(); let fs = try ContainedFileSystem(root: temp.url)
    var entries = [ArchiveTestEntry("./", type: .directory),
        ArchiveTestEntry("././wine/", type: .directory),
        ArchiveTestEntry("./wine/bin/wine", body: "wine"),
        ArchiveTestEntry("wine/bin/plain", body: "plain"),
        ArchiveTestEntry("././wine/literal*file", body: "literal"),
        ArchiveTestEntry("wine-other/extra", body: "excluded")]
    if hardlink { entries.append(ArchiveTestEntry("././wine/bin/linked", type: .hardlink, link: "././wine/bin/wine")) }
    try archiveTestData(entries, format: .tarGZ).write(to: temp.url.appendingPathComponent("archive"))
    try await ArchiveExtractor(runner: SystemProcessRunner()).extract(archive: SafeRelativePath("archive"),
        archiveFS: fs, archiveURL: temp.url.appendingPathComponent("archive"), format: .tarGZ,
        fs: fs, target: SafeRelativePath("out"), expandedLimit: 1000, rootPath: SafeRelativePath("wine"))
    #expect(try fs.readFile(at: SafeRelativePath("out/bin/wine"), maxBytes: 10) == Data("wine".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("out/bin/plain"), maxBytes: 10) == Data("plain".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("out/literal*file"), maxBytes: 10) == Data("literal".utf8))
    #expect(try fs.itemType(at: SafeRelativePath("out/wine")) == nil)
    #expect(try fs.itemType(at: SafeRelativePath("out/wine-other")) == nil)
    if hardlink { #expect(try fs.readFile(at: SafeRelativePath("out/bin/linked"), maxBytes: 10) == Data("wine".utf8)) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func pinnedComponentCannotBeRemoved(bundleRemoval: Bool) async throws {
    try await BlockingIO.run {
        let f = try BundleFixture()
        let installedBundle = try await f.manager.install(f.bundle)
        let component = try #require(f.store.installed().first { $0.kind == .dxmt })
        let pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ["dxmt-1"])
        defer { withExtendedLifetime(pin) {} }
        if bundleRemoval {
            await #expect(throws: LauncherError.busy("install root in use")) { try await f.manager.remove(f.bundle) }
        } else {
            #expect(throws: LauncherError.busy("install root in use")) { try f.store.remove(component) }
        }
        #expect(try f.store.installed().count == 2)
        #expect(try await f.manager.installed(f.bundle)?.digest == installedBundle.digest)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func unpinnedComponentRemoves(bundleRemoval: Bool) async throws {
    try await BlockingIO.run {
        let f = try BundleFixture()
        _ = try await f.manager.install(f.bundle)
        do {
            let pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ["wine-1", "dxmt-1"])
            withExtendedLifetime(pin) {}
        }
        if bundleRemoval { try await f.manager.remove(f.bundle) }
        else { try f.store.remove(#require(f.store.installed().first { $0.kind == .dxmt })) }
        #expect(try !f.store.installed().contains { $0.kind == .dxmt })
    }
}

@Test(.timeLimit(.minutes(1)))
func removalExclusionIsHeldUntilDeletionCompletes() async throws {
    try await BlockingIO.run {
        let f = try BundleFixture()
        _ = try await f.manager.install(f.bundle)
        let component = try #require(f.store.installed().first { $0.kind == .dxmt })
        try f.store.remove(component, deleting: { fs, path in
            #expect(throws: LauncherError.busy("install root in use")) {
                try RuntimePin.pin(paths: f.store.paths, componentIDs: ["dxmt-1"])
            }
            try fs.removeItem(at: path)
        })
        let pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ["dxmt-1"])
        withExtendedLifetime(pin) {}
    }
}

@Test(.timeLimit(.minutes(1)))
func pinnedComponentWithDamagedMetadataCannotBeRemovedAsInvalid() async throws {
    try await BlockingIO.run {
        let f = try BundleFixture()
        _ = try await f.manager.install(f.bundle)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        try fs.writeAtomically(Data("corrupt".utf8), to: SafeRelativePath("Runtimes/dxmt/1/.macgacha-component.json"))
        let invalid = try #require(f.store.scan().invalid.first { $0.kind == .dxmt && $0.rawName == "1" })
        let pin = try RuntimePin.pin(paths: f.store.paths, componentIDs: ["dxmt-1"])
        defer { withExtendedLifetime(pin) {} }
        #expect(throws: LauncherError.busy("install root in use")) { try f.store.removeInvalid(invalid) }
        #expect(try fs.itemType(at: SafeRelativePath("Runtimes/dxmt/1")) == .directory)
    }
}
