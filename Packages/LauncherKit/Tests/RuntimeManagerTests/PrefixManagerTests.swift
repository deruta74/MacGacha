// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport

@Test
func prefixCreationRunsWinebootOnce() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url.appendingPathComponent("Application Support"))
    let fs = try ContainedFileSystem(root: paths.root); let wine = try prefixTestWine(paths)
    let marker = try prefixTestMarker("genshin", .dxmt)
    let runner = FakeProcessRunner { invocation in
        #expect(try fs.itemType(at: marker) == nil)
        try fs.writeAtomically(Data("registry".utf8), to: SafeRelativePath("Prefixes/genshin-dxmt/system.reg"))
        #expect(invocation.arguments == ["wineboot", "--init"])
        return prefixTestSuccess()
    }
    let manager = PrefixManager(paths: paths, runner: runner)
    let before = Date().addingTimeInterval(-1)
    let url = try await manager.createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
    #expect(url == (try manager.prefixURL(game: "genshin", backend: .dxmt)))
    #expect(url.path == paths.prefixes.appendingPathComponent("genshin-dxmt").path)
    let call = try #require(runner.invocations.first)
    #expect(call.executable == wine)
    #expect(call.environment == ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d"])
    #expect(call.currentDirectory == nil)
    let json = try prefixTestJSON(fs, marker)
    #expect(json["schemaVersion"] as? Int == 1)
    #expect(json["backend"] as? String == "dxmt")
    #expect(json["wineBinaryPath"] as? String == wine.path)
    let identity = try #require(json["wineBinaryIdentity"] as? [String: String])
    #expect(identity == ["algorithm": "sha256", "hex": "9113a829a33711e589fe9a23b01aaadafc6943f331616b99cecf53a659192e58"])
    let dateText = try #require(json["createdAt"] as? String)
    let created = try #require(ISO8601DateFormatter().date(from: dateText))
    #expect(created >= before && created <= Date().addingTimeInterval(1))
    // A valid marker is sufficient even if system.reg is absent, across manager instances.
    try fs.removeFile(at: SafeRelativePath("Prefixes/genshin-dxmt/system.reg"))
    let again = try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
    #expect(again == url); #expect(runner.invocations.count == 1)
}

@Test
func failedWinebootLeavesNoMarkerAndRetryRunsAgain() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let calls = Mutex(0)
    let runner = FakeProcessRunner { _ in
        try fs.writeAtomically(Data("partial".utf8), to: SafeRelativePath("Prefixes/starrail-d3dmetal/system.reg"))
        let first = calls.withLock { $0 += 1; return $0 == 1 }
        return first ? ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("wineboot failed".utf8)) : prefixTestSuccess()
    }
    let manager = PrefixManager(paths: paths, runner: runner)
    await #expect(throws: LauncherError.processFailed(executable: wine.path, exitCode: 7, stderrTail: "wineboot failed")) {
        try await manager.createPrefix(game: "starrail", backend: .d3dmetal, wineBinary: wine)
    }
    #expect(try fs.itemType(at: prefixTestMarker("starrail", .d3dmetal)) == nil)
    _ = try await manager.createPrefix(game: "starrail", backend: .d3dmetal, wineBinary: wine)
    #expect(runner.invocations.count == 2)
    #expect(try fs.itemType(at: prefixTestMarker("starrail", .d3dmetal)) == .regularFile)
}

@Test(arguments: [Optional<Data>.none, Data("broken".utf8), Data("{}".utf8), Data()])
func halfCreatedPrefixWithoutValidMarkerIsReinitialized(markerBytes: Data?) async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let marker = try prefixTestMarker("zenless", .dxmt)
    try fs.writeAtomically(Data("partial registry".utf8), to: SafeRelativePath("Prefixes/zenless-dxmt/system.reg"))
    if let markerBytes { try fs.writeAtomically(markerBytes, to: marker) }
    let runner = FakeProcessRunner { _ async throws in
        #expect(try fs.itemType(at: marker) == nil)
        return prefixTestSuccess()
    }
    _ = try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "zenless", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["schemaVersion"] as? Int == 1)
}

@Test
func prefixCancellationPropagatesAndReleasesLock() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let started = Mutex(false); let cancelled = Mutex(false)
    let runner = FakeProcessRunner { _ in
        started.withLock { $0 = true }
        do { try await Task.sleep(for: .seconds(30)); return prefixTestSuccess() }
        catch { cancelled.withLock { $0 = true }; throw error }
    }
    let task = Task { try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "cancel", backend: .dxmt, wineBinary: wine) }
    defer { task.cancel() }
    try await prefixTestWait { started.withLock { $0 } }
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(cancelled.withLock { $0 })
    #expect(try fs.itemType(at: prefixTestMarker("cancel", .dxmt)) == nil)
    let retry = Task { try await PrefixManager(paths: paths, runner: FakeProcessRunner()).createPrefix(game: "cancel", backend: .dxmt, wineBinary: wine) }
    let watchdog = Task { try await Task.sleep(for: .seconds(5)); retry.cancel() }
    defer { watchdog.cancel(); retry.cancel() }
    _ = try await retry.value
}

@Test(arguments: ["", "../genshin", "a/b", ".hidden", "a\\b", "white space", String(repeating: "a", count: 129)])
func prefixInvalidGameIdentifiersAreRejected(game: String) async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let runner = FakeProcessRunner()
    let manager = PrefixManager(paths: paths, runner: runner)
    #expect(throws: LauncherError.unsafePath(game)) { try manager.prefixURL(game: game, backend: .dxmt) }
    await #expect(throws: LauncherError.unsafePath(game)) {
        try await manager.createPrefix(game: game, backend: .dxmt, wineBinary: URL(fileURLWithPath: "/missing/wine"))
    }
    #expect(runner.invocations.isEmpty)
    #expect(try ContainedFileSystem(root: paths.root).itemType(at: SafeRelativePath("Prefixes")) == nil)
}

@Test(arguments: [false, true])
func symlinkedPrefixesAncestorIsRejected(prefixLeaf: Bool) async throws {
    let temp = try TempDir(); let outside = try TempDir(); let paths = AppPaths(root: temp.url)
    let fs = try ContainedFileSystem(root: paths.root); let wine = try prefixTestWine(paths)
    let link = prefixLeaf ? paths.prefixes.appendingPathComponent("genshin-dxmt") : paths.prefixes
    if prefixLeaf { try fs.createDirectory(at: SafeRelativePath("Prefixes")) }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
    let runner = FakeProcessRunner()
    await #expect(throws: LauncherError.unsafePath(link.path)) {
        try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
    }
    #expect(runner.invocations.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
}

@Test
func concurrentPrefixCallsRunWinebootOnce() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let wine = try prefixTestWine(paths)
    let started = Mutex(false); let released = Mutex(false)
    let runner = FakeProcessRunner { _ in
        started.withLock { $0 = true }
        while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        return prefixTestSuccess()
    }
    let first = Task { try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "shared", backend: .dxmt, wineBinary: wine) }
    defer { released.withLock { $0 = true }; first.cancel() }
    try await prefixTestWait { started.withLock { $0 } }
    let second = Task { try await PrefixManager(paths: paths, runner: runner).createPrefix(game: "shared", backend: .dxmt, wineBinary: wine) }
    defer { second.cancel() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(runner.invocations.count == 1)
    released.withLock { $0 = true }
    let watchdog = Task { try await Task.sleep(for: .seconds(5)); first.cancel(); second.cancel() }
    defer { watchdog.cancel() }
    let firstURL = try await first.value; let secondURL = try await second.value
    #expect(firstURL == secondURL)
    #expect(runner.invocations.count == 1)
}

@Test
func prefixMarkerForDifferentBackendIsAnError() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner)
    _ = try await manager.createPrefix(game: "backend", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("backend", .dxmt); var json = try prefixTestJSON(fs, marker)
    json["backend"] = "d3dmetal"; try fs.writeAtomically(JSONSerialization.data(withJSONObject: json), to: marker)
    await #expect(throws: LauncherError.io("Prefix backend mismatch")) {
        try await manager.createPrefix(game: "backend", backend: .dxmt, wineBinary: wine)
    }
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["backend"] as? String == "d3dmetal")
}

@Test
func prefixWineIdentityChangesReinitialize() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner)
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("upgrade", .dxmt)
    let oldIdentity = try #require(prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String])
    _ = try prefixTestWine(paths, body: "wine-v2")
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 2)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] != oldIdentity)
    let nextWine = try prefixTestWine(paths, version: "2.0", body: "wine-v2")
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: nextWine)
    #expect(runner.invocations.count == 3)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == nextWine.path)
}

@Test
func invalidPrefixMarkerSchemaReinitializes() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner)
    _ = try await manager.createPrefix(game: "schema", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("schema", .dxmt); var json = try prefixTestJSON(fs, marker)
    json["schemaVersion"] = 99; try fs.writeAtomically(JSONSerialization.data(withJSONObject: json), to: marker)
    _ = try await manager.createPrefix(game: "schema", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 2)
    #expect(try prefixTestJSON(fs, marker)["schemaVersion"] as? Int == 1)
}

private func prefixTestWine(_ paths: AppPaths, version: String = "1.0", body: String = "wine-v1") throws -> URL {
    let path = try SafeRelativePath("Runtimes/wine/\(version)/bin/wine")
    try ContainedFileSystem(root: paths.root).writeAtomically(Data(body.utf8), to: path)
    return path.resolved(against: paths.root)
}
private func prefixTestMarker(_ game: String, _ backend: ComponentKind) throws -> SafeRelativePath {
    try SafeRelativePath("Prefixes/\(game)-\(backend.rawValue)/.macgacha-prefix.json")
}
private func prefixTestJSON(_ fs: ContainedFileSystem, _ path: SafeRelativePath) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: fs.readFile(at: path, maxBytes: 16_384)) as? [String: Any])
}
private func prefixTestSuccess() -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
private func prefixTestWait(_ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
    while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition())
}
