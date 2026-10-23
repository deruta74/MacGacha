// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import Launch

@Test func winePathWithColonAndSpaces() {
    let url = URL(fileURLWithPath: "/Users/x/Games/MacGacha/Honkai: Star Rail/StarRail.exe")
    #expect(WinePath.windowsPath(for: url) == #"Z:\Users\x\Games\MacGacha\Honkai: Star Rail\StarRail.exe"#)
}

@Test func winePathPreservesUnicodeAndLiteralPercent() {
    #expect(WinePath.windowsPath(for: URL(fileURLWithPath: "/Games/游戏 100%/game.exe")) == #"Z:\Games\游戏 100%\game.exe"#)
}
