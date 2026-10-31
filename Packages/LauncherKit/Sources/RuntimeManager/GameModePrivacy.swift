// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

/// Generated helpers have their own bundle localization. These translations
/// belong in InfoPlist.strings, independently of the launcher's current language.
enum GameModePrivacy {
    static let key = "NSLocalNetworkUsageDescription"
    static let english = "The game connects to a helper on this Mac that MacGacha starts for the session."
    static let descriptions = [
        "en": english,
        "zh-Hans": "游戏会连接到本机上由 MacGacha 为本次会话启动的辅助程序。",
        "zh-Hant": "遊戲會連線到此 Mac 上由 MacGacha 為本次工作階段啟動的輔助程式。",
        "ja": "ゲームは、MacGacha がセッション用にこの Mac で起動するヘルパーに接続します。",
        "ko": "게임은 MacGacha가 이번 세션을 위해 이 Mac에서 실행한 도우미에 연결합니다.",
        "ru": "Игра подключается к вспомогательному процессу на этом Mac, который MacGacha запускает на время сеанса.",
        "uk": "Гра підключається до допоміжного процесу на цьому Mac, який MacGacha запускає на час сеансу.",
        "de": "Das Spiel verbindet sich mit einem Hilfsprogramm auf diesem Mac, das MacGacha für die Sitzung startet.",
        "fr": "Le jeu se connecte à un programme auxiliaire sur ce Mac, lancé par MacGacha pour la session.",
        "es": "El juego se conecta a un programa auxiliar en este Mac que MacGacha inicia para la sesión.",
        "pt": "O jogo se conecta a um programa auxiliar neste Mac que o MacGacha inicia para a sessão.",
        "id": "Game terhubung ke program pembantu di Mac ini yang dijalankan MacGacha untuk sesi ini.",
        "th": "เกมจะเชื่อมต่อกับโปรแกรมช่วยบน Mac เครื่องนี้ที่ MacGacha เริ่มทำงานสำหรับเซสชันนี้",
        "vi": "Trò chơi kết nối với một tiến trình hỗ trợ trên máy Mac này do MacGacha khởi chạy cho phiên chơi.",
    ]
}
