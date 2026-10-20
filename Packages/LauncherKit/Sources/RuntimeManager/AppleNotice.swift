import Foundation
import LauncherCore

public enum AppleNotice {
    public static let title = "Apple Game Porting Toolkit License"
    public static let body = "D3DMetal and the Game Porting Toolkit are © Apple Inc. and are licensed under Apple's terms. MacGacha is not affiliated with, endorsed by, or supported by Apple. By continuing, you confirm that you have read and accept Apple's Game Porting Toolkit license terms and that you will use this component in accordance with them. You can decline and use DXMT instead, or import Game Porting Toolkit that you downloaded from Apple yourself."
    public static let termsURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    public static var bodyDigest: Digest {
        var hasher = StreamingHasher(.sha256)
        hasher.update(Data(body.utf8))
        return hasher.finalize()
    }
}
