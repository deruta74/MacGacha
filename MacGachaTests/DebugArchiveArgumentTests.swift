// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
@testable import MacGacha

@Suite @MainActor struct DebugArchiveArgumentTests {
    @Test func archiveDirectoryRequiresAbsoluteArgumentAndIsIgnoredInRelease() {
        let arguments = ["MacGacha", "-MacGachaDebugArchiveDirectory", "/tmp/runtime-archives"]
        #if DEBUG
        #expect(LiveRuntimeServices.debugArchiveDirectoryURL(arguments: arguments)?.path == "/tmp/runtime-archives")
        #else
        #expect(LiveRuntimeServices.debugArchiveDirectoryURL(arguments: arguments) == nil)
        #endif
        #expect(LiveRuntimeServices.debugArchiveDirectoryURL(arguments: []) == nil)
        #expect(LiveRuntimeServices.debugArchiveDirectoryURL(arguments: ["-MacGachaDebugArchiveDirectory"]) == nil)
        #expect(LiveRuntimeServices.debugArchiveDirectoryURL(arguments: ["-MacGachaDebugArchiveDirectory", "relative"]) == nil)
    }

    #if DEBUG
    @Test func liveServicesApplyArchiveArgumentBeforeAnyNetworkRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("debug-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archives = root.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try Data("tampered".utf8).write(to: archives.appendingPathComponent("component.zip"))
        var hash = StreamingHasher(.sha256); hash.update(Data("expected".utf8))
        let component = try RuntimeComponent(id: SafeIdentifier("surround-audio-debug-test"), kind: .surroundAudio,
            version: SafeIdentifier("debug-test"), sourceMode: .download, url: URL(string: "https://fixtures.invalid/component.zip"),
            size: 8, installedSize: 1024, sha256: hash.finalize(), archive: .zip,
            license: ComponentLicense(name: "Fixture", url: URL(string: "https://fixtures.invalid/license")!, redistributable: true, termsRevision: "1"))
        let network = DebugArchiveUnexpectedNetwork()
        let live = LiveRuntimeServices(paths: AppPaths(root: root.appendingPathComponent("app")), http: network,
            retry: RetryPolicy(maxAttempts: 1), arguments: ["MacGacha", "-MacGachaDebugArchiveDirectory", archives.path])
        do {
            for try await _ in live.install(component, from: nil) { }
            Issue.record("Mismatched local archive was installed")
        } catch {
            #expect(launcherError(error).logCase == "digestMismatch")
        }
        #expect(network.requests.withLock { $0 } == 0)
        #expect(try await live.scan().components.isEmpty)
    }
    #endif
}

#if DEBUG
private final class DebugArchiveUnexpectedNetwork: HTTPClient, Sendable {
    let requests = Mutex(0)
    func post(_ url: URL) async throws -> (HTTPResponseHead, HTTPBody) { throw LauncherError.io("Unexpected POST") }
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        requests.withLock { $0 += 1 }
        throw LauncherError.transport("Unexpected runtime network request")
    }
}
#endif
