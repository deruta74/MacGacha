// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import CoreGraphics
import ImageIO
import LauncherCore

public protocol GameModeIconProviding: Sendable {
    func icon(for game: GameDefinition) async throws -> GameModeIcon
}

public struct GameModeIcon: Sendable, Equatable {
    public let icns: Data
    public let assets: Data?
    public init(icns: Data, assets: Data? = nil) throws {
        guard icns.count <= 16 << 20, icns.starts(with: Data("icns".utf8)),
            let image = CGImageSourceCreateWithData(icns as CFData, nil), CGImageSourceGetCount(image) > 0,
            (assets?.count ?? 0) <= 64 << 20 else { throw LauncherError.io("Invalid Game Mode icon") }
        self.icns = icns; self.assets = assets
    }
    public var digest: Digest {
        var hash = StreamingHasher(.sha256)
        hash.update(Data(String(icns.count).utf8)); hash.update(icns)
        if let assets { hash.update(Data(String(assets.count).utf8)); hash.update(assets) }
        return hash.finalize()
    }

    /// Called on BlockingIO. Read dimensions before decoding and cap the decoded
    /// image, then write PNG representations into the native ICNS container.
    public static func fromImage(_ data: Data) throws -> Self {
        guard data.count <= 16 << 20, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 4096, height <= 4096,
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw LauncherError.io("Invalid Game Mode icon image")
        }
        func integer(_ value: Int) -> Data {
            let n = UInt32(value)
            return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        }
        var representations = Data()
        for (size, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw LauncherError.io("Cannot render Game Mode icon")
            }
            let scale = min(Double(size) / Double(image.width), Double(size) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))
            guard let rendered = context.makeImage() else { throw LauncherError.io("Cannot render Game Mode icon") }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
                throw LauncherError.io("Cannot encode Game Mode icon")
            }
            CGImageDestinationAddImage(destination, rendered, nil)
            guard CGImageDestinationFinalize(destination) else { throw LauncherError.io("Cannot encode Game Mode icon") }
            representations.append(Data(type.utf8)); representations.append(integer(png.length + 8)); representations.append(png as Data)
        }
        return try Self(icns: Data("icns".utf8) + integer(representations.count + 8) + representations)
    }
}

public struct BundleGameModeIcons: GameModeIconProviding {
    private let resources: URL?
    public init(resources: URL? = Bundle.main.resourceURL) { self.resources = resources }
    public func icon(for game: GameDefinition) async throws -> GameModeIcon {
        try await BlockingIO.run {
            guard let resources else { throw LauncherError.io("Game Mode fallback icon unavailable") }
            let fs = try ContainedFileSystem(root: resources)
            let icon = try fs.readFile(at: SafeRelativePath("AppIcon.icns"), maxBytes: 16 << 20)
            let path = try SafeRelativePath("Assets.car")
            let assets = try fs.itemType(at: path) == nil ? nil : fs.readFile(at: path, maxBytes: 64 << 20)
            return try GameModeIcon(icns: icon, assets: assets)
        }
    }
}
