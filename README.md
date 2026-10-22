# MacGacha

> 🚧 **Work in progress.** Games can already be installed, updated and verified, but they can't be launched yet. There are no releases yet.

A native macOS launcher for **Genshin Impact**, **Honkai: Star Rail** and **Zenless Zone Zero** on Apple Silicon. It aims to provide reliable resumable downloads, file verification, and managed Wine / DXMT / D3DMetal runtimes.

- Requirements (planned): Apple Silicon Mac, macOS 27 or later.

## Screenshots

![Launcher with the current Genshin Impact banner](assets/screenshots/launcher.jpg)

| Install | Downloading |
|---|---|
| ![Install sheet with location, voice packs and a disk-space estimate](assets/screenshots/install.jpg) | ![Download in progress, with pause](assets/screenshots/progress.jpg) |

![Runtimes panel with Wine, DXMT and D3DMetal](assets/screenshots/runtimes.jpg)

## Roadmap

**Done**
- **Download engine.** Resumable, verified downloads with a crash-safe journal. A file reaches the game folder only after its hash matches.
- **Runtimes.** Wine, DXMT and D3DMetal are downloaded and kept side by side, so an update never breaks a working version. D3DMetal is installed only after you accept Apple's terms, or imported from an existing Game Porting Toolkit.
- **Launcher.** One window for all three games with the official banners and background art, plus a diagnostics bundle for bug reports.
- **Installing games** through HoYoverse's official delivery: install, update, verify and repair, voice packs, using an existing installation, and uninstall. Pause and resume work across app restarts, and free space is checked before and during the download.

**In progress**
- **Faster downloads.** The engine downloads and assembles many files in parallel. In early tests it is about twice as fast as before and comes close to the full speed of a 2.5 Gbit link.
- **Compatibility testing.** Each game is run by hand under D3DMetal and DXMT, to choose the first game that launches and the graphics backend for each one.

**Next**
- **Launching games:** a graphics backend and runtime version per game, voice-pack settings the game reads, and opt-in compatibility patches that can be reverted.
- **Updates:** pre-downloading the next version before release, and smaller patch-based updates.
- **Releases:** signed and notarized builds with automatic updates.

## Disclaimer

MacGacha is an unofficial, community project. It is not affiliated with, endorsed by, or supported by HoYoverse (COGNOSPHERE) or Apple Inc. All game names and trademarks belong to their respective owners.

- Using third-party launchers may conflict with HoYoverse's Terms of Service. Optional compatibility patches carry a risk of account bans. Use at your own risk.
- D3DMetal and the Game Porting Toolkit are © Apple Inc. and licensed under Apple's terms. The launcher will ask you to accept those terms before it downloads the component.

## License

Copyright (C) 2026 deruta74. MacGacha is free software under the [GNU General Public License v3.0](LICENSE), with one additional term under GPL section 7(b) (see [NOTICE](NOTICE)): the link to the original project, https://github.com/deruta74/MacGacha, must be kept by every conveyed (distributed) copy and every distributed work based on MacGacha, both in its source and in its About screen. Private modifications that aren't distributed aren't affected. Any distributed version, modified or paid, must stay under GPL-3.0 with its source available.

Components the launcher downloads at runtime (Wine, DXMT, D3DMetal) and the games themselves are under their own licenses and terms.
