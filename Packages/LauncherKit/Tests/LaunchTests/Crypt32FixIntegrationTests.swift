// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import RuntimeManager
import TestSupport
import Launch

@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_RUNTIME_FIXTURES"] != nil
    && ProcessInfo.processInfo.environment["MACGACHA_CRYPT32_FIX_BUILD"] != nil))
struct Crypt32FixIntegrationTests {
    @Test(.timeLimit(.minutes(5))) func nativePrefixCopyActuallyReplacesBuiltin() async throws {
        let built = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MACGACHA_CRYPT32_FIX_BUILD"]))
        let probe = built.appendingPathComponent("audit/crypt32-probe.exe")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await withProbeTestRoot(root: root, setup: { try await installLaunchProbeRuntime(backend: "d3dmetal", root: $0) }) { configuration in
            let runner = SystemProcessRunner()
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let manifest = try RuntimeManifest.load(from: repository.appendingPathComponent("App/Resources/runtime-manifest.json"))
            let component = try #require(manifest.components.first { $0.id.rawValue == Crypt32Fix.componentID })
            let store = RuntimeStore(paths: configuration.paths)
            let installer = ComponentInstaller(store: store, consent: ConsentStore(url: configuration.paths.consent, root: configuration.paths.root),
                fetcher: ChunkFetcher(http: ProbeFixtureHTTP(root: built), retry: RetryPolicy(maxAttempts: 1), sleeper: InstantSleeper()),
                extractor: ArchiveExtractor(runner: runner), disk: SystemDiskSpaceProbe())
            for try await _ in installer.install(component) {}
            let installed = store.installURL(for: component)
            let prefix = try await PrefixManager(paths: configuration.paths, runner: runner).createPrefix(game: "starrail", bundle: configuration.bundle)
            let runtime = configuration.wine.deletingLastPathComponent().deletingLastPathComponent()
            let dll = try SafeRelativePath("lib/wine/x86_64-windows/crypt32.dll")
            let before = try await BlockingIO.run { try ContainedFileSystem(root: runtime).withClaimedFile(at: dll) { $0.sha256 } }
            let recipe = LaunchRecipe(game: "zzz-cn", recipeVersion: 1, verifiedBuilds: [],
                executable: try SafeRelativePath("probe.exe"), wrapper: .none, blockedHosts: [], hidden: [], copyIfPresent: [],
                timeoutFix: false, supportsDirectX12: false)
            var settings = LaunchSettings.defaults(for: "zzz-cn"); settings.compatibilityPatches = false
            let plan = try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: configuration.gameRoot,
                prefix: prefix, wineBinary: configuration.wine, proxyPort: 1234,
                componentRoots: [.crypt32Fix: installed], baseEnvironment: [:], runtimeBundleID: configuration.bundleID.rawValue)
            try #require(plan.componentCopies.count == 1)
            try #require(plan.environment["WINEDLLOVERRIDES"] == "crypt32=n,b")
            var baseline = plan.environment; baseline["WINEDLLOVERRIDES"] = ""; baseline["WINEDEBUG"] = "-all"
            let stockEnvironment = baseline
            let stock = try await BlockingIO.run {
                try await runner.run(configuration.wine, arguments: [WinePath.windowsPath(for: probe), "0"], environment: stockEnvironment,
                    currentDirectory: configuration.gameRoot, timeout: .seconds(90), timeoutWait: { try await Task.sleep(for: $0) })
            }
            try #require(stock.exitCode == 0, "Stock Wine must reject the upstream unsorted-attributes fixture: \(String(decoding: stock.stderr, as: UTF8.self))")
            #expect(String(decoding: stock.stdout, as: UTF8.self).contains("verified=0"))
            for option in ["-k", "-w"] {
                let stopped = try await BlockingIO.run {
                    try await runner.run(configuration.wine.deletingLastPathComponent().appendingPathComponent("wineserver"),
                        arguments: [option], environment: stockEnvironment, currentDirectory: nil,
                        timeout: .seconds(20), timeoutWait: { try await Task.sleep(for: $0) })
                }
                var idleKill = false
                if option == "-k", stopped.exitCode == 1, stopped.stdout.isEmpty, stopped.stderr.isEmpty {
                    idleKill = try await BlockingIO.run { try WineServerProbe().isIdle(prefix: ContainedFileSystem(root: prefix).pinRoot()) }
                }
                try #require(stopped.exitCode == 0 || idleKill)
            }
            try await LaunchPreparation(paths: configuration.paths, runner: runner).ensure(prefix: prefix,
                wineBinary: configuration.wine, request: plan.preparation)
            try await BlockingIO.run {
                for copy in plan.componentCopies {
                    try LaunchCopies.copyRequired([(copy.source, copy.toSystem32)], componentRoot: copy.root,
                        system32: prefix.appendingPathComponent("drive_c/windows/system32"), log: nil)
                }
                let fs = try ContainedFileSystem(root: prefix.appendingPathComponent("drive_c/windows/system32"))
                let contents = try fs.readFile(at: SafeRelativePath("crypt32.dll"), maxBytes: 8 << 20)
                try #require(contents[64..<96].allSatisfy { $0 == 0 }, "Prefix DLL must have native identification")
            }
            var debug = plan.environment; debug["WINEDEBUG"] = "+loaddll"
            let fixedEnvironment = debug
            let patched = try await BlockingIO.run {
                try await runner.run(configuration.wine, arguments: [WinePath.windowsPath(for: probe), "1"], environment: fixedEnvironment,
                    currentDirectory: configuration.gameRoot, timeout: .seconds(90), timeoutWait: { try await Task.sleep(for: $0) })
            }
            try #require(patched.exitCode == 0, "Prefix-only crypt32 fix did not verify the signature: \(String(decoding: patched.stdout, as: UTF8.self)); \(String(decoding: patched.stderr, as: UTF8.self))")
            #expect(String(decoding: patched.stdout, as: UTF8.self).contains("verified=1"))
            let after = try await BlockingIO.run { try ContainedFileSystem(root: runtime).withClaimedFile(at: dll) { $0.sha256 } }
            #expect(after == before)
            print("crypt32 Wine 11.20: stock verified=0; prefix-only fixed DLL verified=1; runtime digest unchanged PASS")
        }
    }
}
