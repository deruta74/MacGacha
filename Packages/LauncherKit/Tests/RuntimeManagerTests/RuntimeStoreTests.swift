import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager
import TestSupport

@Test
func storeListsInstalledComponents() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let store = RuntimeStore(paths: paths)
    #expect(try store.installed().components.isEmpty)
    let wine = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(timeIntervalSince1970: 10), source: .download)
    let ninthWine = try InstalledComponent(kind: .wine, version: "9.0", installedAt: Date(timeIntervalSince1970: 1), source: .download)
    let earlierWine = try InstalledComponent(kind: .wine, version: "10.0", installedAt: Date(timeIntervalSince1970: 5), source: .download)
    let dxmt = try InstalledComponent(kind: .dxmt, version: "0.80", installedAt: Date(timeIntervalSince1970: 20), source: .download)
    try writeRuntimeMarker(wine, paths: paths)
    try writeRuntimeMarker(earlierWine, paths: paths)
    try writeRuntimeMarker(ninthWine, paths: paths)
    try writeRuntimeMarker(dxmt, paths: paths)
    #expect(try store.installed().components == [dxmt, ninthWine, earlierWine, wine])
    try store.remove(dxmt)
    #expect(try store.installed().components == [ninthWine, earlierWine, wine])
    try store.remove(dxmt)
}

@Test
func runtimeStoreUsesSafeLayoutAndRefusesSymlinks() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let paths = AppPaths(root: directory.url)
    let license = try ComponentLicense(name: "Test", url: URL(string: "https://example.test/license")!,
        redistributable: false, termsRevision: "r1")
    let component = try RuntimeComponent(id: SafeIdentifier("d3dmetal-3.0"), kind: .d3dmetal, version: SafeIdentifier("3.0"),
        sourceMode: .importFromGPTK, license: license, consent: .appleGPTK)
    let store = RuntimeStore(paths: paths)
    #expect(store.installURL(for: component).path == paths.runtimes.appendingPathComponent("d3dmetal/3.0").path)
    let record = try InstalledComponent(kind: .d3dmetal, version: "3.0", installedAt: Date(), source: .importFromGPTK)
    let control = outside.url.appendingPathComponent("keep")
    try Data("preserved".utf8).write(to: control)
    try FileManager.default.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: paths.runtimes.appendingPathComponent("d3dmetal"), withDestinationURL: outside.url)
    #expect(throws: LauncherError.unsafePath(paths.runtimes.appendingPathComponent("d3dmetal").path)) { try store.remove(record) }
    #expect(try Data(contentsOf: control) == Data("preserved".utf8))
}

@Test
func runtimeDiscoverySkipsMarkedInstallerStagingDirectories() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let valid = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    for name in [".incoming-\(UUID().uuidString)", ".hidden"] {
        let staged = paths.runtimes.appendingPathComponent("wine/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try JSONEncoder().encode(valid).write(to: staged.appendingPathComponent(".macgacha-component.json"))
    }
    #expect(try RuntimeStore(paths: paths).installed().components == [valid])
}

@Test
func runtimeStoreRefusesRedirectedRootForDeletionAndDiscovery() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let record = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(record, paths: AppPaths(root: outside.url))
    let control = outside.url.appendingPathComponent("Runtimes/wine/11.0/.macgacha-component.json")
    let original = try Data(contentsOf: control)
    let alias = directory.url.appendingPathComponent("redirected-root")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside.url)
    let store = RuntimeStore(paths: AppPaths(root: alias))
    do { _ = try store.installed().components; Issue.record("A redirected root must not be enumerated") }
    catch LauncherError.unsafePath {}
    do { try store.remove(record); Issue.record("A redirected root must not be deleted through") }
    catch LauncherError.unsafePath {}
    #expect(FileManager.default.fileExists(atPath: control.path))
    if FileManager.default.fileExists(atPath: control.path) { #expect(try Data(contentsOf: control) == original) }
}

@Test
func runtimeStoreRefusesAncestorSymlinksBelowRoot() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let record = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    let outsidePaths = AppPaths(root: outside.url)
    try writeRuntimeMarker(record, paths: outsidePaths)
    let control = outsidePaths.runtimes.appendingPathComponent("wine/11.0/.macgacha-component.json")
    let original = try Data(contentsOf: control)
    let paths = AppPaths(root: directory.url)
    try FileManager.default.createSymbolicLink(at: paths.runtimes, withDestinationURL: outsidePaths.runtimes)
    let store = RuntimeStore(paths: paths)
    do { _ = try store.installed().components; Issue.record("Discovery must refuse a symlink below the root") }
    catch LauncherError.unsafePath {}
    do { try store.remove(record); Issue.record("Removal must refuse a symlink below the root") }
    catch LauncherError.unsafePath {}
    #expect(try Data(contentsOf: control) == original)
}

@Test
func installedComponentDecodingKeepsPathInvariants() throws {
    let invalid: [String: Any] = ["kind": "wine", "version": "../escape", "installedAt": 0, "source": "download"]
    let data = try JSONSerialization.data(withJSONObject: invalid)
    #expect(throws: LauncherError.unsafePath("../escape")) { try JSONDecoder().decode(InstalledComponent.self, from: data) }
    #expect(throws: LauncherError.unsafePath("..")) { try InstalledComponent(kind: .wine, version: "..", installedAt: Date(), source: .download) }
}

@Test
func runtimeStoreDoesNotFollowMarkerSymlinks() throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let paths = AppPaths(root: directory.url)
    let record = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    let target = outside.url.appendingPathComponent("marker.json")
    try JSONEncoder().encode(record).write(to: target)
    let destination = paths.runtimes.appendingPathComponent("wine/11.0", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let marker = destination.appendingPathComponent(".macgacha-component.json")
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
    let result = try RuntimeStore(paths: paths).installed()
    #expect(result.components.isEmpty)
    #expect(result.invalid == ["Runtimes/wine/11.0"])
    #expect(try JSONDecoder().decode(InstalledComponent.self, from: Data(contentsOf: target)) == record)
}

@Test
func runtimeStoreReportsInvalidEntriesWithoutHidingValidComponents() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let valid = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    for (name, contents) in [("12.0", Data("broken".utf8)),
        ("13.0", try JSONEncoder().encode(valid)), ("bad\\name", try JSONEncoder().encode(valid)),
        ("bad name", try JSONEncoder().encode(valid)), ("\u{0301}bad", try JSONEncoder().encode(valid))] {
        let version = paths.runtimes.appendingPathComponent("wine/" + name)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try contents.write(to: version.appendingPathComponent(".macgacha-component.json"))
    }
    let result = try RuntimeStore(paths: paths).installed()
    #expect(result.components == [valid])
    #expect(result.invalid == ["Runtimes/wine/12.0", "Runtimes/wine/13.0", "Runtimes/wine/bad name",
        "Runtimes/wine/bad\\name", "Runtimes/wine/\u{0301}bad"].sorted())
}

@Test
func cancelledRuntimeRemovalNeverLeavesAnInstalledMarker() async throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let record = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(record, paths: paths)
    let store = RuntimeStore(paths: paths)
    let task = Task {
        try store.remove(record, deleting: { fs, path in
            withUnsafeCurrentTask { $0?.cancel() }
            try fs.removeItem(at: path)
        })
    }
    do { try await task.value; Issue.record("Deletion must observe cancellation") }
    catch LauncherError.cancelled {}
    #expect(try store.installed().components.isEmpty)
    let versions = try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("wine").path)
    #expect(versions.count == 1)
    #expect(versions.first?.hasPrefix(".removing-") == true)
    let staged = try #require(versions.first)
    let marker = paths.runtimes.appendingPathComponent("wine/" + staged + "/.macgacha-component.json")
    #expect(try JSONDecoder().decode(InstalledComponent.self, from: Data(contentsOf: marker)) == record)
}

private func writeRuntimeMarker(_ record: InstalledComponent, paths: AppPaths) throws {
    let destination = paths.runtimes.appendingPathComponent(record.kind.rawValue, isDirectory: true)
        .appendingPathComponent(record.version, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(".macgacha-component.json"), options: .atomic)
}
