// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Idempotent provisioning of an initialized prefix. Wine registry settings
/// and verified file copies stay in this prefix; no certificates are installed.
/// Shares PrefixManager's lock so initialization and preparation cannot overlap.
public struct LaunchPreparation: Sendable {
    public static let provisioningRevision = 2
    private let paths: AppPaths
    private let runner: any ProcessRunner
    private let inspector: any ProcessInspector
    private let serverProbe: WineServerProbe
    private let fileOps: any FileOps
    private let registryWaitTimeout: Duration
    private let timeoutWait: @Sendable (Duration) async throws -> Void
    private static let internetSettings = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

    public init(paths: AppPaths, runner: any ProcessRunner, registryWaitTimeout: Duration = .seconds(60),
        inspector: any ProcessInspector = SystemProcessInspector(), wineServerRoot: URL? = nil) {
        self.init(paths: paths, runner: runner, fileOps: SystemFileOps(), registryWaitTimeout: registryWaitTimeout, inspector: inspector, wineServerRoot: wineServerRoot)
    }

    package init(paths: AppPaths, runner: any ProcessRunner, fileOps: any FileOps,
        registryWaitTimeout: Duration = .seconds(60),
        timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        inspector: any ProcessInspector = SystemProcessInspector(), wineServerRoot: URL? = nil) {
        self.paths = paths; self.runner = runner; self.fileOps = fileOps; self.inspector = inspector
        self.serverProbe = WineServerProbe(root: wineServerRoot)
        self.registryWaitTimeout = registryWaitTimeout; self.timeoutWait = timeoutWait
    }

    @discardableResult public func ensure(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome {
        do {
            return try await BlockingIO.run { try await ensureOnIO(prefix: prefix, wineBinary: wineBinary, request: request) }
        } catch {
            if Task.isCancelled || error is CancellationError { throw LauncherError.cancelled }
            throw error
        }
    }

    private func ensureOnIO(prefix: URL, wineBinary: URL, request: PreparationRequest) async throws -> PreparationOutcome {
        let fs = try ContainedFileSystem(root: paths.root, fileOps: fileOps)
        let path = try RuntimeJSONFile.relativePath(prefix, root: paths.root)
        guard path.components.count == 2, path.components.first == "Prefixes" else { throw LauncherError.unsafePath(prefix.path) }
        _ = try SafeIdentifier(path.components[1])
        _ = try fs.directoryURL(at: path)
        let lock = try await PrefixManager.acquireLock(fs: fs, prefix: path)
        defer { withExtendedLifetime(lock) {} }
        let markerPath = try SafeRelativePath("\(path)/.macgacha-prefix.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var marker = try decoder.decode(PrefixMarker.self, from: fs.readFile(at: markerPath, maxBytes: PrefixManager.markerLimit))
        let binary = wineBinary.standardizedFileURL
        let sourceRoot = binary.deletingLastPathComponent()
        let sourceFS = try ContainedFileSystem(root: sourceRoot)
        let sourcePath = try RuntimeJSONFile.relativePath(binary, root: sourceRoot)
        let binaryIdentity = try fingerprint(sourceFS, at: sourcePath).digest
        guard marker.schemaVersion == PrefixMarker.schema, marker.state == .ready,
              marker.createdAt.timeIntervalSince1970.isFinite, marker.wineBinaryPath == binary.path,
              marker.wineBinaryIdentity == binaryIdentity else {
            throw LauncherError.io("Launch preparation requires a ready prefix for this Wine binary")
        }
        for name in request.dxmtExtras {
            guard try SafeRelativePath(name).components.count == 1 else { throw LauncherError.unsafePath(name) }
        }
        guard let prefixFS = try fs.pinDirectoryIfPresent(at: path) else { throw LauncherError.io("Prefix is missing") }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        try PrefixShellFolders.repair(in: prefixFS)
        let environment = ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all", "LC_ALL": "C"]
        let needsProvisioning = (marker.provisioningRevision ?? 0) < Self.provisioningRevision
        if needsProvisioning {
            try await run(binary, ["reg", "add", Self.internetSettings, "/v", "ProxyEnable", "/t", "REG_DWORD", "/d", "0", "/f"], environment)
            for value in ["ProxyServer", "ProxyOverride"] {
                try await run(binary, ["reg", "delete", Self.internetSettings, "/v", value, "/f"], environment, allowMissingValue: true)
            }
            try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "winemenubuilder.exe", "/t", "REG_SZ", "/d", "", "/f"], environment)
            for (value, folder) in PrefixShellFolders.registryValues {
                try await run(binary, ["reg", "add", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
                    "/v", value, "/t", "REG_EXPAND_SZ", "/d", "%USERPROFILE%\\" + folder, "/f"], environment)
            }
        }
        try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\Mac Driver", "/v", "RetinaMode", "/t", "REG_SZ", "/d", request.retina ? "y" : "n", "/f"], environment)
        if let shim = request.steamShim {
            let source = try ContainedFileSystem(root: shim)
            for (name, destination, optional) in [
                ("steam64.exe", "system32/steam.exe", false), ("steam32.exe", "syswow64/steam.exe", false),
                ("lsteamclient64.dll", "system32/lsteamclient.dll", true), ("lsteamclient32.dll", "syswow64/lsteamclient.dll", true)
            ] {
                let input = try SafeRelativePath(name)
                // Our pinned Proton component is steam.exe-only. Older shim
                // sets also contain these DLLs; copy them when supplied.
                if optional { if try source.itemType(at: input) == nil { continue } }
                try copyVerified(source, at: input, into: fs, at: SafeRelativePath("\(path)/drive_c/windows/\(destination)"))
            }
        }
        let bundle = try ContainedFileSystem(root: binary.deletingLastPathComponent().deletingLastPathComponent())
        for name in request.dxmtExtras {
            try copyVerified(bundle, at: SafeRelativePath("lib/wine/x86_64-windows/\(name)"), into: fs,
                at: SafeRelativePath("\(path)/drive_c/windows/system32/\(name)"))
        }
        if request.nvidiaKeys {
            // MIT: yaagl setNVExtension (Copyright (c) 2023 3Shain).
            for key in ["HKLM\\SOFTWARE\\NVIDIA Corporation\\Global", "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm"] {
                try await run(binary, ["reg", "add", key, "/v", "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}", "/t", "REG_BINARY", "/d", "1", "/f"], environment)
            }
            try await run(binary, ["reg", "add", "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", "/v", "FullPath", "/t", "REG_SZ", "/d", "C:\\Windows\\System32", "/f"], environment)
        }
        if request.crypt32Native {
            // The pinned yaagl wrapper removes WINEDLLOVERRIDES. Persist the
            // same policy in this game/bundle's prefix, not in the runtime.
            try await run(binary, ["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "crypt32", "/t", "REG_SZ", "/d", "native,builtin", "/f"], environment)
        }
        let frameRate = try await applyStarRailFrameRate(request, binary: binary, environment: environment)
        // reg.exe success only acknowledges wineserver's in-memory state. Wait
        // for the server to save it, then flush the files and directory before
        // the marker's full-sync boundary can certify this provisioning revision.
        let wineserver = binary.deletingLastPathComponent().appendingPathComponent("wineserver")
        let persisted = try await runner.run(wineserver, arguments: ["-w"], environment: environment,
            currentDirectory: nil, timeout: registryWaitTimeout, timeoutWait: timeoutWait)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        guard persisted.exitCode == 0 else {
            throw LauncherError.processFailed(executable: wineserver.path, exitCode: persisted.exitCode,
                stderrTail: String(decoding: persisted.stderr.suffix(4096), as: UTF8.self))
        }
        try PrefixShellFolders.validate(in: prefixFS)
        try PrefixShellFolders.requireIdle(prefix: prefix, prefixFS: prefixFS, wineBinary: binary, runtimeRoot: paths.runtimes, inspector: inspector, serverProbe: serverProbe)
        try PrefixShellFolders.repair(in: prefixFS)
        for name in ["system.reg", "user.reg", "userdef.reg"] {
            let registry = try SafeRelativePath("\(path)/\(name)")
            if try fs.itemType(at: registry) != nil { try fs.synchronizeFile(at: registry, durable: false) }
        }
        try fs.synchronizeParentDirectory(of: markerPath)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if needsProvisioning {
            marker.provisioningRevision = Self.provisioningRevision
            try PrefixManager.writeMarker(marker, fs: fs, to: markerPath, pending: SafeRelativePath("\(path)/.macgacha-prefix.pending"))
        }
        return PreparationOutcome(starRailFrameRate: frameRate)
    }

    private func applyStarRailFrameRate(_ request: PreparationRequest, binary: URL,
        environment: [String: String]) async throws -> StarRailFrameRateOutcome? {
        guard let mode = request.starRailFrameRate else { return nil }
        let key = StarRailFrameRate.registryKey(for: request.starRailRegion)
        do {
            let query = try await runner.run(binary, arguments: ["reg", "query", key], environment: environment,
                currentDirectory: nil, timeout: .seconds(10), timeoutWait: timeoutWait)
            try Task.checkCancellation()
            let diagnostic = String(decoding: query.stdout + query.stderr, as: UTF8.self).lowercased()
            guard query.exitCode == 0 else {
                return query.exitCode == 1 && (diagnostic.contains("unable to find the specified registry") ||
                    diagnostic.contains("the system was unable to find the specified registry key or value")) ? .missing : .unreadable
            }
            guard query.stdout.count <= StarRailFrameRate.maximumPayloadBytes * 2 else { return .unreadable }
            let values = StarRailFrameRate.parseQuery(String(decoding: query.stdout, as: UTF8.self))
            guard !values.isEmpty else { return .missing }
            var applied = false, unreadable = false
            for value in values {
                guard let payload = StarRailFrameRate.decodeHex(value.hex), let oldFPS = StarRailFrameRate.currentFPS(payload) else {
                    unreadable = true; continue
                }
                let fps = mode == .unlock120 ? 120 : 60
                if oldFPS == Double(fps) || (mode == .restore && oldFPS != 120) { continue }
                guard let rewritten = StarRailFrameRate.rewrite(payload, fps: fps) else { unreadable = true; continue }
                let result = try await runner.run(binary, arguments: ["reg", "add", key, "/v", value.name,
                    "/t", "REG_BINARY", "/d", StarRailFrameRate.encodeHex(rewritten), "/f"], environment: environment,
                    currentDirectory: nil, timeout: .seconds(10), timeoutWait: timeoutWait)
                try Task.checkCancellation()
                if result.exitCode == 0 { applied = true } else { unreadable = true }
            }
            return applied ? .applied : unreadable ? .unreadable : .unchanged
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? LauncherError) == .cancelled { throw LauncherError.cancelled }
            return .unreadable
        }
    }

    private func run(_ binary: URL, _ arguments: [String], _ environment: [String: String], allowMissingValue: Bool = false) async throws {
        let result = try await runner.run(binary, arguments: arguments, environment: environment, currentDirectory: nil)
        guard !Task.isCancelled else { throw LauncherError.cancelled }
        if result.exitCode == 0 { return }
        // Wine reg.exe reports an absent value as exit 1. Force the C locale so
        // missing-value diagnostics are stable; access and other failures throw.
        let diagnostic = String(decoding: result.stdout + result.stderr, as: UTF8.self).lowercased()
        if allowMissingValue && result.exitCode == 1 &&
            (diagnostic.contains("unable to find the specified registry value") || diagnostic.contains("the system was unable to find the specified registry key or value")) { return }
        throw LauncherError.processFailed(executable: binary.path, exitCode: result.exitCode,
            stderrTail: String(decoding: result.stderr.suffix(4096), as: UTF8.self))
    }

    private func fingerprint(_ fs: ContainedFileSystem, at path: SafeRelativePath) throws -> (size: Int64, digest: Digest) {
        guard let size = try fs.size(at: path) else { throw LauncherError.io("Launch preparation file is missing") }
        var hash = StreamingHasher(.sha256), count: Int64 = 0
        try fs.readFile(at: path) { bytes in count += Int64(bytes.count); hash.update(bytes) }
        guard count == size else { throw LauncherError.io("Launch preparation source changed") }
        return (size, hash.finalize())
    }

    private func copyVerified(_ source: ContainedFileSystem, at input: SafeRelativePath, into fs: ContainedFileSystem, at output: SafeRelativePath) throws {
        let expected = try fingerprint(source, at: input)
        let parent = output.components.dropLast().joined(separator: "/")
        let temporary = try SafeRelativePath("\(parent)/.macgacha-prepare-\(UUID().uuidString)")
        defer { try? fs.removeFile(at: temporary) }
        _ = try source.copyRegularFile(at: input, to: temporary, in: fs, maxBytes: expected.size)
        let actual = try fingerprint(fs, at: temporary)
        guard actual.size == expected.size, actual.digest == expected.digest else { throw LauncherError.io("Launch preparation copy mismatch") }
        try fs.fullSync(at: temporary)
        try fs.rename(from: temporary, to: output)
        let published = try fingerprint(fs, at: output)
        guard published.size == expected.size, published.digest == expected.digest else { throw LauncherError.io("Launch preparation publication mismatch") }
    }
}
