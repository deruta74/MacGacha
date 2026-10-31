// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreGraphics
import ImageIO
import Testing
import LauncherCore
import TestSupport
@testable import RuntimeManager

func gameModeTestPNG(red: CGFloat = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: 0.25, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

struct FixedGameModeIcon: GameModeIconProviding {
    let value: GameModeIcon
    init(red: CGFloat = 1) throws { value = try GameModeIcon.fromImage(gameModeTestPNG(red: red)) }
    func icon(for game: GameDefinition) async throws -> GameModeIcon { value }
}

@Suite struct GameModeIconTests {
    @Test func convertsValidatedImagesToNativeIconsAndKeysTheirContent() throws {
        let first = try GameModeIcon.fromImage(gameModeTestPNG())
        #expect(first.icns.prefix(4) == Data("icns".utf8))
        let source = try #require(CGImageSourceCreateWithData(first.icns as CFData, nil))
        #expect(CGImageSourceGetCount(source) >= 4)
        #expect(try GameModeIcon.fromImage(gameModeTestPNG()).digest == first.digest)
        #expect(try GameModeIcon.fromImage(gameModeTestPNG(red: 0)).digest != first.digest)
        #expect(throws: (any Error).self) { try GameModeIcon.fromImage(Data("invalid".utf8)) }
    }
    @Test func fallbackUsesTheLaunchersOwnIconResources() async throws {
        let temp = try TempDir(), expected = try FixedGameModeIcon().value
        let root = temp.url
        try await BlockingIO.run {
            let fs = try ContainedFileSystem(root: root)
            try fs.writeAtomically(expected.icns, to: SafeRelativePath("AppIcon.icns"))
            try fs.writeAtomically(Data("compiled assets".utf8), to: SafeRelativePath("Assets.car"))
        }
        let fallback = try await BundleGameModeIcons(resources: root).icon(for: GameDefinition.all[0])
        #expect(fallback.icns == expected.icns)
        #expect(fallback.assets == Data("compiled assets".utf8))
    }
}
