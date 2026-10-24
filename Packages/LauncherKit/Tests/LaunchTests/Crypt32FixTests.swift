// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
import TestSupport
@testable import Launch

@Suite(.timeLimit(.minutes(1))) struct Crypt32FixTests {
    @Test func managerCopiesBeforeSpawnAndPersistsComponentPinForRecovery() async throws {
        let f = try await ManagerFixture.make()
        let source = f.paths.runtimes.appendingPathComponent("crypt32-fix")
        let payload = Data("verified Wine component fixture".utf8)
        try await BlockingIO.run {
            try ContainedFileSystem(root: source).writeAtomically(payload, to: SafeRelativePath("x86_64-windows/crypt32.dll"))
        }
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier(Crypt32Fix.bundleID), root: f.bundle.root,
            wineBinary: f.bundle.wineBinary, digest: f.bundle.digest, source: .download)
        let runtime = ManagerRuntimeProvider(selected: LaunchRuntimeSelection(bundle: bundle, componentIDs: ["wine-a"],
            componentRoots: [.crypt32Fix: source], compatibilityComponentIDs: [.crypt32Fix: Crypt32Fix.componentID]))
        let recipe = LaunchRecipe(game: "zzz-cn", recipeVersion: 1, verifiedBuilds: [], executable: try SafeRelativePath("StarRail.exe"),
            wrapper: .none, blockedHosts: [], hidden: [], copyIfPresent: [], timeoutFix: false, supportsDirectX12: false)
        let manager = LaunchManager(paths: f.paths, runtimes: runtime, prefixes: f.prefixes, preparation: f.preparation,
            spawner: f.spawner, inspector: f.inspector, runner: f.runner, clock: f.clock,
            proxyFactory: { [proxy = f.proxy] _, log in proxy.start(log: log); return proxy }, recipeOverrides: ["zzz-cn": recipe],
            sessionProvenance: { (ManagerFixture.bootSessionUUID, ManagerFixture.sessionStartTime) })
        let stream = await manager.launch(game: try #require(GameDefinition.find("zzz-cn")), installRoot: f.installRoot, gameBuild: "probe")
        let events = ManagerEvents()
        let consumer = Task { for await event in stream { await events.append(event) } }
        await events.wait { switch $0 { case .running, .failed: true; default: false } }
        guard !(await events.values).contains(where: { if case .failed = $0 { true } else { false } }) else {
            Issue.record("Crypt32 component launch failed"); await consumer.value; return
        }
        let snapshot = try await BlockingIO.run { try LaunchJournal(paths: f.paths).read(game: "zzz-cn") }
        #expect(snapshot?.componentIDs.contains(Crypt32Fix.componentID) == true)
        #expect(snapshot?.gameExecutable?.description == "StarRail.exe")
        let published = try await BlockingIO.run {
            try ContainedFileSystem(root: f.prefix).readFile(at: SafeRelativePath("drive_c/windows/system32/crypt32.dll"), maxBytes: 1024)
        }
        #expect(published == payload)
        await manager.markReady(game: "zzz-cn")
        try await f.end(manager)
        await consumer.value
        await manager.waitForSupervision(game: "zzz-cn")
        await manager.flushLogs()
    }

    @Test(arguments: GameDefinition.all.map(\.id), [RuntimeBackend.d3dmetal, .dxmt])
    func scopedToTwoCNEditionsAndWine1120(game: String, backend: RuntimeBackend) throws {
        let recipe = try #require(Recipes.recipe(for: game))
        var settings = LaunchSettings.defaults(for: game); settings.backend = backend
        let component = URL(fileURLWithPath: "/Components/crypt32-fix")
        let roots: [ComponentKind: URL] = [.crypt32Fix: component, .steamShim: URL(fileURLWithPath: "/Components/steam"),
            .jadeite: URL(fileURLWithPath: "/Components/jadeite")]
        for bundle in [Crypt32Fix.bundleID, "d3dmetal-wine11.21-gptk4.0b3"] {
            let value = try LaunchResolver.resolve(recipe: recipe, settings: settings,
                installRoot: URL(fileURLWithPath: "/Games/game"), prefix: URL(fileURLWithPath: "/Prefixes/game"),
                wineBinary: URL(fileURLWithPath: "/Runtimes/bin/wine"), proxyPort: 1234, componentRoots: roots,
                baseEnvironment: ["WINEDLLPATH": "/foreign", "WINEDLLOVERRIDES": "crypt32=b"], runtimeBundleID: bundle)
            let affected = ["genshin-cn", "zzz-cn"].contains(game) && backend == .d3dmetal && bundle == Crypt32Fix.bundleID
            #expect(value.environment["WINEDLLPATH"] == nil)
            #expect(value.environment["WINEDLLOVERRIDES"] == (affected ? "crypt32=n,b" : ""))
            #expect(value.requiredComponents.contains(.crypt32Fix) == affected)
            #expect(value.componentCopies.count == (affected ? 1 : 0))
            #expect(value.preparation.crypt32Native == affected)
            if let copy = value.componentCopies.first {
                #expect(copy.root == component)
                #expect(copy.source.description == "x86_64-windows/crypt32.dll")
                #expect(copy.toSystem32 == "crypt32.dll")
            }
        }
    }

    @Test func missingFixBlocksEvenWithGamePatchesDisabled() throws {
        let recipe = try #require(Recipes.recipe(for: "zzz-cn"))
        var settings = LaunchSettings.defaults(for: "zzz-cn"); settings.compatibilityPatches = false
        #expect(LaunchResolver.requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: Crypt32Fix.bundleID) == [.crypt32Fix])
        #expect(throws: LauncherError.self) {
            try LaunchResolver.resolve(recipe: recipe, settings: settings, installRoot: URL(fileURLWithPath: "/game"),
                prefix: URL(fileURLWithPath: "/prefix"), wineBinary: URL(fileURLWithPath: "/runtime/wine"),
                proxyPort: 1234, componentRoots: [:], baseEnvironment: [:], runtimeBundleID: Crypt32Fix.bundleID)
        }
    }

    @Test func requiredCopyNeverSilentlySkipsMissingDLL() throws {
        let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
        try fs.createDirectory(at: SafeRelativePath("component"))
        try fs.createDirectory(at: SafeRelativePath("prefix/drive_c/windows/system32"))
        #expect(throws: LauncherError.self) {
            try LaunchCopies.copyRequired([(try SafeRelativePath("x86_64-windows/crypt32.dll"), "crypt32.dll")],
                componentRoot: temp.url.appendingPathComponent("component"),
                system32: temp.url.appendingPathComponent("prefix/drive_c/windows/system32"), log: nil)
        }
        #expect(try fs.contentsOfDirectory(at: SafeRelativePath("prefix/drive_c/windows/system32")).isEmpty)
    }
}
