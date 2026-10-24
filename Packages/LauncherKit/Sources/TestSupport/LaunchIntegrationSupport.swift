// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager
import Launch

/// Only test processes read this configuration; every path is inside an explicitly managed temporary root.
package struct ProbeLaunchConfiguration: Codable, Sendable {
    package let root: URL
    package let bundleID: SafeIdentifier
    package let bundleRoot: URL
    package let wine: URL
    package let digest: Digest
    package let componentIDs: [String]
    package init(root: URL, bundleID: SafeIdentifier, bundleRoot: URL, wine: URL, digest: Digest, componentIDs: [String]) {
        self.root = root; self.bundleID = bundleID; self.bundleRoot = bundleRoot
        self.wine = wine; self.digest = digest; self.componentIDs = componentIDs
    }
    package var paths: AppPaths { AppPaths(root: root.appendingPathComponent("store")) }
    package var gameRoot: URL { root.appendingPathComponent("game") }
    package var bundle: InstalledRuntimeBundle {
        InstalledRuntimeBundle(id: bundleID, root: bundleRoot, wineBinary: wine, digest: digest, source: .download)
    }
    package static func read(root: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: ContainedFileSystem(root: root)
            .readFile(at: SafeRelativePath("probe-launch.json"), maxBytes: 65536))
    }
    package func write() throws {
        try ContainedFileSystem(root: root).writeAtomically(JSONEncoder().encode(self), to: SafeRelativePath("probe-launch.json"))
    }
    package static var recipe: LaunchRecipe {
        LaunchRecipe(game: "starrail", recipeVersion: 1, verifiedBuilds: ["probe"],
            executable: try! SafeRelativePath("d3d11probe.exe"), wrapper: .none, blockedHosts: ["blocked.test"],
            hidden: [try! SafeRelativePath("vulkan-1.dll")], copyIfPresent: [], timeoutFix: false, supportsDirectX12: false)
    }
    package func manager(hooks: LaunchFileHooks = .none, inspector: any ProcessInspector = SystemProcessInspector()) -> LaunchManager {
        let runner = SystemProcessRunner()
        return LaunchManager(paths: paths, runtimes: ProbeRuntime(configuration: self),
            prefixes: PrefixManager(paths: paths, runner: runner), preparation: LaunchPreparation(paths: paths, runner: runner),
            spawner: SystemProcessSpawner(), inspector: inspector, runner: runner, clock: ContinuousClock(),
            proxyFactory: { hosts, log in try await SessionProxy.start(blockedHosts: hosts, log: log) },
            baseEnvironment: ProcessInfo.processInfo.environment, hideHooks: hooks, recipeOverrides: ["starrail": Self.recipe])
    }
    package func signal(_ name: String) throws {
        try ContainedFileSystem(root: gameRoot).writeAtomically(Data(), to: SafeRelativePath(name))
    }
    package func recordHandshakePhase(_ phase: String) throws {
        try ContainedFileSystem(root: gameRoot).writeAtomically(Data(phase.utf8), to: SafeRelativePath("harness-phase"))
    }
    package func handshakeDiagnostics() throws -> String {
        let fs = try ContainedFileSystem(root: gameRoot)
        let phasePath = try SafeRelativePath("harness-phase")
        let phase = try fs.itemType(at: phasePath) == nil ? "child has not recorded a phase"
            : String(decoding: fs.readFile(at: phasePath, maxBytes: 4096), as: UTF8.self)
        let signals = try ["probe-ready", "launcher-ready", "probe-release"].map {
            "\($0)=\(try fs.itemType(at: SafeRelativePath($0)) == nil ? "absent" : "present")"
        }.joined(separator: ", ")
        let inspectionPath = try SafeRelativePath("inspection-error")
        let inspection = try fs.itemType(at: inspectionPath) == nil ? "none recorded"
            : String(decoding: fs.readFile(at: inspectionPath, maxBytes: 4096), as: UTF8.self)
        return "child phase: \(phase); \(signals); last inspection error: \(inspection)"
    }
}

private struct ProbeRuntime: LaunchRuntimeProviding {
    let configuration: ProbeLaunchConfiguration
    func selection(for settings: LaunchSettings) async throws -> LaunchRuntimeSelection {
        LaunchRuntimeSelection(bundle: configuration.bundle, componentIDs: configuration.componentIDs, componentRoots: [:])
    }
}
