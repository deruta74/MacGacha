import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport

@Test
func storeListsInstalledComponents() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let store = RuntimeStore(paths: paths)
    #expect(try store.installed().isEmpty)
    let wine = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(timeIntervalSince1970: 10), source: .download)
    let earlierWine = try InstalledComponent(kind: .wine, version: "10.0", installedAt: Date(timeIntervalSince1970: 5), source: .download)
    let dxmt = try InstalledComponent(kind: .dxmt, version: "0.80", installedAt: Date(timeIntervalSince1970: 20), source: .download)
    try writeRuntimeMarker(wine, paths: paths)
    try writeRuntimeMarker(earlierWine, paths: paths)
    try writeRuntimeMarker(dxmt, paths: paths)
    #expect(try store.installed() == [dxmt, earlierWine, wine])
    try store.remove(dxmt)
    #expect(try store.installed() == [earlierWine, wine])
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
func installedComponentDecodingKeepsPathInvariants() throws {
    let invalid: [String: Any] = ["kind": "wine", "version": "../escape", "installedAt": 0, "source": "download"]
    let data = try JSONSerialization.data(withJSONObject: invalid)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(InstalledComponent.self, from: data) }
    #expect(throws: (any Error).self) { try InstalledComponent(kind: .wine, version: "..", installedAt: Date(), source: .download) }
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
    do {
        _ = try RuntimeStore(paths: paths).installed()
        Issue.record("A marker symlink must be refused")
    } catch LauncherError.unsafePath {}
    #expect(try JSONDecoder().decode(InstalledComponent.self, from: Data(contentsOf: target)) == record)
}

@Test
func runtimeStoreRejectsMismatchedMarker() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let record = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    let destination = paths.runtimes.appendingPathComponent("wine/12.0", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(".macgacha-component.json"), options: .atomic)
    #expect(throws: (any Error).self) { try RuntimeStore(paths: paths).installed() }
}

private func writeRuntimeMarker(_ record: InstalledComponent, paths: AppPaths) throws {
    let destination = paths.runtimes.appendingPathComponent(record.kind.rawValue, isDirectory: true)
        .appendingPathComponent(record.version, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(".macgacha-component.json"), options: .atomic)
}
