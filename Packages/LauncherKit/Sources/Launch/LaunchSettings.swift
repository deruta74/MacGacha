// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import RuntimeManager

public struct LaunchSettings: Codable, Equatable, Sendable {
    public var backend: RuntimeBackend
    public var retina: Bool
    public var frameLimit: Int?
    public var directX12: Bool
    public var compatibilityPatches: Bool
    public var display: DisplayChoice?

    public init(backend: RuntimeBackend, retina: Bool, frameLimit: Int?, directX12: Bool, compatibilityPatches: Bool, display: DisplayChoice? = nil) {
        self.backend = backend; self.retina = retina; self.frameLimit = frameLimit
        self.directX12 = directX12; self.compatibilityPatches = compatibilityPatches; self.display = display
    }

    public static func defaults(for game: String) -> Self {
        Self(backend: .d3dmetal, retina: false, frameLimit: GameDefinition.find(game)?.family == .zzz ? nil : 60,
            directX12: GameDefinition.find(game)?.family == .zzz, compatibilityPatches: true)
    }

    private enum CodingKeys: CodingKey { case backend, retina, frameLimit, directX12, compatibilityPatches, display }
    // The store supplies the game so absent fields get that game's defaults.
    // A standalone decoder uses the shared defaults (60 FPS, DirectX 12 off).
    static let gameKey = CodingUserInfoKey(rawValue: "MacGacha.launchSettings.game")!
    public init(from decoder: any Decoder) throws {
        let defaults = Self.defaults(for: decoder.userInfo[Self.gameKey] as? String ?? "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decodeIfPresent(RuntimeBackend.self, forKey: .backend) ?? defaults.backend
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? defaults.retina
        frameLimit = c.contains(.frameLimit) ? try c.decodeIfPresent(Int.self, forKey: .frameLimit) : defaults.frameLimit
        directX12 = try c.decodeIfPresent(Bool.self, forKey: .directX12) ?? defaults.directX12
        compatibilityPatches = try c.decodeIfPresent(Bool.self, forKey: .compatibilityPatches) ?? defaults.compatibilityPatches
        display = try c.decodeIfPresent(DisplayChoice.self, forKey: .display)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend); try c.encode(retina, forKey: .retina)
        // Explicit null means Off; an absent key means use the game's default.
        try c.encode(frameLimit, forKey: .frameLimit)
        try c.encode(directX12, forKey: .directX12); try c.encode(compatibilityPatches, forKey: .compatibilityPatches)
        try c.encodeIfPresent(display, forKey: .display)
    }

    public func validate() throws {
        try display?.validate()
        if let frameLimit, ![30, 60, 120].contains(frameLimit) {
            throw LauncherError.io("Frame limit must be Off, 30, 60 or 120")
        }
    }
}
