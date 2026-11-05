// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import RuntimeManager
@testable import Launch

@Suite struct RuntimeProfileTests {
    @Test func helperProfileMustMatchResolvedRecipeProfile() throws {
        let root = URL(fileURLWithPath: "/tmp/runtime-profile-fixture")
        let game = GameDefinition.find("genshin")!
        let helper = GameModeRuntime(game: game, root: root, wineBinary: root.appendingPathComponent("MacOS/wine"),
            wineserver: root.appendingPathComponent("bin/wineserver"), runtimeProfileID: "wrong-profile")
        let settings = LaunchSettings(backend: .d3dmetal, retina: true, frameLimit: nil, directX12: false, compatibilityPatches: false)
        #expect(throws: (any Error).self) {
            try LaunchResolver.resolve(recipe: Recipes.recipe(for: game.id)!, settings: settings,
                installRoot: root, prefix: root, wineBinary: root.appendingPathComponent("bin/wine"), proxyPort: 0,
                componentRoots: [:], baseEnvironment: [:], runtimeBundleID: SurroundAudio.bundleID, gameModeRuntime: helper)
        }
    }

    @Test func actualBundleIdentityIsSeparateFromCompiledProfile() throws {
        let root = URL(fileURLWithPath: "/tmp/runtime-profile-fixture")
        let bundle = InstalledRuntimeBundle(id: try SafeIdentifier("metal-revision3"), root: root,
            wineBinary: root.appendingPathComponent("bin/wine"), digest: try Digest(algorithm: .sha256, hex: String(repeating: "1", count: 64)), source: .download)
        let selection = LaunchRuntimeSelection(bundle: bundle, componentIDs: ["wine-revision3"], componentRoots: [:],
            runtimeProfileID: SurroundAudio.bundleID)
        #expect(selection.bundle.id.rawValue == "metal-revision3")
        #expect(selection.runtimeProfileID == SurroundAudio.bundleID)
        #expect(LaunchResolver.offersSurroundSound("genshin", backend: .d3dmetal, runtimeBundleID: selection.runtimeProfileID))
        let legacy = LaunchRuntimeSelection(bundle: bundle, componentIDs: ["wine-revision3"], componentRoots: [:])
        #expect(legacy.runtimeProfileID == bundle.id.rawValue)
    }
}
