// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import GameLibrary
import Launch
import RuntimeManager

#if DEBUG
extension AppModel {
    static func debugPreview(defaults: UserDefaults) -> AppModel? {
        let region = initialRegion(defaults: defaults, locale: .current)
        let name = defaults.string(forKey: "MacGachaDebugGameState")
        let notice = defaults.bool(forKey: "MacGachaDebugRecoveryNotice")
        let games = LauncherGame.games(in: region)
        let model: AppModel?
        if let name, ["predownloadAvailable", "predownloading", "predownloadPaused", "predownloadReady"].contains(name) {
            let preview = preview(logLines: [], games: Dictionary(uniqueKeysWithValues:
                games.map { ($0.id, GameState(status: .installed(tag: "7.1.0"))) }), region: region)
            preview.debugLaunchRuntimesReady = true
            for game in games {
                let ready = name == "predownloadReady"
                let paused = name == "predownloadPaused"
                let info = PreDownloadInfo(state: ready ? .ready : paused ? .paused : .available, version: "7.2.0",
                    bytes: 8_400_000_000, downloaded: ready ? 8_400_000_000 : paused ? 3_528_000_000 : 0, canDelete: ready || paused)
                var overlay = PreDownloadOverlay(info: info)
                if name == "predownloading" {
                    overlay.state = .downloading(PreDownloadProgress(isResolving: false, downloaded: 3_528_000_000,
                        total: 8_400_000_000, fraction: 0.42, bytesPerSecond: 47_000_000))
                }
                preview.preDownloads[game.id] = overlay
            }
            model = preview
        } else if let name, let state = debugGameState(name) {
            model = preview(logLines: [], games: Dictionary(uniqueKeysWithValues: games.map { ($0.id, state) }), region: region)
        } else if let name, name.hasPrefix("busy") {
            let requested = name == "busy" ? nil : GameDefinition.find(String(name.dropFirst(5)))
            let busy = GameDefinition.inRegion(region).first { $0.family == (requested?.family ?? .genshin) }!.id
            let downloading = GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.12,
                bytesPerSecond: 215_500_000, downloaded: 18_100_000_000, total: 146_480_000_000))
            model = preview(rows: [], logLines: [], games: Dictionary(uniqueKeysWithValues: games.map {
                ($0.id, $0.id == busy ? downloading : GameState(status: .notInstalled))
            }), region: region)
            model?.gameOperation = GameOperationToken(id: busy, generation: UUID())
        } else if let name, name.hasPrefix("dependencies") {
            let scenario = defaults.string(forKey: "MacGachaDebugAutoUpdate")
            // The consent case is about the footer, so every game is installed and idle.
            let preview = scenario == "consent"
                ? preview(rows: [], logLines: [], games: Dictionary(uniqueKeysWithValues:
                    games.map { ($0.id, GameState(status: .installed(tag: "7.1.0"))) }), region: region)
                : preview(rows: [], logLines: [], region: region)
            if scenario == "off" { preview.autoUpdateDependencies = false }
            if scenario == "consent" { preview.runtimeUpdatesAwaitingConsent = Set(games.map(\.id)) }
            Task { await preview.loadDebugDependencies(installing: name == "dependenciesInstalling", autoUpdate: scenario) }
            model = preview
        } else { model = debugLaunchPreview(state: name, recoveryNotice: notice, region: region) }
        if notice, let recovery = debugRecoveryNotice(in: region) { model?.recoveryNotices = [recovery] }
        return model
    }

    /// Debug-only stand-in for catalog r3: MacGacha Wine 11.20 is recommended for both
    /// graphics layers, ahead of every bundle the app ships today. The shipped manifest and
    /// the published catalog stay untouched. `newerGraphics` adds an invented later D3DMetal
    /// for the import-offer screenshots only.
    private static func debugManifest(_ bundled: RuntimeManifest, newerGraphics: Bool) throws -> RuntimeManifest {
        func variant(of id: String, as newID: String, version: String) throws -> RuntimeComponent {
            guard let original = bundled.components.first(where: { $0.id.rawValue == id }),
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] else {
                throw LauncherError.io("Debug runtime component is missing")
            }
            json["id"] = newID; json["version"] = version
            return try JSONDecoder().decode(RuntimeComponent.self, from: JSONSerialization.data(withJSONObject: json))
        }
        var components = bundled.components
        var bundles = bundled.bundles
        if newerGraphics {
            // After the active bundle: a preview model reads the full manifest, where the
            // first bundle per graphics layer is what Play needs. The offer never blocks Play.
            components.append(try variant(of: "d3dmetal-4.0b3", as: "d3dmetal-4.0b4", version: "4.0b4"))
            bundles.insert(try RuntimeBundle(id: SafeIdentifier("d3dmetal-wine11.20mg1.0-gptk4.0b4"), displayName: "D3DMetal",
                summary: "MacGacha Wine 11.20 · Apple D3DMetal 4.0 beta 4", backend: .d3dmetal,
                components: [SafeIdentifier("wine-11.20-macgacha-1.0"), SafeIdentifier("d3dmetal-4.0b4")]), at: 2)
        }
        return try RuntimeManifest(components: components, bundles: bundles)
    }

    /// A mix of states over the debug catalog: both graphics layers on our Wine, the older
    /// builds still on disk, a missing helper and an extra. `-MacGachaDebugAutoUpdate` picks
    /// one automatic-update moment for the DXMT card (`installing`, `waiting`, `keeping`,
    /// `off`), the D3DMetal card (`offered`, `declined`) or the footer (`consent`).
    private func loadDebugDependencies(installing: Bool, autoUpdate: String?) async {
        let offer = autoUpdate == "offered" || autoUpdate == "declined"
        guard let bundled = try? await BundledRuntimeManifest.load(),
            let manifest = try? Self.debugManifest(bundled, newerGraphics: offer),
            var snapshot = try? await RuntimeCatalogService(baseline: manifest).snapshot() else { return }
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func component(_ id: String) -> InstalledComponent? {
            guard let item = manifest.components.first(where: { $0.id.rawValue == id }) else { return nil }
            return try? InstalledComponent(kind: item.kind, version: item.version.rawValue, installedAt: date, source: .download)
        }
        let digest = try! Digest(algorithm: .sha256, hex: String(repeating: "0", count: 64))
        let root = URL(fileURLWithPath: "/var/empty")
        let ours = "dxmt-wine11.20mg1.0-dxmt0.80", crossover = "dxmt-wine11.0cx-dxmt0.80"
        let ourMetal = "d3dmetal-wine11.20mg1.0-gptk4.0b3", oldMetal = "d3dmetal-wine11.20-gptk4.0b3"
        var bundles = [ours, crossover, ourMetal]
        var working: [String: RowState] = installing ? ["genshin-fps-unlock-2": .working(phase: .staging, fraction: 0.42)] : [:]
        var selections = snapshot.selections
        func use(_ id: String, for backend: RuntimeBackend) {
            selections.bundles[backend] = RuntimeCatalogSelection(id: try! SafeIdentifier(id))
        }
        use(ours, for: .dxmt); use(ourMetal, for: .d3dmetal)
        switch autoUpdate {
        case "installing":
            use(crossover, for: .dxmt); bundles = [crossover, ourMetal]
            working[ours] = .working(phase: .staging, fraction: 0.42)
            dependencyAutoUpdates["bundle-dxmt"] = .installing(id: ours)
        case "waiting":
            use(crossover, for: .dxmt)
            dependencyAutoUpdates["bundle-dxmt"] = .waitingToActivate(id: ours)
        case "keeping":
            dependencyAutoUpdates["bundle-dxmt"] = .keepingPrevious(id: crossover)
        case "off":
            use(crossover, for: .dxmt); bundles = [crossover, ourMetal]
        case "offered":
            dependencyAutoUpdates["bundle-d3dmetal"] = .graphicsUpdateOffered(id: "d3dmetal-wine11.20mg1.0-gptk4.0b4")
        case "declined":
            dependencyAutoUpdates["bundle-d3dmetal"] = .graphicsUpdateDeclined(id: "d3dmetal-wine11.20mg1.0-gptk4.0b4")
        case "consent":
            // The selection already names the new bundle here, so the existing setup plan
            // lists it. The real coordinator decides how the pending update reaches the plan.
            bundles = [ours, oldMetal]
        default: break
        }
        snapshot = (try? snapshot.replacingSelections(selections)) ?? snapshot
        applyRuntimeCatalog(snapshot)
        debugRuntimeState(
            installed: ["jadeite-4.1.0", "steam-shim-proton-10.0-4", "surround-audio-wine-11.20-1"].compactMap(component),
            bundles: Dictionary(uniqueKeysWithValues: bundles.map { id in (id, InstalledRuntimeBundle(id: try! SafeIdentifier(id),
                root: root, wineBinary: root, digest: digest, source: id.hasPrefix("d3dmetal") ? .importFromGPTK : .download)) }),
            working: working)
    }

    private static func debugGameState(_ name: String) -> GameState? {
        let time = ContinuousClock.now
        let eta = GameTiming(phaseStarted: time.advanced(by: .seconds(-60)), lastAdvance: time,
            remaining: .seconds(12 * 60), hasFraction: true)
        return switch name {
        case "preparing": GameState(status: .notInstalled, activity: .resolving)
        case "progress": GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.42, bytesPerSecond: 47_000_000, downloaded: 57_300_000_000, total: 136_500_000_000), timing: eta)
        case "verifying": GameState(status: .installed(tag: "7.1.0"), activity: .working(.verifying, fraction: 0.42, bytesPerSecond: nil), timing: eta)
        case "installingSlow": GameState(status: .notInstalled, activity: .working(.committing, fraction: nil, bytesPerSecond: nil),
            timing: GameTiming(phaseStarted: time.advanced(by: .seconds(-180)), lastAdvance: time.advanced(by: .seconds(-180)), remaining: nil, hasFraction: false))
        case "downloadStalled": GameState(status: .notInstalled, activity: .working(.staging, fraction: 0.42, bytesPerSecond: 0, downloaded: 57_300_000_000, total: 136_500_000_000),
            timing: GameTiming(phaseStarted: time.advanced(by: .seconds(-60)), lastAdvance: time.advanced(by: .seconds(-45)), remaining: .seconds(12 * 60), hasFraction: true))
        case "parts": GameState(status: .paused(.install), activity: .needsApproval(required: 150_000_000_000, available: 60_000_000_000))
        case "install": GameState(status: .notInstalled)
        case "resume": GameState(status: .paused(.update))
        case "uninstall": GameState(status: .uninstallPaused)
        case "update": GameState(status: .updateAvailable(from: "7.1.0", to: "7.2.0"))
        case "location": GameState(status: .locationUnavailable(URL(fileURLWithPath: "/Volumes/Games SSD/MacGacha/Genshin Impact")))
        case "installed": GameState(status: .installed(tag: "7.1.0"))
        default: nil
        }
    }

    /// Inert screenshot data: no launch, filesystem mutation or recovery is run.
    static func debugLaunchPreview(state name: String?, recoveryNotice: Bool, region: Region = .global) -> AppModel? {
        let state: LaunchUIState?
        switch name {
        case "playing": state = .running
        case "launching": state = .starting(.prepare)
        case "launchFailed": state = .failed(LaunchFailureInfo(stage: .watch,
            message: String(localized: "The game closed during startup."), hasLog: true, unverifiedBuild: false))
        case "recoveryNeeded": state = .recoveryNeeded(String(localized: "MacGacha is putting the game's files back. You can play when it's done."))
        default: state = nil
        }
        // `ready` is an idle installed game with every runtime present, so the footer shows Play.
        guard state != nil || recoveryNotice || name == "ready" else { return nil }
        let model = AppModel.preview(logLines: [], games: Dictionary(uniqueKeysWithValues:
            LauncherGame.games(in: region).map { ($0.id, GameState(status: .installed(tag: "1.0"))) }), region: region)
        model.debugLaunchRuntimesReady = true
        for game in LauncherGame.games(in: region) {
            model.launchStates[game.id] = state
        }
        let owner = LauncherGame.games(in: region)[1].id
        if ["playing", "launching", "recoveryNeeded"].contains(name) { model.launchSlotOwner = owner }
        if name == "playing" || name == "launching" { model.liveLaunchGames.insert(owner) }
        if recoveryNotice, let notice = debugRecoveryNotice(in: region) { model.recoveryNotices = [notice] }
        return model
    }

    private static func debugRecoveryNotice(in region: Region) -> RecoveryNotice? {
        let game = LauncherGame.games(in: region)[1].id
        let json = """
        {"id":"C2579465-61CA-4445-8C35-F00FF1395516","game":"\(game)",\
        "movedTo":["file:///Volumes/Games/MacGacha/.macgacha-recovery/example/crashreport.exe"]}
        """
        return try? JSONDecoder().decode(RecoveryNotice.self, from: Data(json.utf8))
    }
}
#endif
