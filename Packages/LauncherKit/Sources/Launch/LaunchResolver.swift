// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.executable == rhs.executable && lhs.arguments == rhs.arguments && lhs.environment == rhs.environment
            && lhs.currentDirectory == rhs.currentDirectory && lhs.hidden == rhs.hidden
            && lhs.copyIfPresent.elementsEqual(rhs.copyIfPresent, by: { $0.source == $1.source && $0.toSystem32 == $1.toSystem32 })
            && lhs.blockedHosts == rhs.blockedHosts && lhs.preparation == rhs.preparation && lhs.requiredComponents == rhs.requiredComponents
    }
}

public enum LaunchResolver {
    public static func resolve(recipe: LaunchRecipe, settings: LaunchSettings, installRoot: URL, prefix: URL,
        wineBinary: URL, proxyPort: UInt16, componentRoots: [ComponentKind: URL], baseEnvironment: [String: String]) throws -> ResolvedLaunch {
        guard Recipes.recipe(for: recipe.game) != nil else { throw LauncherError.io("Unknown launch game: \(recipe.game)") }
        try settings.validate()
        for url in [installRoot, prefix, wineBinary] { try validateLocalURL(url) }

        let gamePath = WinePath.windowsPath(for: recipe.executable.resolved(against: installRoot))
        var arguments = [gamePath], requiredComponents: [ComponentKind] = []
        var steamShim: URL?
        if settings.compatibilityPatches {
            switch recipe.wrapper {
            case .none: break
            case .jadeite:
                let root = try requiredRoot(.jadeite, in: componentRoots)
                arguments.insert(WinePath.windowsPath(for: root.appendingPathComponent("jadeite.exe")), at: 0)
                requiredComponents = [.jadeite]
            case .steamShim:
                steamShim = try requiredRoot(.steamShim, in: componentRoots)
                arguments.insert(#"C:\windows\system32\steam.exe"#, at: 0)
                requiredComponents = [.steamShim]
            }
        }
        if recipe.supportsDirectX12 && settings.directX12 && settings.backend == .d3dmetal {
            arguments.append("-use-d3d12")
        }

        let basics: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
        var environment = baseEnvironment.filter { basics.contains($0.key) || $0.key.hasPrefix("LC_") }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDLLOVERRIDES"] = ""
        environment["WINEDEBUG"] = "fixme-all"
        let proxy = "http://127.0.0.1:\(proxyPort)"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { environment[key] = proxy }
        if settings.compatibilityPatches && recipe.timeoutFix { environment["WINE_ENABLE_TIMEOUT_FIX"] = "1" }

        let dxmt = settings.backend == .dxmt, starRail = recipe.game == "starrail"
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
                dxmtExtras: dxmt ? (["winemetal.dll"] + (starRail ? ["nvngx.dll"] : [])) : [], nvidiaKeys: dxmt && starRail),
            requiredComponents: requiredComponents)
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
