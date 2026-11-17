// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// Zenless Zone Zero's login SDK saves which renderer its WebView used. Under
/// Wine a saved choice can leave the CN captcha window blank, so every CN launch
/// clears it and the SDK chooses again. Other values under the key stay. Global
/// shows its verification page correctly, so the resolver leaves it unchanged,
/// though both keys are known.
public enum WebViewRenderReset {
    static let savedMethod = "MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267"
    static let experimentPrefix = "HOYO_WEBVIEW_RENDER_METHOD_ABTEST_"
    static let maximumQueryBytes = 1 << 20

    static func registryKey(for region: Region) -> String {
        switch region {
        case .global: "HKCU\\Software\\miHoYo\\ZenlessZoneZero"
        case .mainlandChina: "HKCU\\Software\\miHoYo\\绝区零"
        }
    }

    /// Value names from `reg query` output that hold a saved render method.
    /// Wine may print the CJK key name garbled, so only value lines count.
    public static func valueNames(in output: String) -> [String] {
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let name = String(field)
            guard name == savedMethod || (name.hasPrefix(experimentPrefix) && name.count > experimentPrefix.count),
                name.utf8.allSatisfy({ $0 == UInt8(ascii: "_") || (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) }),
                !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}
