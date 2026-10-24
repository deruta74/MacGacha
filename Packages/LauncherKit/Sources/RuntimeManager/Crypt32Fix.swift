// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// This Wine DLL is ABI-scoped to one bundle, independently of game patches.
/// Drop this requirement when that bundle is replaced by Wine 11.21 or newer.
public enum Crypt32Fix {
    public static let bundleID = "d3dmetal-wine11.20-gptk4.0b3"
    public static let componentID = "crypt32-fix-wine-11.20-1"
    public static func applies(game: String, backend: RuntimeBackend, bundleID: String?) -> Bool {
        guard backend == .d3dmetal, bundleID == Self.bundleID, let definition = GameDefinition.find(game) else { return false }
        return definition.region == .mainlandChina && [.genshin, .zzz].contains(definition.family)
    }
}
