// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
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
    #expect(try store.installed().isEmpty)
    let wine = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(timeIntervalSince1970: 10), source: .download)
    let ninthWine = try InstalledComponent(kind: .wine, version: "9.0", installedAt: Date(timeIntervalSince1970: 1), source: .download)
    let earlierWine = try InstalledComponent(kind: .wine, version: "10.0", installedAt: Date(timeIntervalSince1970: 5), source: .download)
    let dxmt = try InstalledComponent(kind: .dxmt, version: "0.80", installedAt: Date(timeIntervalSince1970: 20), source: .download)
    try writeRuntimeMarker(wine, paths: paths)
    try writeRuntimeMarker(earlierWine, paths: paths)
    try writeRuntimeMarker(ninthWine, paths: paths)
    try writeRuntimeMarker(dxmt, paths: paths)
    #expect(try store.installed() == [dxmt, ninthWine, earlierWine, wine])
    try store.remove(dxmt)
    #expect(try store.installed() == [ninthWine, earlierWine, wine])
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
    #expect(try RuntimeStore(paths: paths).installed() == [valid])
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
    do { _ = try store.installed(); Issue.record("A redirected root must not be enumerated") }
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
    do { _ = try store.installed(); Issue.record("Discovery must refuse a symlink below the root") }
    catch LauncherError.unsafePath {}
    do { try store.remove(record); Issue.record("Removal must refuse a symlink below the root") }
    catch LauncherError.unsafePath {}
    do { try store.sweepStaging(); Issue.record("Sweep must refuse a symlink at Runtimes") }
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
    let result = try RuntimeStore(paths: paths).scan()
    #expect(result.components.isEmpty)
    #expect(result.invalid.map(\.rawName) == ["11.0"])
    #expect(result.invalid.allSatisfy { $0.kind == .wine && !$0.reason.isEmpty })
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
    let result = try RuntimeStore(paths: paths).scan()
    #expect(result.components == [valid])
    #expect(result.invalid.map(\.rawName).sorted() == ["12.0", "13.0", "bad name", "bad\\name", "\u{0301}bad"].sorted())
    #expect(result.invalid.allSatisfy { $0.kind == .wine && !$0.reason.isEmpty })
    let removable = result.invalid.filter { $0.rawName == "12.0" || $0.rawName == "13.0" || $0.rawName == "bad name" }
    let store = RuntimeStore(paths: paths)
    for entry in removable { try store.removeInvalid(entry) }
    #expect(try store.installed() == [valid])
    for entry in result.invalid where !removable.contains(entry) {
        #expect(throws: LauncherError.unsafePath(entry.rawName)) { try store.removeInvalid(entry) }
    }
    #expect(try store.scan().invalid.count == 2)
    let repaired = try InstalledComponent(kind: .wine, version: "12.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(repaired, paths: paths)
    let oldEntry = try #require(removable.first { $0.rawName == "12.0" })
    try store.removeInvalid(oldEntry)
    #expect(try store.installed() == [valid, repaired])
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
    #expect(try store.installed().isEmpty)
    let versions = try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("wine").path)
    #expect(versions.count == 1)
    #expect(versions.first?.hasPrefix(".removing-") == true)
    let staged = try #require(versions.first)
    let marker = paths.runtimes.appendingPathComponent("wine/" + staged + "/.macgacha-component.json")
    #expect(try JSONDecoder().decode(InstalledComponent.self, from: Data(contentsOf: marker)) == record)
    try store.sweepStaging()
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("wine").path).isEmpty)
    #expect(try store.installed().isEmpty)
}

@Test(arguments: ["file", "symlink", "fifo"])
func invalidKindEntryDoesNotHideOtherKinds(shape: String) throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let paths = AppPaths(root: directory.url)
    let valid = try InstalledComponent(kind: .dxmt, version: "0.80", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    let control = outside.url.appendingPathComponent("control")
    let original = Data("preserved".utf8)
    try original.write(to: control)
    let invalid = paths.runtimes.appendingPathComponent("wine")
    if shape == "symlink" { try FileManager.default.createSymbolicLink(at: invalid, withDestinationURL: outside.url) }
    else if shape == "fifo" { try #require(invalid.path.withCString { mkfifo($0, 0o600) } == 0) }
    else { try original.write(to: invalid) }
    let result = try RuntimeStore(paths: paths).scan()
    #expect(result.components == [valid])
    let entry = try #require(result.invalid.count == 1 ? result.invalid.first : nil)
    #expect(entry.kind == nil)
    #expect(entry.rawName == "wine")
    #expect(!entry.reason.isEmpty)
    #expect(entry.removable)
    let store = RuntimeStore(paths: paths)
    let pending = paths.runtimes.appendingPathComponent("dxmt/.incoming-stale", isDirectory: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    try store.sweepStaging()
    #expect(!FileManager.default.fileExists(atPath: pending.path))
    try store.removeInvalid(entry)
    #expect(try store.installed() == [valid])
    #expect(try store.scan().invalid.isEmpty)
    #expect(try Data(contentsOf: control) == original)
}

@Test
func sweepStagingIsResumableAndLeavesOtherEntriesAlone() async throws {
    let directory = try TempDir()
    let outside = try TempDir()
    let paths = AppPaths(root: directory.url)
    let fs = try ContainedFileSystem(root: directory.url)
    let store = RuntimeStore(paths: paths)
    let valid = try InstalledComponent(kind: .dxmt, version: "1.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    let stale = ["Runtimes/wine/.incoming-old", "Runtimes/dxmt/.removing-old", "Runtimes/.removing-kind"]
    for name in stale { try fs.writeAtomically(Data("partial".utf8), to: SafeRelativePath(name + "/partial")) }
    try fs.writeAtomically(Data("keep".utf8), to: SafeRelativePath("Runtimes/wine/.other/control"))
    try fs.writeAtomically(Data("keep".utf8), to: SafeRelativePath("Runtimes/wine/.incoming-file"))
    try Data("outside".utf8).write(to: outside.url.appendingPathComponent("control"))
    try FileManager.default.createSymbolicLink(at: paths.runtimes.appendingPathComponent("wine/.incoming-link"), withDestinationURL: outside.url)
    let cancelled = Task {
        try store.sweepStaging(deleting: { fs, path in
            withUnsafeCurrentTask { $0?.cancel() }
            try fs.removeItem(at: path)
        })
    }
    do { try await cancelled.value; Issue.record("Staging sweep must propagate cancellation") }
    catch LauncherError.cancelled {}
    try store.sweepStaging()
    try store.sweepStaging()
    for name in stale { #expect(try fs.itemType(at: SafeRelativePath(name)) == nil) }
    #expect(try store.installed() == [valid])
    #expect(try fs.readFile(at: SafeRelativePath("Runtimes/wine/.other/control"), maxBytes: 4) == Data("keep".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("Runtimes/wine/.incoming-file"), maxBytes: 4) == Data("keep".utf8))
    #expect(try Data(contentsOf: outside.url.appendingPathComponent("control")) == Data("outside".utf8))
}

@Test
func runtimeScanPropagatesCancellationWithInvalidKinds() async throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let valid = try InstalledComponent(kind: .dxmt, version: "1.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    try Data("invalid kind".utf8).write(to: paths.runtimes.appendingPathComponent("wine"))
    let store = RuntimeStore(paths: paths)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try store.scan()
    }
    do { _ = try await cancelled.value; Issue.record("Scanning must propagate cancellation") }
    catch LauncherError.cancelled {}
}

@Test
func removeInvalidRejectsMultiComponentNamesWithoutTouchingFiles() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let store = RuntimeStore(paths: paths)
    let fs = try ContainedFileSystem(root: directory.url)
    try fs.writeAtomically(Data("preserved".utf8), to: SafeRelativePath("Runtimes/wine/control"))
    for rawName in ["../wine", "wine/control", ".", "..", "bad\\name", "/absolute", "nul\0name"] {
        let entry = InvalidRuntimeEntry(kind: nil, rawName: rawName, reason: "Test invalid entry")
        #expect(throws: LauncherError.unsafePath(rawName)) { try store.removeInvalid(entry) }
    }
    #expect(try fs.readFile(at: SafeRelativePath("Runtimes/wine/control"), maxBytes: 100) == Data("preserved".utf8))
}

@Test
func kindInspectionFailureCannotAuthorizeRemoval() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let store = RuntimeStore(paths: paths)
    let valid = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    let wine = paths.runtimes.appendingPathComponent("wine")
    let marker = wine.appendingPathComponent("11.0/.macgacha-component.json")
    let original = try Data(contentsOf: marker)
    for index in 0..<1024 {
        try FileManager.default.createDirectory(at: wine.appendingPathComponent(".incoming-\(index)"), withIntermediateDirectories: true)
    }
    let scan = try store.scan()
    let entry = try #require(scan.invalid.first { $0.kind == nil && $0.rawName == "wine" })
    #expect(entry.reason == "Too many runtime directory entries")
    #expect(!entry.removable)
    #expect(throws: LauncherError.io("Runtime entry is report-only")) { try store.removeInvalid(entry) }
    let forged = InvalidRuntimeEntry(kind: nil, rawName: "wine", reason: entry.reason, removable: true)
    #expect(throws: LauncherError.io("Runtime entry is report-only")) { try store.removeInvalid(forged) }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    if FileManager.default.fileExists(atPath: marker.path) { #expect(try Data(contentsOf: marker) == original) }
}

@Test
func unknownRuntimeKindsAreReportOnlyAndNeverSwept() throws {
    let directory = try TempDir()
    let paths = AppPaths(root: directory.url)
    let fs = try ContainedFileSystem(root: directory.url)
    let store = RuntimeStore(paths: paths)
    let valid = try InstalledComponent(kind: .wine, version: "11.0", installedAt: Date(), source: .download)
    try writeRuntimeMarker(valid, paths: paths)
    let controls = ["Runtimes/unknown-dir/.incoming-test/control", "Runtimes/unknown-dir/.removing-test/control",
        "Runtimes/unknown-file", "Runtimes/.hidden-kind/control"]
    let original = Data("preserved".utf8)
    for path in controls { try fs.writeAtomically(original, to: SafeRelativePath(path)) }
    try fs.createDirectory(at: SafeRelativePath("Runtimes/wine/.incoming-stale"))
    let result = try store.scan()
    #expect(result.components == [valid])
    #expect(result.invalid.map(\.rawName) == ["unknown-dir", "unknown-file"])
    #expect(result.invalid.allSatisfy { $0.kind == nil && !$0.removable && $0.reason == "Unknown runtime kind" })
    for entry in result.invalid {
        #expect(throws: LauncherError.io("Runtime entry is report-only")) { try store.removeInvalid(entry) }
    }
    try store.sweepStaging()
    #expect(try fs.itemType(at: SafeRelativePath("Runtimes/wine/.incoming-stale")) == nil)
    for path in controls { #expect(try fs.readFile(at: SafeRelativePath(path), maxBytes: 100) == original) }
    #expect(try store.installed() == [valid])
    #expect(try store.scan().invalid == result.invalid)
}

private func writeRuntimeMarker(_ record: InstalledComponent, paths: AppPaths) throws {
    let destination = paths.runtimes.appendingPathComponent(record.kind.rawValue, isDirectory: true)
        .appendingPathComponent(record.version, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(".macgacha-component.json"), options: .atomic)
}
