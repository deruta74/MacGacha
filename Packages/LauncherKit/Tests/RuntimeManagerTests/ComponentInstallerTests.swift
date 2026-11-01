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
func consentGateBlocksBeforeNetwork() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("lib", body: "metal")], format: .tarGZ)
    let component = try installerComponent(bytes, kind: .d3dmetal)
    let installer = try makeInstaller(root: temp.url, cdn: cdn)
    await #expect(throws: LauncherError.consentRequired(component.id.rawValue)) {
        for try await _ in installer.install(component) { }
    }
    #expect(cdn.requestLog.isEmpty)
    let consent = ConsentStore(url: temp.url.appendingPathComponent("consent.json"), root: temp.url)
    try await consent.accept(.appleGPTK, version: "1.0", termsRevision: "old")
    await #expect(throws: LauncherError.consentRequired(component.id.rawValue)) {
        for try await _ in installer.install(component) { }
    }
    #expect(cdn.requestLog.isEmpty)
    try await consent.accept(.appleGPTK, version: "1.0", termsRevision: "1")
    cdn.serve("archive", data: bytes)
    for try await _ in installer.install(component) { }
    #expect(cdn.requestLog.count == 1)
}

@Test
func installsTarGzComponentAndCompletesOnlyAfterPublish() async throws {
    let temp = try TempDir(); let fixture = try TempDir(); let cdn = MockCDN()
    try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let script = Data("#!/bin/sh\necho wine\n".utf8)
    try script.write(to: fixture.url.appendingPathComponent("bin/wine"))
    let archive = temp.url.appendingPathComponent("fixture.tar.gz")
    let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", fixture.url.path, "bin"], environment: [:], currentDirectory: nil)
    try #require(result.exitCode == 0)
    let bytes = try Data(contentsOf: archive); cdn.serve("archive", data: bytes)
    let c = try installerComponent(bytes); let paths = AppPaths(root: temp.url)
    let store = RuntimeStore(paths: paths); let installer = try makeInstaller(root: temp.url, cdn: cdn)
    var events: [OperationEvent] = []
    for try await event in installer.install(c) {
        events.append(event)
        if event == .phase(.completed) { #expect(try store.installed().count == 1) }
    }
    #expect(events.filter { $0 == .phase(.completed) }.count == 1)
    #expect(events.last == .phase(.completed))
    #expect(events.contains { if case .progress = $0 { return true }; return false })
    let target = store.installURL(for: c)
    #expect(try Data(contentsOf: target.appendingPathComponent("bin/wine")) == script)
    let marker = try JSONDecoder().decode(InstalledComponent.self, from: Data(contentsOf: target.appendingPathComponent(".macgacha-component.json")))
    #expect(marker.kind == .wine && marker.version == "1.0" && marker.source == .download)
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.appendingPathComponent("wine").path) == ["1.0"])
    #expect(!FileManager.default.fileExists(atPath: paths.runtimes.appendingPathComponent(".downloads/\(c.id)").path))
}

@Test
func reinstallsOverNonemptyVersionWithAtomicSwap() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); let store = RuntimeStore(paths: AppPaths(root: temp.url))
    let old = archiveTestData([ArchiveTestEntry("old", body: "old")], format: .zip)
    let new = archiveTestData([ArchiveTestEntry("new", body: "new")], format: .zip)
    let installer = try makeInstaller(root: temp.url, cdn: cdn)
    cdn.serve("archive", data: old)
    for try await _ in installer.install(try installerComponent(old, format: .zip)) { }
    cdn.serve("archive", data: new)
    let c = try installerComponent(new, format: .zip)
    for try await _ in installer.install(c) { }
    #expect(try store.installed().count == 1)
    #expect(try Data(contentsOf: store.installURL(for: c).appendingPathComponent("new")) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: store.installURL(for: c).appendingPathComponent("old").path))
}

@Test(arguments: [ComponentInstaller.PublishPoint.beforePublish, .afterPublish])
func publishFailureLeavesExactlyOneValidInstall(point: ComponentInstaller.PublishPoint) async throws {
    let temp = try TempDir(); let cdn = MockCDN(); let paths = AppPaths(root: temp.url)
    let store = RuntimeStore(paths: paths)
    let old = archiveTestData([ArchiveTestEntry("value", body: "old")], format: .tarGZ)
    let new = archiveTestData([ArchiveTestEntry("value", body: "new")], format: .tarGZ)
    cdn.serve("archive", data: old)
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(try installerComponent(old)) { }
    cdn.serve("archive", data: new)
    let c = try installerComponent(new)
    let installer = try makeInstaller(root: temp.url, cdn: cdn, failurePoint: { if $0 == point { throw LauncherError.io("injected") } })
    var completed = 0
    await #expect(throws: LauncherError.io("injected")) {
        for try await event in installer.install(c) { if event == .phase(.completed) { completed += 1 } }
    }
    #expect(completed == 0)
    #expect(try store.installed().count == 1)
    let expected = point == .beforePublish ? "old" : "new"
    #expect(try String(contentsOf: store.installURL(for: c).appendingPathComponent("value"), encoding: .utf8) == expected)
    // Startup cleanup of an interrupted publish never removes the visible install.
    try store.sweepStaging()
    #expect(try store.installed().count == 1)
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(c) { }
    #expect(try String(contentsOf: store.installURL(for: c).appendingPathComponent("value"), encoding: .utf8) == "new")
}

@Test
func extractionFailurePreservesExistingInstall() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); let store = RuntimeStore(paths: AppPaths(root: temp.url))
    let old = archiveTestData([ArchiveTestEntry("value", body: "old")], format: .tarGZ)
    cdn.serve("archive", data: old)
    let c = try installerComponent(old)
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(c) { }
    let evil = archiveTestData([ArchiveTestEntry("../escape", body: "bad")], format: .tarGZ)
    cdn.serve("archive", data: evil)
    do {
        for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(try installerComponent(evil)) { }
        Issue.record("Unsafe runtime installed")
    } catch LauncherError.unsafePath { }
    #expect(try String(contentsOf: store.installURL(for: c).appendingPathComponent("value"), encoding: .utf8) == "old")
    #expect(try store.installed().count == 1)
}

@Test
func installerStripsQuarantineRecursively() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("bin/wine", body: "new"), ArchiveTestEntry("bin/link", type: .symlink, link: "wine")], format: .tarGZ)
    cdn.serve("archive", data: bytes)
    let real = SystemProcessRunner()
    let runner = FakeProcessRunner { invocation in
        let result = try await real.run(invocation.executable, arguments: invocation.arguments, environment: invocation.environment, currentDirectory: invocation.currentDirectory)
        if invocation.arguments.first == "-xf", let targetIndex = invocation.arguments.firstIndex(of: "-C") {
            let target = URL(fileURLWithPath: invocation.arguments[targetIndex + 1])
            for path in [target.path, target.appendingPathComponent("bin").path, target.appendingPathComponent("bin/wine").path, target.appendingPathComponent("bin/link").path] {
                let value = Array("0081;test".utf8)
                try #require(value.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) } == 0)
            }
        }
        return result
    }
    let c = try installerComponent(bytes)
    let installer = try makeInstaller(root: temp.url, cdn: cdn, runner: runner)
    for try await _ in installer.install(c) { }
    let target = RuntimeStore(paths: AppPaths(root: temp.url)).installURL(for: c)
    for url in [target, target.appendingPathComponent("bin"), target.appendingPathComponent("bin/wine"), target.appendingPathComponent("bin/link")] {
        #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        #expect(errno == ENOATTR)
    }
}

@Test
func installerChecksSpaceBeforeNetworkAndRetainsOldVersion() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ)
    let c = try installerComponent(bytes)
    let required = Int64(bytes.count) + c.installedSize!
    let installer = try makeInstaller(root: temp.url, cdn: cdn, disk: FixedDiskSpace(bytes: required - 1))
    await #expect(throws: LauncherError.insufficientSpace(required: required, available: required - 1)) {
        for try await _ in installer.install(c) { }
    }
    #expect(cdn.requestLog.isEmpty)
}

@Test
func installerStoreLockIsHeldAndDiscardReleasesIt() async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ)
    cdn.serve("archive", data: bytes)
    let c = try installerComponent(bytes); let installer = try makeInstaller(root: temp.url, cdn: cdn)
    for _ in 0..<20 {
        try await pauseAndDiscardInstaller(installer, c)
        // Swift may finish releasing an async call frame after its caller resumes.
        // Observe lock release with a deadline rather than relying on immediate ARC timing.
        let fs = try ContainedFileSystem(root: temp.url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var released = false
        while !released && ContinuousClock.now < deadline {
            do { try probeRuntimeLock(fs); released = true }
            catch LauncherError.busy { try await Task.sleep(for: .milliseconds(10)) }
        }
        try #require(released)
        // The store lock is the outermost lock: once it is free, the session's
        // component pins must already be free, or an immediate retry is busy.
        let pins = try RuntimeStore.componentLocks(paths: AppPaths(root: temp.url), componentIDs: [c.id.rawValue], mode: .exclusive)
        withExtendedLifetime(pins) {}
    }
    for try await _ in installer.install(c) { }
    #expect(cdn.requestLog.count == 1)
}

@Test(arguments: ["Runtimes", "Runtimes/wine", "Runtimes/wine/1.0"])
func installerRejectsSymlinkRuntimeAncestorWithoutNetwork(path: String) async throws {
    let temp = try TempDir(); let outside = try TempDir(); let cdn = MockCDN()
    let link = temp.url.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
    let c = try installerComponent(archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ))
    do {
        for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(c) { }
        Issue.record("Symlink ancestor accepted")
    } catch LauncherError.unsafePath { }
    #expect(cdn.requestLog.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

func installerComponent(_ bytes: Data, kind: ComponentKind = .wine, format: ArchiveFormat = .tarGZ) throws -> RuntimeComponent {
    var hasher = StreamingHasher(.sha256); hasher.update(bytes)
    return try RuntimeComponent(id: SafeIdentifier("\(kind.rawValue)-1.0"), kind: kind, version: SafeIdentifier("1.0"), sourceMode: .download,
        url: URL(string: "https://fixtures.invalid/archive"), size: Int64(bytes.count), installedSize: 1024, sha256: hasher.finalize(), archive: format,
        license: ComponentLicense(name: "fixture", url: URL(string: "https://fixtures.invalid/license")!, redistributable: kind != .d3dmetal, termsRevision: "1"),
        consent: kind == .d3dmetal ? .appleGPTK : nil)
}

private func makeInstaller(root: URL, cdn: MockCDN, runner: any ProcessRunner = SystemProcessRunner(),
    disk: any DiskSpaceProbe = FixedDiskSpace(bytes: 10 << 30),
    fileOps: any FileOps = SystemFileOps(),
    failurePoint: @escaping @Sendable (ComponentInstaller.PublishPoint) throws -> Void = { _ in }) throws -> ComponentInstaller {
    let paths = AppPaths(root: root)
    return ComponentInstaller(store: RuntimeStore(paths: paths), consent: ConsentStore(url: paths.consent, root: root),
        fetcher: ChunkFetcher(http: cdn, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: runner), disk: disk, fileOps: fileOps, failurePoint: failurePoint)
}

@Test(.timeLimit(.minutes(1)), arguments: ["beforePull", "betweenPulls"])
func installerCancellationAtPullBoundaryThrowsAndCleansDownloads(point: String) async throws {
    let temp = try TempDir(), paths = AppPaths(root: temp.url), cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ)
    let component = try installerComponent(bytes)
    cdn.serve("archive", data: bytes)
    let installer = try makeInstaller(root: temp.url, cdn: cdn)
    let task = Task {
        if point == "beforePull" { withUnsafeCurrentTask { $0?.cancel() } }
        for try await event in installer.install(component) {
            if point == "betweenPulls", event == .phase(.staging) { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: paths.runtimes.appendingPathComponent(".downloads/\(component.id)").path))
    try probeRuntimeLock(ContainedFileSystem(root: temp.url))
}

@Test(.timeLimit(.minutes(1)), arguments: ["headers", "body"])
func cancellingInstallerCancelsNetworkAndReleasesStoreLock(point: String) async throws {
    let temp = try TempDir(), paths = AppPaths(root: temp.url)
    let bytes = Data(repeating: 0x61, count: 131_072)
    let http = InstallerStalledHTTP(body: point == "body" ? bytes : nil)
    let c = try installerComponent(bytes)
    let installer = ComponentInstaller(store: RuntimeStore(paths: paths), consent: ConsentStore(url: paths.consent, root: paths.root),
        fetcher: ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: SystemProcessRunner()), disk: FixedDiskSpace(bytes: 10 << 30))
    let task = Task { for try await _ in installer.install(c) { } }
    defer { task.cancel() }
    await http.waitUntilStarted()
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(http.cancelled)
    #expect(!FileManager.default.fileExists(atPath: paths.runtimes.appendingPathComponent(".downloads/\(c.id)").path))
    #expect(try RuntimeStore(paths: paths).installed().isEmpty)
    // A valid archive then installs, proving cancellation released the store lock.
    let archive = archiveTestData([ArchiveTestEntry("file", body: "ok")], format: .tarGZ)
    let cdn = MockCDN(); cdn.serve("archive", data: archive)
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(installerComponent(archive)) { }
    #expect(try RuntimeStore(paths: paths).installed().count == 1)
}

private final class InstallerStalledHTTP: HTTPClient {
    private let body: Data?
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellation = Mutex(false)
    var cancelled: Bool { cancellation.withLock { $0 } }
    init(body: Data?) { self.body = body }
    func waitUntilStarted() async { for await _ in started.stream { return } }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if let body {
            let state = InstallerStalledBody(prefix: Data(body.prefix(65_536)), started: { self.started.continuation.yield(()) })
            return (HTTPResponseHead(status: 200, contentLength: Int64(body.count)),
                HTTPBody(next: { try await state.next() }, onCancel: { self.cancellation.withLock { $0 = true } }))
        }
        started.continuation.yield(())
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancellation.withLock { $0 = true }; throw error }
        throw LauncherError.transport("test watchdog reached")
    }
}

private actor InstallerStalledBody {
    let prefix: Data
    let started: @Sendable () -> Void
    var sent = false
    init(prefix: Data, started: @escaping @Sendable () -> Void) { self.prefix = prefix; self.started = started }
    func next() async throws -> Data? {
        if !sent { sent = true; return prefix }
        started() // The fetcher has written the prefix before it asks for more.
        try await Task.sleep(for: .seconds(30))
        throw LauncherError.transport("test watchdog reached")
    }
}

private func pauseAndDiscardInstaller(_ installer: ComponentInstaller, _ c: RuntimeComponent) async throws {
    var iterator = installer.install(c).makeAsyncIterator()
    #expect(try await iterator.next() == .phase(.checkingSpace))
    await #expect(throws: LauncherError.busy("install root in use")) {
        for try await _ in installer.install(c) { }
    }
    withExtendedLifetime(iterator) {}
}

private func probeRuntimeLock(_ fs: ContainedFileSystem) throws {
    let lock = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.lock"))
    withExtendedLifetime(lock) {}
}


@Test(arguments: ["payload", "sub", ".macgacha-component.json", "publish-parent-1", "publish-parent-2"], [false, true])
func runtimeSyncFailurePreservesOldPayloadAndRetryPublishes(failedLeaf: String, existing: Bool) async throws {
    let temp = try TempDir(); let cdn = MockCDN(); let store = RuntimeStore(paths: AppPaths(root: temp.url))
    let old = archiveTestData([ArchiveTestEntry("old", body: "old payload")], format: .tarGZ)
    cdn.serve("archive", data: old)
    if existing { for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(try installerComponent(old)) { } }
    let new = archiveTestData([ArchiveTestEntry("sub/", type: .directory), ArchiveTestEntry("sub/payload", body: "replacement")], format: .tarGZ)
    let component = try installerComponent(new); cdn.serve("archive", data: new)
    let faults = RuntimeSyncAudit(failedLeaf: failedLeaf)
    await #expect(throws: LauncherError.io("injected runtime sync failure")) {
        for try await _ in try makeInstaller(root: temp.url, cdn: cdn, fileOps: faults).install(component) { }
    }
    let target = store.installURL(for: component)
    if existing { #expect(try Data(contentsOf: target.appendingPathComponent("old")) == Data("old payload".utf8)) }
    else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("sub/payload").path))
    #expect(try store.installed().count == (existing ? 1 : 0))
    if !failedLeaf.hasPrefix("publish-parent-") { #expect(!faults.events.contains(.publish)) }
    #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Runtimes/.downloads/\(component.id)").path))
    let audit = RuntimeSyncAudit()
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn, fileOps: audit).install(component) { }
    #expect(try Data(contentsOf: target.appendingPathComponent("sub/payload")) == Data("replacement".utf8))
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old").path))
    let events = audit.events
    let file = try #require(events.firstIndex { if case .sync(let path, _) = $0 { return path.contains(".incoming-") && path.hasSuffix("/sub/payload") }; return false })
    let sub = try #require(events.firstIndex { if case .sync(let path, _) = $0 { return path.contains(".incoming-") && path.hasSuffix("/sub") }; return false })
    let root = try #require(events.firstIndex { if case .sync(let path, _) = $0 { return path.split(separator: "/").last?.hasPrefix(".incoming-") == true }; return false })
    let marker = try #require(events.firstIndex { if case .sync(let path, true) = $0 { return path.hasSuffix("/.macgacha-component.json") }; return false })
    let swap = try #require(events.firstIndex(of: .publish))
    #expect(file < sub && sub < root && root < marker && marker < swap)
    #expect(events.dropFirst(swap + 1).filter { if case .sync(let path, _) = $0 { return path.hasSuffix("/Runtimes/wine") }; return false }.count >= 2)
}

@Test
func failedRuntimeInstallRemovesDownloadsAndSweepReclaimsStaleDownloads() async throws {
    let temp = try TempDir(); let cdn = MockCDN(); let paths = AppPaths(root: temp.url)
    let bytes = archiveTestData([ArchiveTestEntry("../escape", body: "bad")], format: .tarGZ)
    cdn.serve("archive", data: bytes)
    let component = try installerComponent(bytes)
    do {
        for try await _ in try makeInstaller(root: temp.url, cdn: cdn).install(component) { }
        Issue.record("Unsafe runtime installed")
    } catch LauncherError.unsafePath { }
    let fs = try ContainedFileSystem(root: temp.url)
    #expect(try fs.itemType(at: SafeRelativePath("Runtimes/.downloads/\(component.id)")) == nil)
    #expect(try fs.itemType(at: SafeRelativePath("Runtimes/.downloads")) == nil)
    try fs.writeAtomically(Data("abandoned".utf8), to: SafeRelativePath("Runtimes/.downloads/other-version/archive"))
    let lease = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.lock"))
    try RuntimeStore(paths: paths).sweepStaging()
    #expect(try fs.itemType(at: SafeRelativePath("Runtimes/.downloads/other-version")) == nil)
    withExtendedLifetime(lease) {}
}

private final class RuntimeSyncAudit: FileOps, Sendable {
    enum Event: Sendable, Equatable { case sync(String, Bool), publish }
    private let recorded = Mutex([Event]())
    private let failedLeaf: String?
    private let publishedSyncCount = Mutex(0)
    init(failedLeaf: String? = nil) { self.failedLeaf = failedLeaf }
    var events: [Event] { recorded.withLock { $0 } }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard buffer.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else { throw LauncherError.io("Cannot inspect test descriptor") }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let published = recorded.withLock { events in
            events.append(.sync(path, durable))
            return events.contains(.publish)
        }
        if published && path.hasSuffix("/Runtimes/wine") {
            let ordinal = publishedSyncCount.withLock { $0 += 1; return $0 }
            if failedLeaf == "publish-parent-\(ordinal)" { throw LauncherError.io("injected runtime sync failure") }
        }
        if let failedLeaf, path.contains("/.incoming-"), path.hasSuffix("/" + failedLeaf) { throw LauncherError.io("injected runtime sync failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if destination == "1.0" { recorded.withLock { $0.append(.publish) } }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func swap(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32) throws {
        recorded.withLock { $0.append(.publish) }
        try SystemFileOps().swap(from: source, in: sourceDirectory, to: destination, in: destinationDirectory)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}


@Test
func interruptedStaleDownloadSweepResumesUnderStoreLock() throws {
    let temp = try TempDir(); let outside = try TempDir()
    let fs = try ContainedFileSystem(root: temp.url); let store = RuntimeStore(paths: AppPaths(root: temp.url))
    try fs.writeAtomically(Data("abandoned".utf8), to: SafeRelativePath("Runtimes/.downloads/stale/archive"))
    let control = outside.url.appendingPathComponent("control")
    try Data("outside".utf8).write(to: control)
    try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Runtimes/.downloads/stale/link"), withDestinationURL: outside.url)
    let lease = try InstallLock(fs: fs, path: SafeRelativePath("Runtimes/.lock"))
    #expect(throws: LauncherError.cancelled) { try store.sweepStaging(deleting: { _, _ in throw LauncherError.cancelled }) }
    #expect(try fs.itemType(at: SafeRelativePath("Runtimes/.downloads")) == nil)
    #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Runtimes")).filter { $0.components.last!.hasPrefix(".removing-") }.count == 1)
    try store.sweepStaging()
    #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Runtimes")).allSatisfy { !$0.components.last!.hasPrefix(".removing-") })
    #expect(try Data(contentsOf: control) == Data("outside".utf8))
    withExtendedLifetime(lease) {}
}

@Test(arguments: [false, true]) func quarantineCleanupAcceptsReadOnlyFilesWithoutQuarantine(quarantined: Bool) async throws {
    let temp = try TempDir(); let cdn = MockCDN()
    let bytes = archiveTestData([ArchiveTestEntry("readonly", body: "payload")], format: .tarGZ)
    cdn.serve("archive", data: bytes)
    let real = SystemProcessRunner()
    let runner = FakeProcessRunner { invocation in
        let result = try await real.run(invocation.executable, arguments: invocation.arguments,
            environment: invocation.environment, currentDirectory: invocation.currentDirectory)
        if let index = invocation.arguments.firstIndex(of: "-C") {
            let file = URL(fileURLWithPath: invocation.arguments[index + 1]).appendingPathComponent("readonly")
            if quarantined {
                let data = Data("0081;test".utf8)
                try #require(data.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
            }
            try #require(chmod(file.path, 0o444) == 0)
        }
        return result
    }
    let component = try installerComponent(bytes)
    for try await _ in try makeInstaller(root: temp.url, cdn: cdn, runner: runner).install(component) { }
    #expect(try RuntimeStore(paths: AppPaths(root: temp.url)).installed().count == 1)
}
