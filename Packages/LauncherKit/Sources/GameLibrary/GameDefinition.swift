// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

public struct VoiceOption: Sendable, Hashable {
    public let code: String
    public let name: String
    public init(code: String, name: String) { self.code = code; self.name = name }
}

public struct GameDefinition: Sendable, Hashable, Identifiable {
    public let id: String
    public let biz: String
    public let voices: [VoiceOption]
    public init(id: String, biz: String, voices: [VoiceOption]) { self.id = id; self.biz = biz; self.voices = voices }

    public static let all: [GameDefinition] = {
        let voices = [VoiceOption(code: "zh-cn", name: "Chinese"), VoiceOption(code: "en-us", name: "English"),
            VoiceOption(code: "ja-jp", name: "Japanese"), VoiceOption(code: "ko-kr", name: "Korean")]
        return [GameDefinition(id: "genshin", biz: "hk4e_global", voices: voices),
            GameDefinition(id: "starrail", biz: "hkrpg_global", voices: voices),
            GameDefinition(id: "zzz", biz: "nap_global", voices: voices)]
    }()
}
