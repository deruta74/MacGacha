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

func rgba(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
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
    @Test(arguments: [256, 1024]) func iconFollowsTheMacOSIconGrid(size: Int) throws {
        let source = try #require(CGImageSourceCreateWithData(gameModeTestPNG() as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rendered = try #require(GameModeIcon.renderIcon(image, size: size))
        #expect(rendered.width == size && rendered.height == size)
        let pixels = try rgba(rendered)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * size + x) * 4 ..< (y * size + x) * 4 + 4]) }
        let last = size - 1, middle = size / 2, margin = size / 100
        for corner in [pixel(0, 0), pixel(last, 0), pixel(0, last), pixel(last, last), pixel(margin, middle), pixel(middle, margin)] {
            #expect(corner[3] == 0)
        }
        // Same color the source yields in the device RGB context (the PNG is color-managed).
        let sourcePixels = try rgba(image)
        let expected = Array(sourcePixels[(image.height / 2 * image.width + image.width / 2) * 4 ..< (image.height / 2 * image.width + image.width / 2) * 4 + 4])
        #expect(pixel(middle, middle) == expected)
        // Just inside the body edge (side midpoints), where the corner radius does not apply.
        let edge = size * 100 / 1024 + 2
        for inside in [pixel(edge, middle), pixel(last - edge, middle), pixel(middle, edge), pixel(middle, last - edge)] {
            #expect(inside[3] == 255)
        }
        // The body corner is rounded away.
        #expect(pixel(edge, edge)[3] == 0)
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
