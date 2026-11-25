// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Launch
import RuntimeManager

struct LaunchChangedValue: Equatable {
    let field: String
    let label: String
    let previous: String
    let attempted: String
}

struct LaunchConfigurationDisplay: Equatable {
    let gameBuild: String
    let runtime: String
    let components: String
    let backend: String
}

enum LaunchDiagnosticText {
    static func configurationDisplay(_ configuration: LaunchConfiguration, manifest: RuntimeManifest?) -> LaunchConfigurationDisplay {
        LaunchConfigurationDisplay(gameBuild: configuration.gameBuild, runtime: runtimeName(configuration, manifest: manifest),
            components: ListFormatter.localizedString(byJoining: configuration.componentIDs.map { componentName($0, manifest: manifest) }),
            backend: backendName(configuration.settings.backend))
    }

    static func changedValues(previous: LaunchConfiguration, attempted: LaunchConfiguration, manifest: RuntimeManifest? = nil) -> [LaunchChangedValue] {
        var rows: [LaunchChangedValue] = []
        func add(_ field: String, _ label: String, _ old: String, _ new: String, changed: Bool? = nil) {
            if changed ?? (old != new) { rows.append(LaunchChangedValue(field: field, label: label, previous: old, attempted: new)) }
        }
        func flag(_ value: Bool) -> String { value ? String(localized: "On") : String(localized: "Off") }
        func helpers(_ value: LaunchConfiguration) -> String {
            value.compatibilityComponentIDs.sorted { $0.key.rawValue < $1.key.rawValue }.map {
                componentName($0.value, manifest: manifest)
            }.joined(separator: "\n")
        }
        let differentBuildID = previous.gameBuildID != attempted.gameBuildID
        let sameTag = previous.gameBuild == attempted.gameBuild
        if !sameTag || differentBuildID {
            add("game", String(localized: "Game build"),
                buildName(previous, includesID: sameTag), buildName(attempted, includesID: sameTag))
        }
        let sameBundle = previous.bundleID == attempted.bundleID
        let differentFiles = previous.runtimeDigest != attempted.runtimeDigest
        if !sameBundle || differentFiles || previous.runtimeProfileID != attempted.runtimeProfileID {
            let priorName = runtimeName(previous, manifest: manifest)
            let attemptedName = runtimeName(attempted, manifest: manifest)
            let attemptedLabel = sameBundle && differentFiles
                ? [attemptedName, String(localized: "Same version, different files")].joined(separator: "\n")
                : attemptedName
            add("runtime", String(localized: "Runtime"), priorName, attemptedLabel, changed: true)
        }
        if previous.componentIDs != attempted.componentIDs {
            let oldComponents = previous.componentIDs.map { componentName($0, manifest: manifest) }
            let newComponents = attempted.componentIDs.map { componentName($0, manifest: manifest) }
            add("components", String(localized: "Components"), oldComponents.joined(separator: "\n"),
                newComponents.joined(separator: "\n"), changed: true)
        }
        if previous.compatibilityComponentIDs != attempted.compatibilityComponentIDs {
            add("helpers", String(localized: "Compatibility components"), helpers(previous), helpers(attempted), changed: true)
        }
        add("recipe", String(localized: "Launch recipe"), previous.recipeVersion.formatted(), attempted.recipeVersion.formatted())
        if let oldMode = previous.gameModeEnabled, let newMode = attempted.gameModeEnabled {
            add("gameMode", String(localized: "Game Mode"), flag(oldMode), flag(newMode))
        }
        let old = previous.settings, new = attempted.settings
        add("backend", String(localized: "Graphics"), backendName(old.backend), backendName(new.backend))
        add("retina", String(localized: "Retina resolution"), flag(old.retina), flag(new.retina))
        add("frameLimit", String(localized: "Frame limit"), old.frameLimit?.formatted() ?? String(localized: "Off"), new.frameLimit?.formatted() ?? String(localized: "Off"))
        add("directX12", String(localized: "DirectX 12"), flag(old.directX12), flag(new.directX12))
        add("patches", String(localized: "Compatibility patches"), flag(old.compatibilityPatches), flag(new.compatibilityPatches))
        add("display", String(localized: "Display"), old.display?.name ?? String(localized: "Main Display"),
            new.display?.name ?? String(localized: "Main Display"), changed: old.display != new.display)
        add("surround", String(localized: "Surround sound"), flag(old.surroundSound), flag(new.surroundSound))
        add("metalHUD", String(localized: "Metal HUD"), flag(old.metalHUD), flag(new.metalHUD))
        add("hudContents", String(localized: "Contents"), MetalHUDDisplayName.name(of: old.metalHUDContents), MetalHUDDisplayName.name(of: new.metalHUDContents))
        add("hudElements", String(localized: "Metal HUD"), old.metalHUDElements.map { MetalHUDDisplayName.name(of: $0) }.joined(separator: ", "), new.metalHUDElements.map { MetalHUDDisplayName.name(of: $0) }.joined(separator: ", "))
        add("hudPosition", String(localized: "Position"), MetalHUDDisplayName.name(of: old.metalHUDPosition), MetalHUDDisplayName.name(of: new.metalHUDPosition))
        add("hudSize", String(localized: "Size"), MetalHUDDisplayName.name(of: old.metalHUDSize), MetalHUDDisplayName.name(of: new.metalHUDSize))
        add("unlockFPS", String(localized: "Unlock frame rate"), flag(old.unlockFPS), flag(new.unlockFPS))
        add("unlockTarget", String(localized: "Target"), old.unlockTarget.formatted(), new.unlockTarget.formatted())
        return rows
    }

    private static func buildName(_ configuration: LaunchConfiguration, includesID: Bool) -> String {
        guard includesID, let id = configuration.gameBuildID else { return configuration.gameBuild }
        return [configuration.gameBuild, id].joined(separator: "\n")
    }

    private static func runtimeName(_ configuration: LaunchConfiguration, manifest: RuntimeManifest?) -> String {
        manifest?.bundles.first { $0.id.rawValue == configuration.bundleID }?.displayName ?? configuration.bundleID
    }

    private static func componentName(_ id: String, manifest: RuntimeManifest?) -> String {
        guard let component = manifest?.components.first(where: { $0.id.rawValue == id }) else { return id }
        return String(localized: "\(AppModel.kindName(component.kind)) \(component.version.rawValue)",
            comment: "Runtime component name followed by its version")
    }

    private static func backendName(_ backend: RuntimeBackend) -> String {
        switch backend {
        case .d3dmetal: String(localized: "D3DMetal", comment: "Graphics backend name; usually not translated")
        case .dxmt: String(localized: "DXMT", comment: "Graphics backend name; usually not translated")
        }
    }

    /// Configuration changes are possible leads when no typed evidence establishes a cause.
    static func explanation(_ failure: LaunchFailureInfo) -> String {
        if failure.cause == .antiCheatOffline { return String(localized: "The game could not reach its servers. Check your connection or try another network.") }
        switch failure.diagnosis?.reason ?? .unknown {
        case .runtime: return String(localized: "The selected runtime is unavailable. Check Dependencies.")
        case .process: return String(localized: "A required tool could not finish. Check Diagnostics for details.")
        case .busy: return failure.message
        case .rosetta: return String(localized: "Rosetta 2 is required to run games. Install it using MacGacha, then try again.")
        case .location: return LaunchFailureInfo.locationUnavailableLine
        case .gameFiles: return String(localized: "The game executable is missing. Verify Files.")
        case .network: return String(localized: "The game could not reach its servers. Check your connection or try another network.")
        case .unknown:
            let changes = failure.diagnosis?.comparison?.changes ?? []
            if changes.contains(.game) { return String(localized: "The game build changed. The update may have affected compatibility.") }
            if changes.contains(.backend) { return String(localized: "The graphics backend changed and may be involved.") }
            if changes.contains(.runtime) { return String(localized: "The runtime changed and may be involved.") }
            if changes.contains(.settings) { return String(localized: "Launch settings changed and may be involved.") }
            return String(localized: "The cause could not be determined.")
        }
    }
}

enum MetalHUDDisplayName {
    nonisolated static func name(of contents: MetalHUDContents) -> String {
        switch contents {
        case .standard: String(localized: "Standard", comment: "Metal HUD contents or size: Apple's default")
        case .fpsOnly: String(localized: "FPS Only", comment: "Metal HUD contents")
        case .full: String(localized: "Full", comment: "Metal HUD contents: every main metric")
        case .custom: String(localized: "Custom")
        }
    }

    nonisolated static func name(of element: MetalHUDElement) -> String {
        switch element {
        case .device: String(localized: "Device and macOS version", comment: "Metal HUD element")
        case .rosetta: String(localized: "Rosetta", comment: "Metal HUD element: whether the game runs through Rosetta")
        case .layersize: String(localized: "Resolution", comment: "Metal HUD element: the game's render size")
        case .memory: String(localized: "Memory", comment: "Metal HUD element")
        case .refreshrate: String(localized: "Refresh rate", comment: "Metal HUD element: display refresh rate")
        case .thermal: String(localized: "Thermal state", comment: "Metal HUD element")
        case .gamemode: String(localized: "Game Mode", comment: "Metal HUD element: whether macOS Game Mode is on")
        case .fps: String(localized: "FPS", comment: "Metal HUD element: frames per second")
        case .fpsgraph: String(localized: "FPS graph", comment: "Metal HUD element")
        case .frameinterval: String(localized: "Frame time", comment: "Metal HUD element: time between frames")
        case .frameintervalgraph: String(localized: "Frame time graph", comment: "Metal HUD element")
        case .gputime: String(localized: "GPU time", comment: "Metal HUD element: GPU time per frame")
        case .presentdelay: String(localized: "Present delay", comment: "Metal HUD element: delay before a frame reaches the screen")
        }
    }

    nonisolated static func name(of position: MetalHUDPosition) -> String {
        switch position {
        case .topLeft: String(localized: "Top Left", comment: "Metal HUD position")
        case .topCenter: String(localized: "Top Center", comment: "Metal HUD position")
        case .topRight: String(localized: "Top Right", comment: "Metal HUD position")
        case .centerLeft: String(localized: "Center Left", comment: "Metal HUD position")
        case .centered: String(localized: "Center", comment: "Metal HUD position")
        case .centerRight: String(localized: "Center Right", comment: "Metal HUD position")
        case .bottomLeft: String(localized: "Bottom Left", comment: "Metal HUD position")
        case .bottomCenter: String(localized: "Bottom Center", comment: "Metal HUD position")
        case .bottomRight: String(localized: "Bottom Right", comment: "Metal HUD position")
        }
    }

    nonisolated static func name(of size: MetalHUDSize) -> String {
        switch size {
        case .small: String(localized: "Small", comment: "Metal HUD size")
        case .standard: String(localized: "Standard", comment: "Metal HUD contents or size: Apple's default")
        case .large: String(localized: "Large", comment: "Metal HUD size")
        }
    }
}
