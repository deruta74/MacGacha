// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
@testable import RuntimeManager
import TestSupport

@Test
func gptkLocateFindsFrameworkAndNearestVersion() throws {
    let temp = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("Vol/GPTK/redist/lib/external"))
    try gptkPlist("2.0").write(to: temp.url.appendingPathComponent("Vol/Info.plist"))
    let importer = GPTKImporter(searchRoots: [temp.url.appendingPathComponent("Vol")])
    #expect(try importer.locate() == [candidate])
    try FileManager.default.removeItem(at: candidate.d3dmetalFramework.appendingPathComponent("Info.plist"))
    #expect(try importer.locate().first?.version == "2.0")
}

@Test
func gptkLocateHonorsDepthAndDoesNotFollowSymlinkLoops() throws {
    let temp = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("GPTK/external"))
    try FileManager.default.createSymbolicLink(atPath: temp.url.appendingPathComponent("loop").path, withDestinationPath: temp.url.path)
    try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("fake"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: temp.url.appendingPathComponent("fake/D3DMetal.framework").path,
        withDestinationPath: candidate.d3dmetalFramework.path)
    #expect(try GPTKImporter(searchRoots: [temp.url], maxDepth: 2).locate().isEmpty)
    #expect(try GPTKImporter(searchRoots: [temp.url], maxDepth: 3).locate() == [candidate])
    #expect(try GPTKImporter(searchRoots: [temp.url.appendingPathComponent("loop")]).locate().isEmpty)
}

@Test
func gptkLocateBoundsHugeTreesAndToleratesMissingRoots() throws {
    let temp = try TempDir(); let laterRoot = try TempDir()
    for index in 0..<32 { try Data().write(to: temp.url.appendingPathComponent("entry-\(index)")) }
    let candidate = try gptkFixture(in: laterRoot.url.appendingPathComponent("external"))
    let roots = [temp.url.appendingPathComponent("missing"), temp.url, laterRoot.url]
    #expect(try GPTKImporter(searchRoots: roots, maxEntries: 8).locate().isEmpty)
    #expect(try GPTKImporter(searchRoots: roots).locate() == [candidate])
    #expect(GPTKImporter.searchEntryLimit == 100_000)
}

@Test(arguments: [2, 8])
func gptkVersionEnumerationHonorsSharedBudget(budget: Int) throws {
    let temp = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("external"))
    try FileManager.default.removeItem(at: candidate.d3dmetalFramework.appendingPathComponent("Info.plist"))
    let versions = candidate.d3dmetalFramework.appendingPathComponent("Versions")
    try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
    for index in 0..<256 { try Data().write(to: versions.appendingPathComponent("entry-\(index)")) }
    let entriesRead = Mutex(0)
    let importer = GPTKImporter(searchRoots: [candidate.d3dmetalFramework], maxDepth: 0, maxEntries: budget,
        readDirectoryEntry: { stream in
            guard let item = readdir(stream) else { return nil }
            let raw = withUnsafeBytes(of: item.pointee.d_name) { Array($0.prefix { $0 != 0 }) }
            if raw != [46] && raw != [46, 46] { entriesRead.withLock { $0 += 1 } }
            return item
        })
    let result = try importer.locate()
    #expect(result.count == 1 && result.first?.version == nil)
    // The search root consumes one slot; Versions must stop after the remaining slots.
    // Count actual readdir results rather than only the entries retained after listing.
    #expect(entriesRead.withLock { $0 } == budget - 1)
}

@Test
func gptkLocateReadsVersionedFrameworkPlistWithoutFollowingCurrentLink() throws {
    let temp = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("external"))
    let resources = candidate.d3dmetalFramework.appendingPathComponent("Versions/A/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: candidate.d3dmetalFramework.appendingPathComponent("Info.plist"),
        to: resources.appendingPathComponent("Info.plist"))
    try FileManager.default.createSymbolicLink(atPath: candidate.d3dmetalFramework.appendingPathComponent("Versions/Current").path,
        withDestinationPath: "A")
    try FileManager.default.createSymbolicLink(atPath: candidate.d3dmetalFramework.appendingPathComponent("Resources").path,
        withDestinationPath: "Versions/Current/Resources")
    #expect(try GPTKImporter(searchRoots: [temp.url]).locate().first?.version == "3.0")
}

@Test
func gptkLocateDoesNotReadSymlinkedPlists() throws {
    let temp = try TempDir(); let outside = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("external"))
    let plist = candidate.d3dmetalFramework.appendingPathComponent("Info.plist")
    try FileManager.default.removeItem(at: plist)
    try gptkPlist("secret").write(to: outside.url.appendingPathComponent("Info.plist"))
    try FileManager.default.createSymbolicLink(atPath: plist.path, withDestinationPath: outside.url.appendingPathComponent("Info.plist").path)
    #expect(try GPTKImporter(searchRoots: [temp.url]).locate().first?.version == nil)
}

@Test
func gptkImportRequiresConsentThenInstallsWithoutNetwork() async throws {
    let temp = try TempDir(); let source = try TempDir(); let cdn = MockCDN()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let component = try gptkComponent(); let paths = AppPaths(root: temp.url)
    let store = RuntimeStore(paths: paths); let consent = ConsentStore(url: paths.consent, root: paths.root)
    let installer = gptkInstaller(store: store, consent: consent, cdn: cdn)
    await #expect(throws: LauncherError.consentRequired(component.id.rawValue)) {
        // Consent must win even over a nonexistent source, before creating Runtimes.
        let missing = GPTKCandidate(root: source.url.appendingPathComponent("missing"),
            d3dmetalFramework: source.url.appendingPathComponent("missing/D3DMetal.framework"), version: nil)
        for try await _ in installer.install(component, from: missing) { }
    }
    #expect(!FileManager.default.fileExists(atPath: paths.runtimes.path))
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "old")
    await #expect(throws: LauncherError.consentRequired(component.id.rawValue)) {
        for try await _ in installer.install(component, from: candidate) { }
    }
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    var completed = 0
    for try await event in installer.install(component, from: candidate) {
        if event == .phase(.completed) {
            completed += 1
            #expect(try store.installed().first?.source == .importFromGPTK)
        }
    }
    #expect(completed == 1)
    #expect(cdn.requestLog.isEmpty)
    let destination = store.installURL(for: component)
    #expect(try String(contentsOf: destination.appendingPathComponent("D3DMetal.framework/D3DMetal"), encoding: .utf8) == "metal")
    #expect(try String(contentsOf: destination.appendingPathComponent("companion"), encoding: .utf8) == "helper")
    let entries = try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("d3dmetal").path)
    #expect(entries == ["3.0"])
}

@Test
func gptkImporterConvenienceUsesManifestConsentRevision() async throws {
    let temp = try TempDir(); let source = try TempDir()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root); let component = try gptkComponent()
    let importer = GPTKImporter(searchRoots: [])
    await #expect(throws: LauncherError.consentRequired(component.id.rawValue)) {
        try await importer.importCandidate(candidate, component: component, into: store, consent: consent)
    }
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    let installed = try await importer.importCandidate(candidate, component: component, into: store, consent: consent)
    #expect(installed.kind == .d3dmetal && installed.version == "3.0" && installed.source == .importFromGPTK)
}

@Test(arguments: ["escaping-link", "fifo", "symlink-root", "oversized"])
func gptkImportRejectsUntrustedSource(attack: String) async throws {
    let temp = try TempDir(); let source = try TempDir(); let outside = try TempDir(); let cdn = MockCDN()
    var candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let control = outside.url.appendingPathComponent("control"); try Data("untouched".utf8).write(to: control)
    if attack == "escaping-link" {
        try FileManager.default.createSymbolicLink(atPath: candidate.root.appendingPathComponent("escape").path, withDestinationPath: control.path)
    } else if attack == "fifo" {
        try #require(mkfifo(candidate.root.appendingPathComponent("fifo").path, 0o600) == 0)
    } else if attack == "symlink-root" {
        let link = source.url.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: candidate.root.path)
        candidate = GPTKCandidate(root: link, d3dmetalFramework: link.appendingPathComponent("D3DMetal.framework"), version: "3.0")
    }
    let component = try gptkComponent(installedSize: attack == "oversized" ? 1 : nil)
    let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root)
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    do {
        for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
        Issue.record("Untrusted GPTK source accepted")
    } catch LauncherError.unsafePath { #expect(attack != "oversized") }
      catch LauncherError.io(let message) { #expect(attack == "oversized" && message == "Runtime import size limit exceeded") }
    #expect(try store.installed().isEmpty)
    #expect(try Data(contentsOf: control) == Data("untouched".utf8))
    #expect(cdn.requestLog.isEmpty)
}

@Test(arguments: [ComponentInstaller.PublishPoint.beforePublish, .afterPublish])
func gptkReimportFailureLeavesExactlyOneValidInstall(point: ComponentInstaller.PublishPoint) async throws {
    let temp = try TempDir(); let source = try TempDir(); let cdn = MockCDN()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let component = try gptkComponent(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root)
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
    try Data("new".utf8).write(to: candidate.d3dmetalFramework.appendingPathComponent("D3DMetal"))
    let failing = gptkInstaller(store: store, consent: consent, cdn: cdn, failurePoint: {
        if $0 == point { throw LauncherError.io("injected") }
    })
    await #expect(throws: LauncherError.io("injected")) {
        for try await _ in failing.install(component, from: candidate) { }
    }
    #expect(try store.installed().count == 1)
    let value = try String(contentsOf: store.installURL(for: component).appendingPathComponent("D3DMetal.framework/D3DMetal"), encoding: .utf8)
    #expect(value == (point == .beforePublish ? "metal" : "new"))
    try store.sweepStaging()
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("d3dmetal").path) == ["3.0"])
    #expect(cdn.requestLog.isEmpty)
}

@Test
func gptkImportPreservesInternalLinksExecutableBitsAndStripsQuarantine() async throws {
    let temp = try TempDir(); let source = try TempDir(); let cdn = MockCDN()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let binary = candidate.d3dmetalFramework.appendingPathComponent("D3DMetal")
    try #require(chmod(binary.path, 0o755) == 0)
    try FileManager.default.createSymbolicLink(atPath: candidate.root.appendingPathComponent("metal-link").path,
        withDestinationPath: "D3DMetal.framework/D3DMetal")
    let quarantine = Data("0081;test".utf8)
    try #require(quarantine.withUnsafeBytes { setxattr(binary.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0)
    let component = try gptkComponent(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root)
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
    let destination = store.installURL(for: component)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("metal-link").path) == "D3DMetal.framework/D3DMetal")
    let output = destination.appendingPathComponent("D3DMetal.framework/D3DMetal")
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(getxattr(output.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1 && errno == ENOATTR)
}

@Test
func gptkLocateToleratesUnreadableDirectoriesAndCancellation() async throws {
    let temp = try TempDir()
    let candidate = try gptkFixture(in: temp.url.appendingPathComponent("readable"))
    let unreadable = temp.url.appendingPathComponent("unreadable")
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
    try #require(chmod(unreadable.path, 0) == 0)
    defer { _ = chmod(unreadable.path, 0o700) }
    #expect(try GPTKImporter(searchRoots: [unreadable, temp.url]).locate() == [candidate])
    let searchRoot = temp.url
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try GPTKImporter(searchRoots: [searchRoot]).locate()
    }
    await #expect(throws: LauncherError.cancelled) { try await cancelled.value }
    #expect(throws: LauncherError.io("Invalid GPTK search limits")) {
        try GPTKImporter(searchRoots: [temp.url], maxDepth: -1).locate()
    }
}

@Test
func gptkImportSpaceFailurePreservesInstalledVersion() async throws {
    let temp = try TempDir(); let source = try TempDir(); let cdn = MockCDN()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let component = try gptkComponent(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root)
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
    let sizes = try ["Info.plist", "D3DMetal"].map {
        try Data(contentsOf: candidate.d3dmetalFramework.appendingPathComponent($0)).count
    }
    let expected = Int64(sizes.reduce(0, +) + 6) // Also copy the parent folder's companion.
    let installer = ComponentInstaller(store: store, consent: consent, disk: FixedDiskSpace(bytes: 0))
    await #expect(throws: LauncherError.insufficientSpace(required: expected, available: 0)) {
        for try await _ in installer.install(component, from: candidate) { }
    }
    #expect(try store.installed().count == 1)
    #expect(try String(contentsOf: store.installURL(for: component).appendingPathComponent("D3DMetal.framework/D3DMetal"), encoding: .utf8) == "metal")
}

@Test(arguments: [GPTKFaultOps.Fault.payloadSync, .copyWrite, .cancelCopy])
func gptkImportFaultsKeepOldVersionAndPermitRetry(fault: GPTKFaultOps.Fault) async throws {
    let temp = try TempDir(); let source = try TempDir(); let cdn = MockCDN()
    let candidate = try gptkFixture(in: source.url.appendingPathComponent("external"))
    let component = try gptkComponent(); let paths = AppPaths(root: temp.url); let store = RuntimeStore(paths: paths)
    let consent = ConsentStore(url: paths.consent, root: paths.root)
    try await consent.accept(.appleGPTK, version: "3.0", termsRevision: "2026-10")
    for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
    let replacement = Data(repeating: 0x61, count: 131_072)
    try replacement.write(to: candidate.d3dmetalFramework.appendingPathComponent("D3DMetal"))
    let installer = ComponentInstaller(store: store, consent: consent, disk: FixedDiskSpace(bytes: 10 << 30), fileOps: GPTKFaultOps(fault: fault))
    let operation = Task { for try await _ in installer.install(component, from: candidate) { } }
    await #expect(throws: fault == .cancelCopy ? LauncherError.cancelled : LauncherError.io("injected import fault")) {
        try await operation.value
    }
    #expect(try store.installed().count == 1)
    let output = store.installURL(for: component).appendingPathComponent("D3DMetal.framework/D3DMetal")
    #expect(try Data(contentsOf: output) == Data("metal".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("d3dmetal").path) == ["3.0"])
    for try await _ in gptkInstaller(store: store, consent: consent, cdn: cdn).install(component, from: candidate) { }
    #expect(try Data(contentsOf: output) == replacement)
    #expect(cdn.requestLog.isEmpty)
}

struct GPTKFaultOps: FileOps {
    enum Fault: Sendable { case payloadSync, copyWrite, cancelCopy }
    let fault: Fault
    private func isPayload(_ fd: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("/D3DMetal")
    }
    func write(_ fd: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if isPayload(fd) {
            if fault == .copyWrite { throw LauncherError.io("injected import fault") }
            if fault == .cancelCopy { withUnsafeCurrentTask { $0?.cancel() } }
        }
        return try SystemFileOps().write(fd, bytes: bytes)
    }
    func synchronize(_ fd: Int32, durable: Bool) throws {
        if fault == .payloadSync && isPayload(fd) { throw LauncherError.io("injected import fault") }
        try SystemFileOps().synchronize(fd, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String,
        in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}

private func gptkFixture(in root: URL) throws -> GPTKCandidate {
    let framework = root.appendingPathComponent("D3DMetal.framework")
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    try gptkPlist("3.0").write(to: framework.appendingPathComponent("Info.plist"))
    try Data("metal".utf8).write(to: framework.appendingPathComponent("D3DMetal"))
    try Data("helper".utf8).write(to: root.appendingPathComponent("companion"))
    return GPTKCandidate(root: root, d3dmetalFramework: framework, version: "3.0")
}

private func gptkPlist(_ version: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
}

private func gptkComponent(installedSize: Int64? = nil) throws -> RuntimeComponent {
    try RuntimeComponent(id: SafeIdentifier("d3dmetal-3.0"), kind: .d3dmetal, version: SafeIdentifier("3.0"), sourceMode: .importFromGPTK,
        installedSize: installedSize, license: ComponentLicense(name: "Apple GPTK", url: AppleNotice.termsURL,
            redistributable: false, termsRevision: "2026-10"), consent: .appleGPTK)
}

private func gptkInstaller(store: RuntimeStore, consent: ConsentStore, cdn: MockCDN,
    failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void = { _ in }) -> ComponentInstaller {
    ComponentInstaller(store: store, consent: consent,
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 10 << 30), failurePoint: failurePoint)
}
