// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
@_exported import HoYoPlayAPI


extension AppModel {
    /// Sample consent copy for previews only; the real text comes from the manifest's notice.
    static func previewConsent(mode: ConsentMode) -> ConsentRequest {
        ConsentRequest(
            id: "d3dmetal-3.0",
            mode: mode,
            title: "D3DMetal is licensed by Apple",
            body: "D3DMetal is part of Apple's Game Porting Toolkit and is licensed under Apple's terms, not MacGacha's. By continuing you agree to those terms.",
            termsURL: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
        )
    }
}
