// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import GameLibrary
import RuntimeManager
import TestSupport
@testable import Launch

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACGACHA_RUNTIME_FIXTURES"] != nil))
struct LaunchIntegrationTests {
    @Test(.timeLimit(.minutes(30)), arguments: ["d3dmetal", "dxmt"])
    func realLaunchAndCrashRecovery(backend: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await withProbeTestRoot(root: root, setup: { try await install(backend: backend, root: $0) }) { configuration in
            do {
                try await cleanLaunch(configuration)
                for step in LaunchFileStep.hideSteps {
                    try await killedAtBoundary(configuration, step: step, conflict: false)
                }
                for step in restoreSteps {
                    let conflict = [.beforeRecoveryNoteWrite, .afterRecoveryNoteWrite, .beforeRecoveryRename, .afterRecoveryRename].contains(step)
                    try await killedAtBoundary(configuration, step: step, conflict: conflict)
                }
                try await killedWhileLive(configuration)
                try await conflictThenNextLaunch(configuration)
                try await stalledInspectionStillReachesTeardown(configuration)
            } catch {
                do {
                    try await BlockingIO.run {
                        let fs = try ContainedFileSystem(root: configuration.paths.logs)
                        for path in try fs.contentsOfRootDirectory() where path.description.hasSuffix(".log") {
                            let data = try fs.readFile(at: path, maxBytes: 64 << 20)
                            print("Failed integration log \(path): \(String(decoding: data.suffix(8192), as: UTF8.self))")
                        }
                    }
                } catch { print("Could not read failed probe logs: \(error)") }
                throw error
            }
        }
        print("LaunchIntegrationTests \(backend): D3D11 0xb000; clean launch, \(LaunchFileStep.hideSteps.count) hide + \(restoreSteps.count) restore SIGKILL boundaries, live reattach, conflict/next launch PASS")
    }
}

private let restoreSteps = LaunchFileStep.restoreSteps + [.beforeClaimWrite, .afterClaimWrite, .afterClaimRename, .afterClaimPostcheck]
private let originalDLL = Data("integration original vulkan DLL".utf8)
private let replacementDLL = Data("integration replacement vulkan DLL".utf8)

private func install(backend: String, root: URL) async throws -> ProbeLaunchConfiguration {
    let fixtures = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_RUNTIME_FIXTURES"]))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let manifest = try RuntimeManifest.load(from: repository.appendingPathComponent("App/Resources/runtime-manifest.json"))
    let definition = try #require(manifest.bundles.first { $0.id.rawValue == (backend == "dxmt" ? "dxmt-wine11.0-dxmt0.80" : "d3dmetal-wine11.20-gptk4.0b3") })
    let paths = AppPaths(root: root.appendingPathComponent("store"))
    let store = RuntimeStore(paths: paths), consent = ConsentStore(url: paths.consent, root: paths.root)
    for component in manifest.components where definition.components.contains(component.id) && component.consent != nil {
        try await consent.accept(.appleGPTK, version: component.version.rawValue, termsRevision: component.license.termsRevision)
    }
    let runner = SystemProcessRunner()
    let installer = ComponentInstaller(store: store, consent: consent,
        fetcher: ChunkFetcher(http: ProbeFixtureHTTP(root: fixtures), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
        extractor: ArchiveExtractor(runner: runner), disk: SystemDiskSpaceProbe())
    let runtime = try await RuntimeBundleManager(manifest: manifest, store: store, consent: consent, installer: installer, runner: runner).install(definition)
    let configuration = ProbeLaunchConfiguration(root: root, bundleID: runtime.id, bundleRoot: runtime.root,
        wine: runtime.wineBinary, digest: runtime.digest, componentIDs: definition.components.map(\.rawValue))
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: root)
        try fs.createDirectory(at: SafeRelativePath("game"))
        // The waiting variant calls the original D3D11 probe before its ready/release handshake.
        let fixtureFS = try ContainedFileSystem(root: fixtures)
        try fs.writeAtomically(fixtureFS.readFile(at: SafeRelativePath("d3d11waitprobe.exe"), maxBytes: 8 << 20),
            to: SafeRelativePath("game/d3d11probe.exe"))
        try configuration.write()
        try LaunchSettingsStore(paths: paths).save(LaunchSettings(backend: definition.backend, retina: false,
            frameLimit: nil, directX12: false, compatibilityPatches: true), for: "starrail")
    }
    return configuration
}

private func reset(_ configuration: ProbeLaunchConfiguration) async throws {
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: configuration.gameRoot)
        try removeSignals(configuration)
        try fs.writeAtomically(originalDLL, to: SafeRelativePath("vulkan-1.dll"))
    }
}

private func cleanLaunch(_ configuration: ProbeLaunchConfiguration, expected: Data = originalDLL, resetFiles: Bool = true) async throws {
    if resetFiles { try await reset(configuration) }
    try await withHarness(configuration, mode: "complete") { child in
        try await waitForSignal(configuration, "launcher-ready", child: child)
        let snapshot = try #require(try await readJournal(configuration))
        try await assertHidden(configuration, snapshot: snapshot, expected: expected)
        let port = try #require(snapshot.proxyPort)
        try await assertBlocked(port: port)
        try await BlockingIO.run { try configuration.signal("probe-release") }
        try #require(try await child.result().exitCode == 0)
        try await assertRestored(configuration, expected: expected)
        try await assertClosed(port)
        let log = try #require(snapshot.sessionLogURL)
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: configuration.paths.logs)
            let output = String(decoding: try fs.readFile(at: SafeRelativePath(log.lastPathComponent), maxBytes: 64 << 20), as: UTF8.self)
            #expect(output.contains("feature_level=0xb000"))
            #expect(output.contains("blocked.test"))
        }
    }
}

private func killedAtBoundary(_ configuration: ProbeLaunchConfiguration, step: LaunchFileStep, conflict: Bool) async throws {
    try await reset(configuration)
    let restoring = !LaunchFileStep.hideSteps.contains(step)
    var crashedSession: LaunchSession?
    try await withHarness(configuration, mode: step.rawValue, conflict: conflict) { child in
        if restoring {
            try await waitForSignal(configuration, "launcher-ready", child: child)
            crashedSession = try await readJournal(configuration)
            try await BlockingIO.run { try configuration.signal("probe-release") }
        }
        let result = try await child.result()
        try #require(result.exitCode == SIGKILL, "Boundary not reached: \(step), \(String(decoding: result.stderr, as: UTF8.self))")
    }
    try await recover(configuration)
    try await assertRestored(configuration, expected: conflict ? replacementDLL : originalDLL)
    if let port = crashedSession?.proxyPort { try await assertClosed(port) }
    if conflict { try await assertRecoveryCopy(configuration, sessionID: try #require(crashedSession?.sessionID)) }
    print("SIGKILL \(configuration.bundleID) \(step.rawValue): restored")
}

private func killedWhileLive(_ configuration: ProbeLaunchConfiguration) async throws {
    try await reset(configuration)
    try await withHarness(configuration, mode: "live") { child in
        try await waitForSignal(configuration, "launcher-ready", child: child)
        let session = try #require(try await readJournal(configuration))
        try await assertHidden(configuration, snapshot: session)
        try await killLauncher(configuration)
        try #require(try await child.result().exitCode == SIGKILL)
        try await withHarness(configuration, mode: "recover") { recovery in
            try await waitForSignal(configuration, "recovery-ready", child: recovery)
            let attached = try await BlockingIO.run {
                try JSONDecoder().decode([String: UUID].self, from: ContainedFileSystem(root: configuration.gameRoot)
                    .readFile(at: SafeRelativePath("recovery-attached.json"), maxBytes: 65536))
            }
            #expect(attached["starrail"] == session.sessionID)
            try await assertHidden(configuration, snapshot: session)
            try await assertClosed(try #require(session.proxyPort))
            try await BlockingIO.run { try configuration.signal("probe-release") }
            try #require(try await recovery.result().exitCode == 0)
        }
        try await assertRestored(configuration)
    }
}

private func conflictThenNextLaunch(_ configuration: ProbeLaunchConfiguration) async throws {
    try await reset(configuration)
    try await withHarness(configuration, mode: "live", conflict: true) { child in
        try await waitForSignal(configuration, "launcher-ready", child: child)
        let snapshot = try #require(try await readJournal(configuration))
        try await killLauncher(configuration)
        try #require(try await child.result().exitCode == SIGKILL)
        try await withHarness(configuration, mode: "recover") { recovery in
            try await waitForSignal(configuration, "recovery-ready", child: recovery)
            try await BlockingIO.run { try configuration.signal("probe-release") }
            try #require(try await recovery.result().exitCode == 0)
        }
        try await assertRestored(configuration, expected: replacementDLL)
        let notices = try await readNotices(configuration)
        try await assertRecoveryCopy(configuration, sessionID: snapshot.sessionID)
        try await BlockingIO.run { try removeSignals(configuration) }
        try await cleanLaunch(configuration, expected: replacementDLL, resetFiles: false)
        #expect(try await readNotices(configuration) == notices)
        try await assertRecoveryCopy(configuration, sessionID: snapshot.sessionID)
    }
}

/// Reproduce the review's persistent inspection failure with real Wine. The
/// deadline fires only after the inspector confirms it has entered the retry loop.
private func stalledInspectionStillReachesTeardown(_ configuration: ProbeLaunchConfiguration) async throws {
    try await reset(configuration)
    let deadline = TestEvent()
    let child = makeHarness(configuration, mode: "stall-inspection", timeoutWait: { _ in try await deadline.wait() })
    do {
        try await waitForSignal(configuration, "launcher-ready", child: child)
        try await BlockingIO.run { try configuration.signal("probe-release") }
        try await waitForSignal(configuration, "inspection-stalled", child: child)
        deadline.signal()
        await #expect(throws: LauncherError.self) { try await child.result() }
        await child.stop()
    } catch {
        await child.stop()
        throw error
    }
    try await recover(configuration)
    try await assertRestored(configuration)
    print("\(configuration.bundleID) persistent inspection failure: bounded child joined, recovery completed")
}

private func recover(_ configuration: ProbeLaunchConfiguration) async throws {
    try await withHarness(configuration, mode: "recover") { child in
        try #require(try await child.result().exitCode == 0)
    }
}
private func killLauncher(_ configuration: ProbeLaunchConfiguration) async throws {
    let pid = try await BlockingIO.run {
        try #require(Int32(String(decoding: ContainedFileSystem(root: configuration.gameRoot)
            .readFile(at: SafeRelativePath("launcher-ready"), maxBytes: 32), as: UTF8.self)))
    }
    try #require(kill(pid, SIGKILL) == 0)
}
private func waitForSignal(_ configuration: ProbeLaunchConfiguration, _ name: String, child: ProbeHarnessChild) async throws {
    let ready = try FileAppearanceEvent(configuration.gameRoot.appendingPathComponent(name))
    do {
        try await child.waitUntilReady(step: name) { try await ready.wait() }
    } catch {
        if error is CancellationError { throw error }
        let diagnostics = (try? await BlockingIO.run { try configuration.handshakeDiagnostics() }) ?? "handshake diagnostics unavailable"
        throw LauncherError.io("\(error); \(diagnostics)")
    }
}
private func removeSignals(_ configuration: ProbeLaunchConfiguration) throws {
    let fs = try ContainedFileSystem(root: configuration.gameRoot)
    for name in ["probe-ready", "probe-release", "launcher-ready", "recovery-ready", "recovery-attached.json", "inspection-stalled", "harness-phase", "inspection-error"] {
        if try fs.itemType(at: SafeRelativePath(name)) != nil { try fs.removeFile(at: SafeRelativePath(name)) }
    }
}
private func withHarness(_ configuration: ProbeLaunchConfiguration, mode: String, conflict: Bool = false,
    operation: (ProbeHarnessChild) async throws -> Void) async throws {
    let child = makeHarness(configuration, mode: mode, conflict: conflict)
    do {
        try await operation(child)
        await child.stop()
    } catch {
        await child.stop()
        throw error
    }
}
private func makeHarness(_ configuration: ProbeLaunchConfiguration, mode: String, conflict: Bool = false,
    timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> ProbeHarnessChild {
    let executable = Bundle(for: ProbeBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CrashHarness")
    return ProbeHarnessChild(executable: executable,
        arguments: ["launch-integration", configuration.root.path, mode, conflict ? "conflict" : "clean"],
        root: configuration.root, label: "\(configuration.bundleID) / \(mode)", timeoutWait: timeoutWait)
}
private final class ProbeBundleToken: NSObject {}

private func readJournal(_ configuration: ProbeLaunchConfiguration) async throws -> LaunchSession? {
    try await BlockingIO.run { try LaunchJournal(paths: configuration.paths).read(game: "starrail") }
}
private func assertHidden(_ configuration: ProbeLaunchConfiguration, snapshot: LaunchSession, expected: Data = originalDLL) async throws {
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: configuration.gameRoot)
        #expect(try fs.itemType(at: SafeRelativePath("vulkan-1.dll")) == nil)
        let entry = try #require(snapshot.hides.first)
        #expect(try fs.readFile(at: snapshot.hiddenPath(entry), maxBytes: 1024) == expected)
    }
}
private func assertRestored(_ configuration: ProbeLaunchConfiguration, expected: Data = originalDLL) async throws {
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: configuration.gameRoot)
        #expect(try fs.readFile(at: SafeRelativePath("vulkan-1.dll"), maxBytes: 1024) == expected)
        #expect(try LaunchJournal(paths: configuration.paths).read(game: "starrail") == nil)
        #expect(try fs.contentsOfRootDirectory().allSatisfy { !$0.description.contains(".macgacha-hidden-") })
    }
}
private func assertRecoveryCopy(_ configuration: ProbeLaunchConfiguration, sessionID: UUID) async throws {
    let notices = try await readNotices(configuration)
    let notice = try #require(notices.first { $0.id == sessionID })
    #expect(notice.game == "starrail")
    let copy = try #require(notice.movedTo.first)
    try await BlockingIO.run {
        let fs = try ContainedFileSystem(root: copy.deletingLastPathComponent())
        let bytes = try fs.readFile(at: SafeRelativePath(copy.lastPathComponent), maxBytes: 1024)
        #expect(bytes == originalDLL)
    }
}
private func readNotices(_ configuration: ProbeLaunchConfiguration) async throws -> [RecoveryNotice] {
    try await BlockingIO.run { try RecoveryNoticeStore(paths: configuration.paths).load() }
}
private func assertBlocked(port: UInt16) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Int(port)]
    configuration.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(from: URL(string: "http://blocked.test/")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 403)
}
private func assertClosed(_ port: UInt16) async throws {
    try await BlockingIO.run {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LauncherError.io("Opening proxy test socket") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(result == -1 && errno == ECONNREFUSED)
    }
}

/// Fixture reads retain the production component size/hash checks and never use the network.
private struct ProbeFixtureHTTP: HTTPClient {
    let root: URL
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (DownloadEngine.HTTPResponseHead, HTTPBody) {
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: root), path = try SafeRelativePath(url.lastPathComponent)
            let size = try #require(try fs.size(at: path)), handle = try fs.openForReading(at: path)
            try handle.seek(toOffset: UInt64(offset ?? 0))
            let reader = ProbeFixtureReader(handle)
            return (DownloadEngine.HTTPResponseHead(status: offset == nil ? 200 : 206, contentLength: size - (offset ?? 0)),
                HTTPBody(next: { try await reader.next() }, onCancel: {}))
        }
    }
}
private actor ProbeFixtureReader {
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
