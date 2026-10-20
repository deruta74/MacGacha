// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
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
