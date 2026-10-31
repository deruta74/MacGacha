// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// Unix module ABI-scoped to one Wine bundle. Installing it never enables it;
/// launch integration opts in through a verified per-game runtime helper.
public enum SurroundAudio {
    public static let bundleID = "d3dmetal-wine11.20-gptk4.0b3"
    public static let componentID = "surround-audio-wine-11.20-1"
    public static func applies(game: String, backend: RuntimeBackend, bundleID: String?) -> Bool {
        guard backend == .d3dmetal, bundleID == Self.bundleID, let family = GameDefinition.find(game)?.family else { return false }
        return family == .genshin || family == .zzz
    }
    public static let modulePath = try! SafeRelativePath("x86_64-unix/winecoreaudio.so")
}
