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
    let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
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
    #expect(json["game"] as? String == "genshin")
    #expect(json["backend"] as? String == "dxmt")
    #expect(json["state"] as? String == "ready")
    #expect(json["wineBinaryPath"] as? String == wine.path)
    let identity = try #require(json["wineBinaryIdentity"] as? [String: String])
    #expect(identity == ["algorithm": "sha256", "hex": "9113a829a33711e589fe9a23b01aaadafc6943f331616b99cecf53a659192e58"])
    let dateText = try #require(json["createdAt"] as? String)
    let created = try #require(ISO8601DateFormatter().date(from: dateText))
    #expect(created >= before && created <= Date().addingTimeInterval(1))
    // A valid marker is sufficient even if system.reg is absent, across manager instances.
    try fs.removeFile(at: SafeRelativePath("Prefixes/genshin-dxmt/system.reg"))
    let again = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
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
    let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
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
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "zenless", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["schemaVersion"] as? Int == 1)
}

@Test(arguments: ["missing", "malformed", "symlink", "directory"])
func incompletePrefixSymlinksAreRemovedBeforeWineboot(markerShape: String) async throws {
    let temp = try TempDir(); let outside = try TempDir(); let paths = AppPaths(root: temp.url)
    let fs = try ContainedFileSystem(root: paths.root); let wine = try prefixTestWine(paths)
    let prefix = try SafeRelativePath("Prefixes/unsafe-dxmt")
    let url = prefix.resolved(against: paths.root)
    let windows = outside.url.appendingPathComponent("windows", isDirectory: true)
    let outsideSystem = windows.appendingPathComponent("system.ini")
    let outsideRegistry = outside.url.appendingPathComponent("user.reg")
    try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: false)
    let originalSystem = Data("outside system settings".utf8)
    let originalRegistry = Data("outside registry".utf8)
    try originalSystem.write(to: outsideSystem); try originalRegistry.write(to: outsideRegistry)
    try fs.createDirectory(at: SafeRelativePath("Prefixes/unsafe-dxmt/drive_c"))
    try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("drive_c/windows"), withDestinationURL: windows)
    try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("user.reg"), withDestinationURL: outsideRegistry)
    let marker = try prefixTestMarker("unsafe", .dxmt)
    switch markerShape {
    case "malformed": try fs.writeAtomically(Data("{}".utf8), to: marker)
    case "symlink": try FileManager.default.createSymbolicLink(at: marker.resolved(against: paths.root), withDestinationURL: outsideRegistry)
    case "directory": try fs.createDirectory(at: marker)
    default: break
    }
    let targets = [outside.url, windows, outsideSystem, outsideRegistry]
    for target in targets {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 946_684_800)], ofItemAtPath: target.path)
    }
    let mtimes = try targets.map(prefixTestModificationDate)
    let runner = FakeProcessRunner { _ async throws in
        #expect(try fs.contentsOfDirectory(at: prefix).isEmpty)
        // Simulate Wine's ordinary path-based writes, which would follow stale links.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
        try Data("new system settings".utf8).write(to: url.appendingPathComponent("drive_c/windows/system.ini"))
        try Data("new registry".utf8).write(to: url.appendingPathComponent("user.reg"))
        return prefixTestSuccess()
    }
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "unsafe", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try Data(contentsOf: outsideSystem) == originalSystem)
    #expect(try Data(contentsOf: outsideRegistry) == originalRegistry)
    #expect(try targets.map(prefixTestModificationDate) == mtimes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: windows.path) == ["system.ini"])
    #expect(try fs.itemType(at: SafeRelativePath("Prefixes/unsafe-dxmt/drive_c/windows")) == .directory)
    #expect(try fs.itemType(at: SafeRelativePath("Prefixes/unsafe-dxmt/user.reg")) == .regularFile)
    #expect(try prefixTestJSON(fs, marker)["schemaVersion"] as? Int == 1)
}

@Test
func readyPrefixKeepsItsFilesAndWineLinksUntouched() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
    let url = try await manager.createPrefix(game: "ready", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("ready", .dxmt)
    try fs.writeAtomically(Data("saved game".utf8), to: SafeRelativePath("Prefixes/ready-dxmt/drive_c/game/save.dat"))
    try fs.writeAtomically(Data("user registry".utf8), to: SafeRelativePath("Prefixes/ready-dxmt/user.reg"))
    try fs.createDirectory(at: SafeRelativePath("Prefixes/ready-dxmt/dosdevices"))
    let wineLink = url.appendingPathComponent("dosdevices/c:")
    try FileManager.default.createSymbolicLink(atPath: wineLink.path, withDestinationPath: "../drive_c")
    let markerBytes = try fs.readFile(at: marker, maxBytes: 16_384)
    let preserved = [url, marker.resolved(against: paths.root), url.appendingPathComponent("drive_c/game/save.dat"), url.appendingPathComponent("user.reg")]
    for path in preserved {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 946_684_800)], ofItemAtPath: path.path)
    }
    let mtimes = try preserved.map(prefixTestModificationDate)
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "ready", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try fs.readFile(at: marker, maxBytes: 16_384) == markerBytes)
    #expect(try fs.readFile(at: SafeRelativePath("Prefixes/ready-dxmt/drive_c/game/save.dat"), maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: SafeRelativePath("Prefixes/ready-dxmt/user.reg"), maxBytes: 64) == Data("user registry".utf8))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: wineLink.path) == "../drive_c")
    #expect(try preserved.map(prefixTestModificationDate) == mtimes)
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
    let task = Task { try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "cancel", backend: .dxmt, wineBinary: wine) }
    defer { task.cancel() }
    try await prefixTestWait { started.withLock { $0 } }
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(cancelled.withLock { $0 })
    #expect(try fs.itemType(at: prefixTestMarker("cancel", .dxmt)) == nil)
    let retry = Task { try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "cancel", backend: .dxmt, wineBinary: wine) }
    let watchdog = Task { try await Task.sleep(for: .seconds(5)); retry.cancel() }
    defer { watchdog.cancel(); retry.cancel() }
    _ = try await retry.value
}

@Test(arguments: ["", "../genshin", "a/b", ".hidden", "a\\b", "white space", String(repeating: "a", count: 129)])
func prefixInvalidGameIdentifiersAreRejected(game: String) async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let runner = FakeProcessRunner()
    let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
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
        try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
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
    let first = Task { try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "shared", backend: .dxmt, wineBinary: wine) }
    defer { released.withLock { $0 = true }; first.cancel() }
    try await prefixTestWait { started.withLock { $0 } }
    let second = Task { try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "shared", backend: .dxmt, wineBinary: wine) }
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

@Test(arguments: ["game", "backend"])
func prefixMarkerForDifferentGameOrBackendIsAnError(field: String) async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
    _ = try await manager.createPrefix(game: "backend", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("backend", .dxmt); var json = try prefixTestJSON(fs, marker)
    json[field] = "different"; try fs.writeAtomically(JSONSerialization.data(withJSONObject: json), to: marker)
    let error = LauncherError.io(field == "backend" ? "Prefix backend mismatch" : "Prefix game mismatch")
    await #expect(throws: error) {
        try await manager.createPrefix(game: "backend", backend: .dxmt, wineBinary: wine)
    }
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)[field] as? String == "different")
}

@Test
func prefixWineIdentityChangesUpgradeInPlace() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths)
    let url = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "upgrade", backend: .dxmt, wineBinary: wine)
    let save = try SafeRelativePath("Prefixes/upgrade-dxmt/drive_c/users/player/save.dat")
    let registry = try SafeRelativePath("Prefixes/upgrade-dxmt/user.reg")
    try fs.writeAtomically(Data("saved game".utf8), to: save)
    try fs.writeAtomically(Data("user settings".utf8), to: registry)
    let marker = try prefixTestMarker("upgrade", .dxmt)
    let oldIdentity = try #require(prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String])
    let createdAt = try #require(prefixTestJSON(fs, marker)["createdAt"] as? String)
    let runner = FakeProcessRunner { invocation async throws in
        #expect(invocation.arguments == ["wineboot", "-u"])
        #expect(invocation.environment == ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d"])
        #expect(invocation.currentDirectory == nil)
        #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
        #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("user settings".utf8))
        #expect(try fs.itemType(at: marker) == .regularFile)
        #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
        #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == invocation.executable.path)
        return prefixTestSuccess()
    }
    let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
    _ = try prefixTestWine(paths, body: "wine-v2")
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(runner.invocations.first?.executable == wine)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] != oldIdentity)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "ready")
    #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == wine.path)
    let updatedIdentity = try #require(prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String])
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("user settings".utf8))
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    let nextWine = try prefixTestWine(paths, version: "2.0", body: "wine-v2")
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: nextWine)
    #expect(runner.invocations.count == 2)
    #expect(runner.invocations.last?.executable == nextWine)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == nextWine.path)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] == updatedIdentity)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "ready")
    #expect(try prefixTestJSON(fs, marker)["createdAt"] as? String == createdAt)
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("user settings".utf8))
    // Both updated markers establish readiness on the next request.
    _ = try await manager.createPrefix(game: "upgrade", backend: .dxmt, wineBinary: nextWine)
    #expect(runner.invocations.count == 2)
}

@Test(arguments: [false, true])
func failedPrefixUpgradeIsRetriedWithOldRuntimeAndPreservesData(changedPath: Bool) async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths)
    let url = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "failed-upgrade", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("failed-upgrade", .dxmt)
    let oldIdentity = try #require(prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String])
    let createdAt = try #require(prefixTestJSON(fs, marker)["createdAt"] as? String)
    let save = try SafeRelativePath("Prefixes/failed-upgrade-dxmt/drive_c/users/player/save.dat")
    let registry = try SafeRelativePath("Prefixes/failed-upgrade-dxmt/user.reg")
    try fs.writeAtomically(Data("saved game".utf8), to: save)
    try fs.writeAtomically(Data("user settings".utf8), to: registry)
    let nextWine = try prefixTestWine(paths, version: changedPath ? "2.0" : "1.0", body: "wine-v2")
    let upgradingBytes = Mutex<Data?>(nil)
    let runner = FakeProcessRunner { invocation async throws in
        #expect(invocation.arguments == ["wineboot", "-u"])
        #expect(invocation.environment == ["WINEPREFIX": url.path, "WINEDEBUG": "-all", "WINEDLLOVERRIDES": "winemenubuilder.exe=d"])
        let json = try prefixTestJSON(fs, marker)
        #expect(json["state"] as? String == "upgrading")
        #expect(json["game"] as? String == "failed-upgrade")
        #expect(json["backend"] as? String == "dxmt")
        #expect(json["wineBinaryPath"] as? String == nextWine.path)
        #expect(json["wineBinaryIdentity"] as? [String: String] != oldIdentity)
        let data = try fs.readFile(at: marker, maxBytes: 16_384)
        upgradingBytes.withLock { $0 = data }
        #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
        #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("user settings".utf8))
        try fs.writeAtomically(Data("partially upgraded settings".utf8), to: registry)
        return ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("upgrade failed".utf8))
    }
    let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
    await #expect(throws: LauncherError.processFailed(executable: nextWine.path, exitCode: 9, stderrTail: "upgrade failed")) {
        try await manager.createPrefix(game: "failed-upgrade", backend: .dxmt, wineBinary: nextWine)
    }
    let persisted = try #require(upgradingBytes.withLock { $0 })
    #expect(try fs.readFile(at: marker, maxBytes: 16_384) == persisted)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("partially upgraded settings".utf8))
    // Even the original runtime must repair the partially upgraded prefix.
    if !changedPath { _ = try prefixTestWine(paths) }
    let recovery = FakeProcessRunner { invocation async throws in
        #expect(invocation.executable == wine)
        #expect(invocation.arguments == ["wineboot", "-u"])
        let json = try prefixTestJSON(fs, marker)
        #expect(json["state"] as? String == "upgrading")
        #expect(json["wineBinaryPath"] as? String == wine.path)
        #expect(json["wineBinaryIdentity"] as? [String: String] == oldIdentity)
        #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
        #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("partially upgraded settings".utf8))
        return prefixTestSuccess()
    }
    let resumed = PrefixManager(paths: paths, runner: recovery, inspector: IdlePrefixInspector())
    _ = try await resumed.createPrefix(game: "failed-upgrade", backend: .dxmt, wineBinary: wine)
    #expect(recovery.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "ready")
    #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == wine.path)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] == oldIdentity)
    #expect(try prefixTestJSON(fs, marker)["createdAt"] as? String == createdAt)
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("partially upgraded settings".utf8))
    _ = try await resumed.createPrefix(game: "failed-upgrade", backend: .dxmt, wineBinary: wine)
    #expect(recovery.invocations.count == 1)
    #expect(runner.invocations.count == 1)
}

@Test
func cancelledPrefixUpgradeIsRetriedWithOldRuntimeAndPreservesData() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths)
    _ = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "cancel-upgrade", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("cancel-upgrade", .dxmt)
    let oldIdentity = try #require(prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String])
    let save = try SafeRelativePath("Prefixes/cancel-upgrade-dxmt/drive_c/users/player/save.dat")
    let registry = try SafeRelativePath("Prefixes/cancel-upgrade-dxmt/user.reg")
    try fs.writeAtomically(Data("saved game".utf8), to: save)
    try fs.writeAtomically(Data("user settings".utf8), to: registry)
    let nextWine = try prefixTestWine(paths, version: "2.0", body: "wine-v2")
    let modified = Mutex(false)
    let runner = FakeProcessRunner { invocation async throws in
        #expect(invocation.arguments == ["wineboot", "-u"])
        #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
        #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == nextWine.path)
        try fs.writeAtomically(Data("partially upgraded settings".utf8), to: registry)
        modified.withLock { $0 = true }
        try await Task.sleep(for: .seconds(30))
        return prefixTestSuccess()
    }
    let task = Task { try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "cancel-upgrade", backend: .dxmt, wineBinary: nextWine) }
    defer { task.cancel() }
    try await prefixTestWait { modified.withLock { $0 } }
    let upgradingBytes = try fs.readFile(at: marker, maxBytes: 16_384)
    task.cancel()
    await #expect(throws: LauncherError.cancelled) { try await task.value }
    #expect(try fs.readFile(at: marker, maxBytes: 16_384) == upgradingBytes)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
    let recovery = FakeProcessRunner { invocation async throws in
        #expect(invocation.executable == wine)
        #expect(invocation.arguments == ["wineboot", "-u"])
        #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
        #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] == oldIdentity)
        #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
        #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("partially upgraded settings".utf8))
        return prefixTestSuccess()
    }
    _ = try await PrefixManager(paths: paths, runner: recovery, inspector: IdlePrefixInspector()).createPrefix(game: "cancel-upgrade", backend: .dxmt, wineBinary: wine)
    #expect(recovery.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "ready")
    #expect(try prefixTestJSON(fs, marker)["wineBinaryPath"] as? String == wine.path)
    #expect(try prefixTestJSON(fs, marker)["wineBinaryIdentity"] as? [String: String] == oldIdentity)
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
    #expect(try fs.readFile(at: registry, maxBytes: 64) == Data("partially upgraded settings".utf8))
}

@Test
func upgradingPrefixWithMatchingWineIdentityRunsAgain() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths)
    _ = try await PrefixManager(paths: paths, runner: FakeProcessRunner(), inspector: IdlePrefixInspector()).createPrefix(game: "same-target", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("same-target", .dxmt)
    var json = try prefixTestJSON(fs, marker)
    json["state"] = "upgrading"
    try fs.writeAtomically(JSONSerialization.data(withJSONObject: json), to: marker)
    let save = try SafeRelativePath("Prefixes/same-target-dxmt/drive_c/users/player/save.dat")
    try fs.writeAtomically(Data("saved game".utf8), to: save)
    let runner = FakeProcessRunner { invocation async throws in
        #expect(invocation.arguments == ["wineboot", "-u"])
        #expect(try prefixTestJSON(fs, marker)["state"] as? String == "upgrading")
        #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
        return prefixTestSuccess()
    }
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "same-target", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["state"] as? String == "ready")
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
}

@Test
func legacyPrefixMarkerWithoutStateIsReady() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
    _ = try await manager.createPrefix(game: "legacy", backend: .dxmt, wineBinary: wine)
    let marker = try prefixTestMarker("legacy", .dxmt)
    var json = try prefixTestJSON(fs, marker)
    json.removeValue(forKey: "state"); json.removeValue(forKey: "game")
    let legacyBytes = try JSONSerialization.data(withJSONObject: json)
    try fs.writeAtomically(legacyBytes, to: marker)
    let save = try SafeRelativePath("Prefixes/legacy-dxmt/drive_c/users/player/save.dat")
    try fs.writeAtomically(Data("saved game".utf8), to: save)
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "legacy", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try fs.readFile(at: marker, maxBytes: 16_384) == legacyBytes)
    #expect(try fs.readFile(at: save, maxBytes: 64) == Data("saved game".utf8))
}

@Test
func unreadablePrefixMarkerIsReinitialized() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let marker = try prefixTestMarker("unreadable", .dxmt)
    try fs.writeAtomically(Data("{}".utf8), to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: marker.resolved(against: paths.root).path)
    let runner = FakeProcessRunner { invocation async throws in
        #expect(invocation.arguments == ["wineboot", "--init"])
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("Prefixes/unreadable-dxmt")).isEmpty)
        return prefixTestSuccess()
    }
    _ = try await PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector()).createPrefix(game: "unreadable", backend: .dxmt, wineBinary: wine)
    #expect(runner.invocations.count == 1)
    #expect(try prefixTestJSON(fs, marker)["schemaVersion"] as? Int == 1)
}

@Test
func invalidPrefixMarkerSchemaReinitializes() async throws {
    let temp = try TempDir(); let paths = AppPaths(root: temp.url); let fs = try ContainedFileSystem(root: paths.root)
    let wine = try prefixTestWine(paths); let runner = FakeProcessRunner(); let manager = PrefixManager(paths: paths, runner: runner, inspector: IdlePrefixInspector())
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
private func prefixTestModificationDate(_ url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}
private func prefixTestWait(_ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
    while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(condition())
}
