// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

public struct LaunchRecipe: Sendable {
    public enum Wrapper: Sendable { case none, jadeite, steamShim }
    public let game: String
    public let recipeVersion: Int
    public let verifiedBuilds: Set<String>
    public let executable: SafeRelativePath
    public let wrapper: Wrapper
    public let blockedHosts: [String]
    public let hidden: [SafeRelativePath]
    public let copyIfPresent: [(source: SafeRelativePath, toSystem32: String)]
    public let timeoutFix: Bool
    public let supportsDirectX12: Bool
    /// Candidates relative to each Wine user profile (drive_c/users/<profile>).
    public let gameLogPaths: [SafeRelativePath]

    public init(game: String, recipeVersion: Int, verifiedBuilds: Set<String>, executable: SafeRelativePath,
        wrapper: Wrapper, blockedHosts: [String], hidden: [SafeRelativePath],
        copyIfPresent: [(source: SafeRelativePath, toSystem32: String)], timeoutFix: Bool, supportsDirectX12: Bool, gameLogPaths: [SafeRelativePath] = []) {
        self.game = game; self.recipeVersion = recipeVersion; self.verifiedBuilds = verifiedBuilds
        self.executable = executable; self.wrapper = wrapper; self.blockedHosts = blockedHosts
        self.hidden = hidden; self.copyIfPresent = copyIfPresent; self.timeoutFix = timeoutFix
        self.supportsDirectX12 = supportsDirectX12; self.gameLogPaths = gameLogPaths
    }
}
