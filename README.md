# MacGacha — universal launcher for HoYoverse games on Apple Silicon

> 🚧 **Work in progress.** Games can be installed, updated, verified and started with one click in all three games. The first beta release is being prepared.

A native macOS launcher for **Genshin Impact**, **Honkai: Star Rail** and **Zenless Zone Zero** on Apple Silicon. It aims to provide reliable resumable downloads, file verification, and managed Wine / DXMT / D3DMetal runtimes.

- Requirements: Apple Silicon Mac with Rosetta 2 (MacGacha offers to install it), macOS 27 or later.

Code and documentation in this repository may be written or modified with assistance from large language models (LLMs) and AI agents. The software is provided under the [GPL-3.0 license](LICENSE), as is, without warranty.

## Screenshots

![Launcher with the current Honkai: Star Rail banner, ready to play](assets/screenshots/launcher.jpg)

| Install | Downloading |
|---|---|
| ![Install sheet with location, voice packs and a disk-space estimate](assets/screenshots/install.jpg) | ![Download in progress, with pause](assets/screenshots/progress.jpg) |

| One-click setup | Runtimes |
|---|---|
| ![Set Up sheet listing the runtime a game needs, with its size](assets/screenshots/setup.jpg) | ![Runtimes panel with Wine, DXMT, D3DMetal and jadeite](assets/screenshots/runtimes.jpg) |

![Mainland China region with the interface in Simplified Chinese](assets/screenshots/region-cn.jpg)

## Roadmap

**Done**
- **Download engine.** Resumable, verified downloads with a crash-safe journal. A file reaches the game folder only after its hash matches. Files are downloaded and assembled in parallel, close to the full speed of a 2.5 Gbit link.
- **Installing games** through HoYoverse's official delivery: install, update, verify and repair, voice packs, using an existing installation, and uninstall. Pause and resume work across app restarts. Free space is checked before and during the download. If macOS is still holding space (Time Machine snapshots, caches), the launcher says so instead of just "not enough space".
- **Runtimes.** Wine, DXMT and D3DMetal are downloaded and kept side by side, so an update never breaks a working version. D3DMetal is installed only after you accept Apple's terms, or imported from an existing Game Porting Toolkit. The default DXMT build now uses CrossOver's Wine, which needs about 2.5× less CPU than the previous one.
- **Compatibility components.** jadeite and a Steam launcher shim are installed and removed from the Runtimes window. We build the shim ourselves, reproducibly, from Valve's Proton source ([release](https://github.com/deruta74/MacGacha/releases/tag/steam-shim-proton-10.0-4)).
- **Launcher.** One window for all three games with the official banners and background art, plus a diagnostics bundle for bug reports.
- **One-click Play.** Press Play, and the launcher prepares the Wine prefix and the compatibility workaround, starts the game and minimizes itself to the Dock. When the game closes, it comes back and puts back any game files it hid. Accepted in all three games on D3DMetal and DXMT.
- **One-click setup.** When a game needs runtimes, "Set Up…" lists exactly what it needs for its settings (the Wine bundle and its compatibility component) and installs it all in one go, asking for Apple's terms only when D3DMetal is part of it. The Runtimes panel stays available for picking versions by hand.
- **Per-game settings:** graphics backend, frame limit, Retina mode, DirectX 12 for Zenless Zone Zero, and a switch for the compatibility workaround.
- **Recovery.** If the launcher crashes or is quit while a game runs, it finds the game again on restart and restores everything once the game exits. Quitting during a game asks first.
- **Privacy.** Games run in their own Wine prefix with no links to your Desktop, Documents or other home folders. Session logs stay on your Mac and can be turned off in Settings.
- **Languages.** English and Simplified Chinese interface; game news and art follow the interface language.

**Verified by hand (macOS 27.0.1)**

All three games start and play with a community anti-cheat workaround. None of them needs `/etc/hosts` changes or administrator rights. Measured on a MacBook Pro 14″ with M5 Pro (48 GB) and on a base M5 (16 GB); Zenless Zone Zero used the same graphics preset on both.

| Game | Default backend | M5 Pro, 48 GB | M5, 16 GB |
|---|---|---|---|
| Honkai: Star Rail 4.6 | D3DMetal, 60 fps cap | 60 fps on Ultra. About half the CPU of DXMT, GPU time about 6.5 ms against 9 ms. | Not measured yet. |
| Zenless Zone Zero | D3DMetal, DirectX 12 | 120 fps on High, battle dips stay above 115. With ray tracing on Low, 70–90 fps. | 70–110 fps on High in battle, depending on how many enemies and effects are on screen. With ray tracing on Low, 50–60 fps. |
| Genshin Impact 7.1 | D3DMetal, 60 fps cap | Steady 60 fps on Ultra at 1800×1169 with render scale 1.2, even frame time. | 60 fps at 1512×982 with render scale 1.2. |

DXMT works for every game and stays available as the open-source alternative. The 60 fps cap fixes uneven frame pacing in Star Rail and Genshin; it can be changed per game.

**In progress**
- **Mainland China editions (beta):** a region switch in Settings shows 原神, 崩坏：星穹铁道 and 绝区零 with their own installs, prefixes and settings. 绝区零 installs from the miHoYo servers and reaches the login screen; CN Genshin/ZZZ on Wine 11.20 use a scoped Wine signature-verification fix, installed through Set Up without changing game files (component release publication pending).
- **First beta release** as a downloadable disk image.

**Next**
- **Display choice:** pick the monitor a game opens on when several are connected; the main display by default.
- **Rotating banners and news** like HoYoPlay: several background arts per game, event cards, and Events / Notices / News tabs.
- **More languages** for the interface.
- **Downloads:** estimated time remaining; pre-downloading the next version before release; smaller patch-based updates.
- **Audio:** surround output from the games, including Spatial Audio on AirPods.
- **Releases:** signed and notarized builds with automatic updates.

## Disclaimer

MacGacha is an unofficial, community project. It is not affiliated with, endorsed by, or supported by HoYoverse (COGNOSPHERE) or Apple Inc. All game names and trademarks belong to their respective owners.

- Using third-party launchers may conflict with HoYoverse's Terms of Service. Use at your own risk.
- Under Wine, the games' anti-cheat stops them from starting. To launch them, MacGacha uses community workarounds: [jadeite](https://codeberg.org/mkrsym1/jadeite) for Star Rail, which also blocks one game server through a local proxy while the game runs, and a Steam launcher shim for Genshin Impact and Zenless Zone Zero. These workarounds may conflict with the Terms of Service and could lead to an account ban. MacGacha doesn't inject cheats, FPS unlockers or other mods into the game. Any future option that changes the game process will be off by default and will warn you about the ban risk first.
- The software is provided as is. The authors aren't responsible for account bans, data loss or any other damage.
- D3DMetal and the Game Porting Toolkit are © Apple Inc. and licensed under Apple's terms. The launcher will ask you to accept those terms before it downloads the component.

## License

Copyright (C) 2026 deruta74. MacGacha is free software under the [GNU General Public License v3.0](LICENSE), with one additional term under GPL section 7(b) (see [NOTICE](NOTICE)): the link to the original project, https://github.com/deruta74/MacGacha, must be kept by every conveyed (distributed) copy and every distributed work based on MacGacha, both in its source and in its About screen. Private modifications that aren't distributed aren't affected. Any distributed version, modified or paid, must stay under GPL-3.0 with its source available.

Components the launcher downloads at runtime (Wine, DXMT, D3DMetal, jadeite, the Steam shim) and the games themselves are under their own licenses and terms.
