// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Darwin
import Synchronization
import Testing
import LauncherCore
import TestSupport
@testable import RuntimeManager

@Suite(.timeLimit(.minutes(1))) struct LaunchPreparationTests {
    @Test(arguments: [["system.reg", "user.reg", "userdef.reg"], ["user.reg"], []])
    func registryWaitAndSyncPrecedeMarker(registryFiles: [String]) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let audit = PreparationPersistenceAudit()
            let runner = FakeProcessRunner { call in
                #expect(try fixture.revision() == nil)
                if call.executable.lastPathComponent == "wineserver" {
                    #expect(call.executable == fixture.wine.deletingLastPathComponent().appendingPathComponent("wineserver"))
                    #expect(call.arguments == ["-w"])
                    #expect(call.environment["WINEPREFIX"] == fixture.prefix.path)
                    #expect(call.environment["WINEDEBUG"] == "-all")
                    audit.record("wineserver -w")
                    // Registry files appear when the server saves on exit.
                    for name in registryFiles {
                        try fixture.fs.writeAtomically(Data(name.utf8), to: SafeRelativePath("Prefixes/genshin-dxmt/\(name)"))
                    }
                    audit.record("wineserver exited")
                } else { audit.record("registry " + call.arguments.joined(separator: " ")) }
                return preparationSuccess()
            }
            let preparer = LaunchPreparation(paths: fixture.paths, runner: runner, fileOps: audit)
            try await preparer.ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                request: PreparationRequest(retina: true, steamShim: nil, dxmtExtras: [], nvidiaKeys: true))
            let commands = runner.invocations.filter { $0.executable == fixture.wine }.map { "registry " + $0.arguments.joined(separator: " ") }
            #expect(commands.count == 7)
            let expected = commands + ["wineserver -w", "wineserver exited"] + registryFiles.map { "fsync " + $0 } + ["write marker", "fullsync marker", "publish marker"]
            #expect(audit.events.filter { $0 != "fsync prefix" } == expected)
            let beforeMarker = audit.events.prefix { $0 != "write marker" }
            #expect(beforeMarker.last == "fsync prefix")
            #expect(try fixture.revision() == 1)
        }
    }

    @Test func timedOutWineserverWaitCancelsAndJoinsBeforeThrowing() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let entered = TestEvent(), never = TestEvent(), cancelled = TestEvent()
            let runner = FakeProcessRunner { call in
                if call.executable.lastPathComponent == "wineserver" {
                    defer { cancelled.signal() }
                    entered.signal(); try await never.wait()
                }
                return preparationSuccess()
            }
            let preparer = LaunchPreparation(paths: fixture.paths, runner: runner, fileOps: SystemFileOps(), timeoutWait: { timeout in
                #expect(timeout == .seconds(60))
                try await entered.wait() // Fire the deadline only once the wait has started.
            })
            await #expect(throws: LauncherError.io("Process timed out")) {
                try await preparer.ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            }
            try await cancelled.wait()
            #expect(try fixture.revision() == nil)
            // Cancellation cleanup and the prefix lease finish before returning.
            try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(try fixture.revision() == 1)
        }
    }

    @Test(arguments: ["system.reg", "user.reg", "userdef.reg", "prefix"])
    func registrySyncFailureLeavesRevisionUnset(failedLeaf: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner { call in
                if call.executable.lastPathComponent == "wineserver" {
                    for name in ["system.reg", "user.reg", "userdef.reg"] {
                        try fixture.fs.writeAtomically(Data(name.utf8), to: SafeRelativePath("Prefixes/genshin-dxmt/\(name)"))
                    }
                }
                return preparationSuccess()
            }
            let audit = PreparationPersistenceAudit(failedLeaf: failedLeaf)
            let preparer = LaunchPreparation(paths: fixture.paths, runner: runner, fileOps: audit)
            await #expect(throws: LauncherError.self) {
                try await preparer.ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                    request: PreparationRequest(retina: false, steamShim: nil, dxmtExtras: [], nvidiaKeys: false))
            }
            #expect(try fixture.revision() == nil)
            #expect(!audit.events.contains("write marker"))
        }
    }

    @Test func failedWineserverWaitLeavesRevisionUnset() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner { call in
                call.executable.lastPathComponent == "wineserver"
                    ? ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("registry wait failed".utf8))
                    : preparationSuccess()
            }
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            }
            #expect(try fixture.revision() == nil)
        }
    }
    @Test func fullyPreparedPrefixNeverInstallsThirdPartyCertificates() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner()
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                request: PreparationRequest(retina: true, steamShim: fixture.shim, dxmtExtras: ["winemetal.dll", "nvngx.dll"], nvidiaKeys: true))
            #expect(try fixture.revision() == 1)
            // Account for every Wine command: a .reg import would conceal its
            // registry keys from the command log, so prohibit imports as well.
            #expect(runner.invocations.count == 8)
            for call in runner.invocations where call.executable == fixture.wine {
                #expect(call.arguments.prefix(2) == ["reg", "add"] || call.arguments.prefix(2) == ["reg", "delete"])
                let command = call.arguments.joined(separator: " ").uppercased()
                #expect(!command.contains("SYSTEMCERTIFICATES\\ROOT"))
                #expect(!command.contains("SYSTEMCERTIFICATES\\CA"))
                for thumbprint in ["F09065E2D57F005BBD975DDCF9EB63F570764F17", "D5115FFECE7A5DBFB8F1648C4CAE7085EFE676EE"] {
                    #expect(!command.contains(thumbprint))
                }
            }
        }
    }
    @Test func freshPrefixGetsEverything() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner()
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(runner.invocations.first?.arguments.contains("ProxyEnable") == true)
            #expect(runner.invocations.map(\.arguments).contains(["reg", "add", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "0", "/f"]))
            for value in ["ProxyServer", "ProxyOverride"] {
                #expect(runner.invocations.contains { $0.arguments == ["reg", "delete", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", value, "/f"] })
            }
            #expect(runner.invocations.contains { $0.arguments == ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode", "/t", "REG_SZ", "/d", "n", "/f"] })
            for call in runner.invocations {
                if call.arguments == ["-w"] {
                    #expect(call.executable == fixture.wine.deletingLastPathComponent().appendingPathComponent("wineserver"))
                } else { #expect(call.executable == fixture.wine) }
                #expect(call.environment["WINEPREFIX"] == fixture.prefix.path)
                #expect(call.environment["WINEDEBUG"] == "-all")
            }
            for (source, destination) in PreparationFixture.shimDestinations {
                #expect(try fixture.fs.readFile(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/windows/\(destination)"), maxBytes: 100) == Data(source.utf8))
            }
            #expect(try fixture.revision() == LaunchPreparation.provisioningRevision)
        }
    }

    @Test func existingM1PrefixUpgrades() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            var before = try fixture.marker()
            for key in ["state", "game", "bundleID", "runtimeDigest"] { before.removeValue(forKey: key) }
            try fixture.fs.writeAtomically(JSONSerialization.data(withJSONObject: before), to: SafeRelativePath("Prefixes/genshin-dxmt/.macgacha-prefix.json"))
            #expect(before["provisioningRevision"] == nil)
            let runner = FakeProcessRunner()
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(!runner.invocations.contains { $0.arguments.contains("wineboot") })
            #expect(try fixture.marker()["createdAt"] as? String == before["createdAt"] as? String)
            #expect(try fixture.revision() == 1)
            // PrefixManager still accepts the updated schema-1 marker.
            let prefixRunner = FakeProcessRunner()
            _ = try await PrefixManager(paths: fixture.paths, runner: prefixRunner).createPrefix(game: "genshin", backend: .dxmt, wineBinary: fixture.wine)
            #expect(prefixRunner.invocations.isEmpty)
            #expect(try fixture.revision() == 1)
        }
    }

    @Test func secondRunOnlyAppliesPerLaunchState() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            let runner = FakeProcessRunner()
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request(retina: true))
            #expect(runner.invocations.count == 2)
            #expect(runner.invocations[0].arguments.suffix(3) == ["/d", "y", "/f"])
            #expect(runner.invocations[1].arguments == ["-w"])
            #expect(try fixture.revision() == 1)
        }
    }

    @Test(arguments: ["ProxyEnable", "ProxyServer", "ProxyOverride", "RetinaMode", "FullPath"])
    func interruptedRunCompletesNextTime(failure: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner { call in
                call.arguments.contains(failure) ? ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("Access denied".utf8)) : preparationSuccess()
            }
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request(nvidia: true))
            }
            #expect(try fixture.revision() == nil)
            let retry = FakeProcessRunner()
            try await fixture.preparer(retry).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request(nvidia: true))
            #expect(retry.invocations.first?.arguments.contains("ProxyEnable") == true)
            #expect(try fixture.revision() == 1)
        }
    }

    @Test func absentProxyValuesAreSuccessfulDeletes() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner { call in
                call.arguments.prefix(2) == ["reg", "delete"] ? ProcessResult(exitCode: 1, stdout: Data("reg: Unable to find the specified registry value\n".utf8), stderr: Data()) : preparationSuccess()
            }
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(try fixture.revision() == 1)
        }
    }

    @Test func registryDeleteAccessDeniedIsFailure() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner { call in
                call.arguments.prefix(2) == ["reg", "delete"] ? ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("reg: Access is denied".utf8)) : preparationSuccess()
            }
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            }
            #expect(try fixture.revision() == nil)
        }
    }

    @Test(arguments: ["steam64.exe", "winemetal.dll"])
    func missingRequiredCopyNeverPublishesRevision(name: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let source = name == "steam64.exe" ? "Runtimes/shim/\(name)" : "Runtimes/bundle/lib/wine/x86_64-windows/\(name)"
            try fixture.fs.removeFile(at: SafeRelativePath(source))
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                    request: PreparationRequest(retina: false, steamShim: fixture.shim, dxmtExtras: ["winemetal.dll"], nvidiaKeys: false))
            }
            #expect(try fixture.revision() == nil)
        }
    }

    @Test func nvidiaKeysAndDXMTExtrasMatchYaagl() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let runner = FakeProcessRunner()
            let request = PreparationRequest(retina: false, steamShim: nil, dxmtExtras: ["winemetal.dll", "nvngx.dll"], nvidiaKeys: true)
            try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: request)
            for key in ["HKLM\\SOFTWARE\\NVIDIA Corporation\\Global", "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm"] {
                #expect(runner.invocations.contains { $0.arguments == ["reg", "add", key, "/v", "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}", "/t", "REG_BINARY", "/d", "1", "/f"] })
            }
            #expect(runner.invocations.contains { $0.arguments == ["reg", "add", "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", "/v", "FullPath", "/t", "REG_SZ", "/d", "C:\\Windows\\System32", "/f"] })
            for name in request.dxmtExtras {
                #expect(try fixture.fs.readFile(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/windows/system32/\(name)"), maxBytes: 100) == Data(name.utf8))
            }
        }
    }

    @Test func runtimeTreeUntouched() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let before = try preparationTreeDigest(fixture.fs, at: SafeRelativePath("Runtimes/bundle"))
            try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                request: PreparationRequest(retina: true, steamShim: fixture.shim, dxmtExtras: ["winemetal.dll", "nvngx.dll"], nvidiaKeys: true))
            #expect(try preparationTreeDigest(fixture.fs, at: SafeRelativePath("Runtimes/bundle")) == before)
        }
    }

    @Test(arguments: ["../escape.dll", "/tmp/escape.dll", "other/escape.dll"])
    func unsafeExtrasAreRejected(name: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine,
                    request: PreparationRequest(retina: false, steamShim: nil, dxmtExtras: [name], nvidiaKeys: false))
            }
            #expect(try fixture.revision() == nil)
        }
    }

    @Test func symlinkDestinationIsRejectedWithoutTouchingTarget() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            try fixture.fs.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("outside"))
            try fixture.fs.createSymbolicLink(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/windows/system32/steam.exe"), target: "../../../../../outside")
            await #expect(throws: LauncherError.self) {
                try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            }
            #expect(try fixture.fs.readFile(at: SafeRelativePath("outside"), maxBytes: 100) == Data("untouched".utf8))
            #expect(try fixture.revision() == nil)
        }
    }

    @Test func steamExeOnlyComponentIsSupported() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            for name in ["lsteamclient64.dll", "lsteamclient32.dll"] { try fixture.fs.removeFile(at: SafeRelativePath("Runtimes/shim/\(name)")) }
            try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(try fixture.revision() == 1)
            #expect(try fixture.fs.size(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/windows/system32/steam.exe")) != nil)
        }
    }

    @Test func cancelledPreparationLeavesRevisionUnset() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fixture = try await PreparationFixture(root: temp.url)
            let entered = TestEvent(), release = TestEvent()
            let runner = FakeProcessRunner { _ in entered.signal(); try await release.wait(); return preparationSuccess() }
            let worker = Task { try await fixture.preparer(runner).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request()) }
            try await entered.wait(); worker.cancel()
            await #expect(throws: LauncherError.cancelled) { try await worker.value }
            #expect(try fixture.revision() == nil)
            try await fixture.preparer(FakeProcessRunner()).ensure(prefix: fixture.prefix, wineBinary: fixture.wine, request: fixture.request())
            #expect(try fixture.revision() == 1)
        }
    }
}

private struct PreparationFixture: Sendable {
    let paths: AppPaths, fs: ContainedFileSystem, wine: URL, prefix: URL, shim: URL
    static let shimDestinations = [("steam64.exe", "system32/steam.exe"), ("steam32.exe", "syswow64/steam.exe"),
        ("lsteamclient64.dll", "system32/lsteamclient.dll"), ("lsteamclient32.dll", "syswow64/lsteamclient.dll")]
    init(root: URL) async throws {
        paths = AppPaths(root: root); fs = try ContainedFileSystem(root: root)
        wine = root.appendingPathComponent("Runtimes/bundle/bin/wine")
        shim = root.appendingPathComponent("Runtimes/shim")
        try fs.writeAtomically(Data("wine".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wine"))
        try fs.writeAtomically(Data("wineserver".utf8), to: SafeRelativePath("Runtimes/bundle/bin/wineserver"))
        for (source, _) in Self.shimDestinations { try fs.writeAtomically(Data(source.utf8), to: SafeRelativePath("Runtimes/shim/\(source)")) }
        for name in ["winemetal.dll", "nvngx.dll"] { try fs.writeAtomically(Data(name.utf8), to: SafeRelativePath("Runtimes/bundle/lib/wine/x86_64-windows/\(name)")) }
        prefix = try await PrefixManager(paths: paths, runner: FakeProcessRunner()).createPrefix(game: "genshin", backend: .dxmt, wineBinary: wine)
        try fs.createDirectory(at: SafeRelativePath("Prefixes/genshin-dxmt/drive_c/windows/system32"))
    }
    func request(retina: Bool = false, nvidia: Bool = false) -> PreparationRequest {
        PreparationRequest(retina: retina, steamShim: shim, dxmtExtras: [], nvidiaKeys: nvidia)
    }
    func preparer(_ runner: any ProcessRunner) -> LaunchPreparation { LaunchPreparation(paths: paths, runner: runner) }
    func marker() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: fs.readFile(at: SafeRelativePath("Prefixes/genshin-dxmt/.macgacha-prefix.json"), maxBytes: 16_384)) as! [String: Any]
    }
    func revision() throws -> Int? { try marker()["provisioningRevision"] as? Int }
}

private func preparationSuccess() -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
private func preparationTreeDigest(_ fs: ContainedFileSystem, at path: SafeRelativePath) throws -> Digest {
    var hash = StreamingHasher(.sha256)
    func visit(_ path: SafeRelativePath) throws {
        hash.update(Data(path.description.utf8))
        if try fs.itemType(at: path) == .directory {
            for child in try fs.contentsOfDirectory(at: path).sorted(by: { $0.description < $1.description }) { try visit(child) }
        } else { try fs.readFile(at: path) { hash.update($0) } }
    }
    try visit(path)
    return hash.finalize()
}

private final class PreparationPersistenceAudit: FileOps, Sendable {
    private let log = Mutex([String]())
    private let failedLeaf: String?
    init(failedLeaf: String? = nil) { self.failedLeaf = failedLeaf }
    var events: [String] { log.withLock { $0 } }
    func record(_ event: String) { log.withLock { $0.append(event) } }
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int {
        if String(decoding: bytes, as: UTF8.self).contains("\"provisioningRevision\"") { record("write marker") }
        return try SystemFileOps().write(descriptor, bytes: bytes)
    }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard buffer.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else {
            throw LauncherError.io("Cannot inspect persistence test descriptor")
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        if ["system.reg", "user.reg", "userdef.reg"].contains(leaf) {
            #expect(!durable)
            record("fsync " + leaf)
        } else if leaf == "genshin-dxmt" { record("fsync prefix") }
        else if leaf == ".macgacha-prefix.pending" { #expect(durable); record("fullsync marker") }
        if failedLeaf == leaf || failedLeaf == "prefix" && leaf == "genshin-dxmt" { throw LauncherError.io("Injected registry sync failure") }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        if destination == ".macgacha-prefix.json" { record("publish marker") }
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory)
    }
}
