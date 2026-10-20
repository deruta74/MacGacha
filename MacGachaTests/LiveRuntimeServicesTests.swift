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
    @Test func liveFailureIsLoggedAndUserMessageHidesPayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacGachaLiveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let live = LiveRuntimeServices(paths: paths, http: FailedHTTP(), retry: RetryPolicy(maxAttempts: 1), sleeper: NoWaitSleeper())
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
        #expect(model.lastError == LauncherError.transport("").userMessage)
        let logs = await live.recentLogLines(limit: 200)
        #expect(logs.contains { $0.contains("transport") })
        #expect(!logs.joined().contains("planted-secret"))
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
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        #expect(!onMainThread())
        throw LauncherError.transport("connection failed token=planted-secret")
    }
}

private struct NoWaitSleeper: Sleeper {
    func sleep(for duration: Duration) async throws { if Task.isCancelled { throw LauncherError.cancelled } }
}

private func onMainThread() -> Bool { Thread.isMainThread }
