// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Per-launch prefix state. LaunchPreparation (Task 8) applies this request.
public struct PreparationRequest: Equatable, Sendable {
    public let retina: Bool
    public let steamShim: URL?
    public let dxmtExtras: [String]
    public let nvidiaKeys: Bool

    public init(retina: Bool, steamShim: URL?, dxmtExtras: [String], nvidiaKeys: Bool) {
        self.retina = retina; self.steamShim = steamShim
        self.dxmtExtras = dxmtExtras; self.nvidiaKeys = nvidiaKeys
    }
}
