// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreGraphics
import ImageIO
import Testing
import LauncherCore
import RuntimeManager
@testable import MacGacha

private actor IconFallback: GameModeIconProviding {
    let value: GameModeIcon
    private(set) var calls = 0
    init(_ value: GameModeIcon) { self.value = value }
    func icon(for game: GameDefinition) async throws -> GameModeIcon { calls += 1; return value }
}

@Suite @MainActor struct GameModeIconProviderTests {
    @Test(arguments: ["cache", "missing", "invalid"]) func cachedArtOrLauncherFallback(mode: String) async throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.25, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let png = NSMutableData(), image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); try #require(CGImageDestinationFinalize(output))
        let data = png as Data
        let expected = try GameModeIcon.fromImage(data), fallback = IconFallback(expected)
        let provider = CachedGameModeIcons(cachedImage: { _ in
            mode == "cache" ? data : mode == "invalid" ? Data("invalid cache".utf8) : nil
        }, fallback: fallback)
        let icon = try await provider.icon(for: GameDefinition.all[0])
        #expect(icon == expected)
        #expect(await fallback.calls == (mode == "cache" ? 0 : 1))
    }
}
