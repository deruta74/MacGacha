// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
@testable import MacGacha

@Suite(.serialized)
@MainActor
struct LiveRuntimeServicesTests {
    @Test func everyRuntimeErrorUsesOnlyFixedMessagesAndApprovedFields() {
        let payload = "https://example.invalid/private?cursor=planted-query"
        let errors: [(LauncherError, String)] = [
            (.unsafePath(payload), "unsafePath"), (.invalidDigest(payload), "invalidDigest"),
            (.sizeMismatch(path: payload, expected: 42, actual: 3), "sizeMismatch"),
            (.digestMismatch(path: payload, expected: payload, actual: payload), "digestMismatch"),
            (.insufficientSpace(required: 42, available: 3), "insufficientSpace"),
            (.http(status: 503, url: URL(string: payload)!), "http"),
            (.transport(payload), "transport"), (.io(payload), "io"), (.busy(payload), "busy"),
            (.fileTooLarge(path: payload, limit: 42), "fileTooLarge"),
            (.consentRequired(payload), "consentRequired"),
            (.processFailed(executable: payload, exitCode: 3, stderrTail: payload), "processFailed"),
            (.cancelled, "cancelled"), (.journalCorrupt(payload), "journalCorrupt")
        ]
        let allowed = Set(["case", "host", "status", "expectedSize", "actualSize", "required", "available", "limit", "exitCode"])
        for (error, name) in errors {
            let entry = RuntimeErrorLog(error)
            #expect(entry.message == (error == .cancelled ? "Runtime operation cancelled" : "Runtime operation failed"))
            #expect(entry.metadata["case"] == name)
            #expect(Set(entry.metadata.keys).isSubset(of: allowed))
            let text = entry.message + entry.metadata.values.joined()
            for forbidden in ["https://", "/private", "planted-query"] { #expect(!text.contains(forbidden)) }
            if case .http = error {
                #expect(entry.metadata["host"] == "example.invalid" && entry.metadata["status"] == "503")
            } else { #expect(!text.contains("example.invalid")) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func liveBundleCancellationJoinsCleanupBeforeReadinessAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("x86_64-windows"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: payload.appendingPathComponent("bin/wine"))
        try Data("dxmt".utf8).write(to: payload.appendingPathComponent("x86_64-windows/d3d11.dll"))
        let archive = root.appendingPathComponent("fixture.tar")
        let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cf", archive.path, "-C", root.path, "payload"],
            environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 0)
        let bytes = try Data(contentsOf: archive)
        let http = CleanupHeldHTTP(bytes: bytes)
        let live = LiveRuntimeServices(paths: AppPaths(root: root.appendingPathComponent("app")), http: http,
            retry: RetryPolicy(maxAttempts: 1))
        let manifest = try liveBundleManifest(version: "1", bytes: bytes)
        let bundle = manifest.bundles[0]
        for try await _ in live.install(bundle, manifest: manifest, from: nil) { }
        #expect(try await live.scanBundles(manifest)[bundle.id.rawValue] != nil)
        let update = try liveBundleManifest(version: "2", bytes: bytes)
        let finished = Mutex(false)
        let consumer = Task {
            defer { finished.withLock { $0 = true } }
            do {
                for try await _ in live.install(update.bundles[0], manifest: update, from: nil) {
                    try Task.checkCancellation()
                }
                throw LauncherError.io("Cancelled stream ended successfully")
            } catch {
                // This is the model's cancellation refresh: it must see the old bundle,
                // never a busy lease that the model could mistake for empty readiness.
                let ready = try await Task.detached { try await live.scanBundles(manifest) }.value
                #expect(ready[bundle.id.rawValue] != nil)
                throw launcherError(error)
            }
        }
        await http.started.wait()
        consumer.cancel()
        await http.cancelled.wait()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.withLock { $0 })
        await http.release.open()
        await #expect(throws: LauncherError.cancelled) { try await consumer.value }
        for try await _ in live.install(bundle, manifest: manifest, from: nil) { }
        #expect(try await live.scanBundles(manifest)[bundle.id.rawValue] != nil)
    }

    @Test func liveDiagnosticsReadGlobalSessionLogsPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaLogsOff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try await BlockingIO.run { try GlobalLaunchSettingsStore(paths: paths).save(GlobalLaunchSettings(sessionLogsEnabled: false)) }
        let bundle = try await LiveRuntimeServices(paths: paths, http: FailedHTTP()).makeDiagnosticBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", bundle.path, "session-logs.txt"], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "session logs disabled\n")
    }

    @Test(arguments: ["symlink", "unreadable"], [false, true])
    func liveDiagnosticsSkipFailedGameLogDiscovery(failure: String, directExport: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaDiscovery-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        let unreadable = paths.prefixes.appendingPathComponent("genshin-fixture/drive_c/users")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: root)
        }
        try await BlockingIO.run {
            if failure == "symlink" {
                let target = root.appendingPathComponent("private-token=planted-secret")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: paths.prefixes, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
            }
            // Ensure the fixture actually exercises the discovery failure, rather than
            // relying on an absent log or a permission change ignored by the OS.
            #expect(throws: (any Error).self) { try LaunchLogFiles.gameLogCandidates(in: paths.prefixes) }
        }
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP())
        let bundle: URL
        if directExport {
            bundle = root.appendingPathComponent("diagnostics.zip")
            try await live.exportDiagnostics(to: bundle)
        } else {
            bundle = try await live.makeDiagnosticBundle()
        }
        defer { try? FileManager.default.removeItem(at: bundle) }
        let check = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-tq", bundle.path], environment: [:], currentDirectory: nil)
        #expect(check.exitCode == 0)
        let report = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", bundle.path, "skipped.txt"], environment: [:], currentDirectory: nil)
        #expect(report.exitCode == 0)
        let text = String(decoding: report.stdout, as: UTF8.self)
        #expect(text.contains("discovery unavailable: \"game logs\""))
        for forbidden in [root.path, "planted-secret", "private-token", "drive_c"] {
            #expect(!text.contains(forbidden))
        }
    }

    @Test(arguments: [false, true])
    func liveDiagnosticsSkipSymlinkedLogsRoot(directExport: Bool) async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaForeignLogs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let paths = AppPaths(root: fixture.appendingPathComponent("app"))
        try await BlockingIO.run {
            let foreign = fixture.appendingPathComponent("foreign")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            var event = try JSONSerialization.data(withJSONObject: ["ts": "2026-10-20T12:00:00Z", "level": "info",
                "category": "test", "message": "foreign-event-must-stay-out", "metadata": [:]])
            event.append(10)
            #expect(try JSONDecoder().decode(EventLog.Record.self, from: event).message == "foreign-event-must-stay-out")
            try event.write(to: foreign.appendingPathComponent("macgacha.log"))
            try FileManager.default.createSymbolicLink(at: paths.logs, withDestinationURL: foreign)
        }
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP())
        let bundle: URL
        if directExport {
            bundle = fixture.appendingPathComponent("diagnostics.zip")
            try await live.exportDiagnostics(to: bundle)
        } else {
            bundle = try await live.makeDiagnosticBundle()
        }
        defer { try? FileManager.default.removeItem(at: bundle) }
        let listing = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", bundle.path], environment: [:], currentDirectory: nil)
        #expect(listing.exitCode == 0)
        #expect(!String(decoding: listing.stdout, as: UTF8.self).contains("logs/macgacha.log"))
        let contents = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", bundle.path], environment: [:], currentDirectory: nil)
        #expect(contents.exitCode == 0)
        #expect(!String(decoding: contents.stdout, as: UTF8.self).contains("foreign-event-must-stay-out"))
        let report = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", bundle.path, "skipped.txt"], environment: [:], currentDirectory: nil)
        #expect(report.exitCode == 0)
        let text = String(decoding: report.stdout, as: UTF8.self)
        #expect(text.contains("unsafe or unavailable log directory"))
        #expect(!text.contains(fixture.path))
    }

    @Test(arguments: [false, true])
    func liveDiagnosticsPreserveCancellationWithUnsafeDiscovery(directExport: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaCancelledDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try await BlockingIO.run {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: paths.prefixes, withDestinationURL: root)
        }
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if directExport {
                try await live.exportDiagnostics(to: root.appendingPathComponent("cancelled.zip"))
            } else {
                _ = try await live.makeDiagnosticBundle()
            }
        }
        await #expect(throws: LauncherError.cancelled) { try await task.value }
    }

    @Test func liveDiagnosticBundleIsACompleteTemporaryZip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaBundleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let live = LiveRuntimeServices(paths: AppPaths(root: root), http: FailedHTTP())
        let bundle = try await live.makeDiagnosticBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(bundle.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
        let result = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-tq", bundle.path], environment: [:], currentDirectory: nil)
        #expect(result.exitCode == 0)
    }

    @Test(arguments: [LauncherError.transport("request https://example.invalid/private?cursor=planted-query token=planted-secret"),
        LauncherError.io("write https://example.invalid/private?cursor=planted-query token=planted-secret")])
    func liveFailureIsLoggedAndUserMessageHidesPayloads(error: LauncherError) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaLiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP(error: error), retry: RetryPolicy(maxAttempts: 1), sleeper: NoWaitSleeper())
        let component = try RuntimeComponent(id: SafeIdentifier("wine-1.0"), kind: .wine, version: SafeIdentifier("1.0"), sourceMode: .download,
            url: URL(string: "https://example.invalid/archive"), size: 1, installedSize: 1,
            sha256: Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64)), archive: .tarXZ,
            license: ComponentLicense(name: "Test", url: URL(string: "https://example.invalid/license")!, redistributable: true, termsRevision: "1"))
        let model = AppModel(paths: paths, manifest: try RuntimeManifest(components: [component]), services: live, defaults: nil)
        await model.start()
        model.install(component.id.rawValue)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.lastError == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.lastError != nil)
        #expect(model.lastError == error.userMessage)
        let logs = await live.recentLogLines(limit: 200)
        #expect(logs.contains { $0.contains(error == .transport("request https://example.invalid/private?cursor=planted-query token=planted-secret") ? "transport" : "io") })
        #expect(!logs.joined().contains("planted-secret"))
        // Check the on-disk record too; tail presentation/redaction must not mask a leak.
        let raw = try String(contentsOf: paths.logs.appendingPathComponent("macgacha.log"), encoding: .utf8)
        for forbidden in ["https://", "example.invalid", "/private", "planted-query", "planted-secret"] {
            #expect(!raw.contains(forbidden))
        }
    }

    @Test func recentLogsAreLimitedToTailAndLineCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaTailTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let prefix = String(repeating: "x", count: 300_000) + "\n"
        let tail = (0..<300).map { "safe-line-\($0)" }.joined(separator: "\n") + "\n"
        try Data((prefix + tail).utf8).write(to: paths.logs.appendingPathComponent("macgacha.log"))
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP())
        let lines = await live.recentLogLines(limit: 1000)
        #expect(lines.count == 200)
        #expect(lines.first == "safe-line-100" && lines.last == "safe-line-299")
        #expect(await live.recentLogLines(limit: 0).isEmpty)
    }

    @Test func bundledCreditsRetainOriginAndLicense() throws {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("HYPERLINK \"https://github.com/deruta74/MacGacha\""))
        #expect(text.contains("GNU General Public License v3.0"))
    }
}

private struct FailedHTTP: HTTPClient {
    var error = LauncherError.transport("connection failed token=planted-secret")
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        #expect(!onMainThread())
        throw error
    }
}

private struct NoWaitSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { if Task.isCancelled { throw LauncherError.cancelled } }
}

private func onMainThread() -> Bool { Thread.isMainThread }

private actor LiveTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

private final class CleanupHeldHTTP: HTTPClient, Sendable {
    let bytes: Data
    let started = LiveTestGate(), cancelled = LiveTestGate(), release = LiveTestGate()
    init(bytes: Data) { self.bytes = bytes }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        if url.lastPathComponent.hasSuffix("-2") {
            await started.open()
            await withTaskCancellationHandler {
                await release.wait() // Deliberately hold HTTP cleanup after cancellation.
            } onCancel: { Task { await self.cancelled.open() } }
            throw LauncherError.cancelled
        }
        let remaining = Mutex<Data?>(bytes)
        return (HTTPResponseHead(status: 200, contentLength: Int64(bytes.count)),
            HTTPBody(next: { remaining.withLock { value in let data = value; value = nil; return data } }))
    }
}

private func liveBundleManifest(version: String, bytes: Data) throws -> RuntimeManifest {
    var hasher = StreamingHasher(.sha256); hasher.update(bytes); let digest = hasher.finalize()
    let components = try [ComponentKind.wine, .dxmt].map { kind in
        try RuntimeComponent(id: SafeIdentifier("\(kind.rawValue)-\(version)"), kind: kind,
            version: SafeIdentifier(version), sourceMode: .download,
            url: URL(string: "https://fixtures.invalid/\(kind.rawValue)-\(version)"),
            size: Int64(bytes.count), installedSize: 1024, sha256: digest, archive: .tarGZ,
            license: ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!,
                redistributable: true, termsRevision: "1"),
            rootPath: SafeRelativePath("payload"), wineBinary: kind == .wine ? SafeRelativePath("bin/wine") : nil,
            overlay: kind == .dxmt ? [RuntimeOverlay(source: SafeRelativePath("x86_64-windows"),
                destination: SafeRelativePath("lib/wine/x86_64-windows"))] : [])
    }
    let bundle = try RuntimeBundle(id: SafeIdentifier("test-dxmt"), displayName: "DXMT", backend: .dxmt,
        components: components.map(\.id))
    return try RuntimeManifest(components: components, bundles: [bundle])
}
