// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// Packaging identity only. Installation never starts or enables the helper.
/// It is independent of the graphics backend and is not a launch requirement.
public enum GenshinFps {
    public static let componentID = "genshin-fps-unlock-2"
    public static let version = "2"
    public static let injectorPath = try! SafeRelativePath("fpsinject.exe")
    public static let stubPath = try! SafeRelativePath("fpsstub.dll")
    public static func applies(to game: String) -> Bool {
        GameDefinition.find(game)?.family == .genshin
    }
}
