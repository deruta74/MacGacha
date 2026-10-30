// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

public struct LaunchComponentCopy: Equatable, Sendable {
    public let root: URL
    public let source: SafeRelativePath
    public let toSystem32: String
}

public struct ResolvedLaunch: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL
    public let hidden: [SafeRelativePath]
    public let copyIfPresent: [(source: SafeRelativePath, toSystem32: String)]
    public let blockedHosts: [String]
    public let preparation: PreparationRequest
    public let requiredComponents: [ComponentKind]
    public let componentCopies: [LaunchComponentCopy]
    public let displayFallback: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.executable == rhs.executable && lhs.arguments == rhs.arguments && lhs.environment == rhs.environment
            && lhs.currentDirectory == rhs.currentDirectory && lhs.hidden == rhs.hidden
            && lhs.copyIfPresent.elementsEqual(rhs.copyIfPresent, by: { $0.source == $1.source && $0.toSystem32 == $1.toSystem32 })
            && lhs.blockedHosts == rhs.blockedHosts && lhs.preparation == rhs.preparation && lhs.requiredComponents == rhs.requiredComponents
            && lhs.componentCopies == rhs.componentCopies && lhs.displayFallback == rhs.displayFallback
    }
}

public enum LaunchResolver {
    /// Shared with setup availability; checking requirements never needs component files.
    public static func requiredComponents(recipe: LaunchRecipe, settings: LaunchSettings, runtimeBundleID: String?) -> [ComponentKind] {
        var required: [ComponentKind] = []
        if settings.compatibilityPatches {
            switch recipe.wrapper { case .none: break; case .jadeite: required.append(.jadeite); case .steamShim: required.append(.steamShim) }
        }
        if Crypt32Fix.applies(game: recipe.game, backend: settings.backend, bundleID: runtimeBundleID) { required.append(.crypt32Fix) }
        return required
    }
    public static func resolve(recipe: LaunchRecipe, settings: LaunchSettings, installRoot: URL, prefix: URL,
        wineBinary: URL, proxyPort: UInt16, componentRoots: [ComponentKind: URL], baseEnvironment: [String: String],
        runtimeBundleID: String? = nil, displays: [String] = []) throws -> ResolvedLaunch {
        guard Recipes.recipe(for: recipe.game) != nil else { throw LauncherError.io("Unknown launch game: \(recipe.game)") }
        try settings.validate()
        for url in [installRoot, prefix, wineBinary] { try validateLocalURL(url) }

        let gamePath = WinePath.windowsPath(for: recipe.executable.resolved(against: installRoot))
        var arguments = [gamePath]
        let requiredComponents = requiredComponents(recipe: recipe, settings: settings, runtimeBundleID: runtimeBundleID)
        for kind in requiredComponents { _ = try requiredRoot(kind, in: componentRoots) }
        var componentCopies: [LaunchComponentCopy] = []
        var steamShim: URL?
        if settings.compatibilityPatches {
            switch recipe.wrapper {
            case .none: break
            case .jadeite:
                let root = try requiredRoot(.jadeite, in: componentRoots)
                arguments.insert(WinePath.windowsPath(for: root.appendingPathComponent("jadeite.exe")), at: 0)
            case .steamShim:
                steamShim = try requiredRoot(.steamShim, in: componentRoots)
                arguments.insert(#"C:\windows\system32\steam.exe"#, at: 0)
            }
        }
        var displayFallback = false
        if !displays.isEmpty {
            let selected = settings.display.flatMap { choice in
                displays.firstIndex { $0.caseInsensitiveCompare(choice.id) == .orderedSame }
            }
            displayFallback = settings.display != nil && selected == nil
            arguments.append(contentsOf: ["-monitor", String((selected ?? 0) + 1)])
        }
        if recipe.supportsDirectX12 && settings.directX12 && settings.backend == .d3dmetal {
            arguments.append("-use-d3d12")
        }
        if settings.compatibilityPatches, case .jadeite = recipe.wrapper, arguments.count > 2 {
            // Jadeite reserves argv[2] for a launcher. "--" selects explorer.exe
            // and forwards the remaining arguments to the game's command line.
            arguments.insert("--", at: 2)
        }

        let basics: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
        var environment = baseEnvironment.filter { basics.contains($0.key) || $0.key.hasPrefix("LC_") }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDLLOVERRIDES"] = ""
        if requiredComponents.contains(.crypt32Fix) {
            environment["WINEDLLOVERRIDES"] = "crypt32=n,b"
            componentCopies.append(LaunchComponentCopy(root: try requiredRoot(.crypt32Fix, in: componentRoots),
                source: try SafeRelativePath("x86_64-windows/crypt32.dll"), toSystem32: "crypt32.dll"))
        }
        environment["WINEDEBUG"] = "fixme-all"
        let proxy = "http://127.0.0.1:\(proxyPort)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { environment[key] = proxy }
        if settings.compatibilityPatches && recipe.timeoutFix { environment["WINE_ENABLE_TIMEOUT_FIX"] = "1" }

        let dxmt = settings.backend == .dxmt, starRail = GameDefinition.find(recipe.game)?.family == .starrail
        switch settings.backend {
        case .d3dmetal:
            environment["WINEESYNC"] = "1"
            if let limit = settings.frameLimit { environment["D3DM_MAX_FPS"] = String(limit) }
        case .dxmt:
            environment["WINEMSYNC"] = "1"
            environment["GST_PLUGIN_FEATURE_RANK"] = "atdec:MAX,avdec_h264:MAX"
            var config: [String] = []
            if let limit = settings.frameLimit { config.append("d3d11.preferredMaxFrameRate=\(limit)") }
            if starRail {
                config.append(contentsOf: ["dxgi.customVendorId=10de", "dxgi.customDeviceId=2684"])
                environment["DXMT_ENABLE_NVEXT"] = "1"
            }
            if !config.isEmpty { environment["DXMT_CONFIG"] = config.joined(separator: ";") }
        }
        return ResolvedLaunch(executable: wineBinary, arguments: arguments, environment: environment,
            currentDirectory: installRoot, hidden: settings.compatibilityPatches ? recipe.hidden : [],
            copyIfPresent: settings.compatibilityPatches ? recipe.copyIfPresent : [],
            blockedHosts: settings.compatibilityPatches ? recipe.blockedHosts : [],
            preparation: PreparationRequest(retina: settings.retina, steamShim: steamShim,
                dxmtExtras: dxmt ? (["winemetal.dll"] + (starRail ? ["nvngx.dll"] : [])) : [], nvidiaKeys: dxmt && starRail,
                crypt32Native: requiredComponents.contains(.crypt32Fix)),
            requiredComponents: requiredComponents, componentCopies: componentCopies, displayFallback: displayFallback)
    }

    private static func requiredRoot(_ kind: ComponentKind, in roots: [ComponentKind: URL]) throws -> URL {
        guard let root = roots[kind] else { throw LauncherError.io("Missing required component: \(kind.rawValue)") }
        try validateLocalURL(root)
        return root
    }

    private static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
            url.host == nil || url.host == "" || url.host == "localhost" else { throw LauncherError.unsafePath(url.absoluteString) }
    }
}
