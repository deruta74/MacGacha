<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# MacGacha: guide for AI agents

Read this before you change anything. **Keep it current:** when you add a module, a script, a user-visible feature or a new rule, update the matching section in the same PR.

## What this is

MacGacha is a native macOS launcher for Genshin Impact, Honkai: Star Rail and Zenless Zone Zero (Global servers) on Apple Silicon.

- **What it does:**
  - installs, updates, verifies and repairs games through HoYoverse's official Sophon delivery;
  - manages Wine, DXMT and D3DMetal runtimes side by side;
  - launches each game with a verified per-game recipe.
- **Requirements:** macOS 27, Apple Silicon. SwiftUI, Swift 6 language mode, strict concurrency.
- **License:** GPL-3.0-only, with an extra term under section 7(b): keep the link to the original project. See `NOTICE`.

The README's Roadmap section is the user-facing status. Update it when a feature lands.

## Repository layout

| Path | What lives there |
|---|---|
| `App/` | The SwiftUI app. `Model/`: `AppModel` and service adapters. `Views/`. `Resources/`: `Localizable.xcstrings`, `runtime-manifest.json`, credits. |
| `MacGachaTests/` | App unit tests (Swift Testing), run through `xcodebuild test`. |
| `Packages/LauncherKit/` | SwiftPM package with all logic. The app is a thin layer over it. |
| `compat/steam-shim/` | Reproducible build inputs, notices and `SHA256SUMS` for the Proton `steam.exe` shim. |
| `scripts/` | Build, test and check scripts (see below). |
| `project.yml` | XcodeGen spec. `MacGacha.xcodeproj` is generated and ignored. Never edit it by hand. |
| `assets/` | README screenshots. |
| `docs/`, `spike/` | Gitignored local scratch folders. They aren't part of the project. |

### LauncherKit targets

| Target | Responsibility |
|---|---|
| `LauncherCore` | Shared foundations: `AppPaths`, `ContainedFileSystem` (all file access confined to a root, no symlink escape), `SafeRelativePath`, `Digest`, `BlockingIO`, `EventLog`, `ProcessRunner`, `ProcessSpawner` / `ProcessInspector` (long-running game processes, identity = PID + kernel start time). |
| `CZstd` | Vendored zstd decoder (decompression only). Don't edit upstream files. |
| `DownloadEngine` | Resumable, verified downloads: plans, crash-safe journal, staging, disk-space budget, parallel fetch pipeline, `URLSessionHTTPClient` with bounded buffering. |
| `Sophon` | HoYoverse delivery API client, host policy, protobuf manifest reader, install/update/voice planner. |
| `GameLibrary` | Game records, operation lease (one game operation at a time), install/update/verify/adopt/uninstall bridge to the engine. |
| `RuntimeManager` | Runtime manifest (schema 3), components (Wine, DXMT, D3DMetal, jadeite, Steam shim), bundles, safe archive extraction, Wine prefixes, GPTK import, Apple consent. |
| `HoYoPlayAPI` | HoYoPlay game list and art (banners, backgrounds), with the content language as a parameter. |
| `Launch` | Per-game launch recipes, `LaunchSettings` and its store, `LaunchResolver` (exact Wine command and environment), `LaunchSession` and `LaunchJournal`, `HiddenFiles` (inode-bound hiding and restoring of game files, with recovery for conflicts), and `SessionProxy` (loopback HTTP/CONNECT proxy that blocks a recipe's hosts by exact name, with bounded buffers and deadlines). |
| `Diagnostics` | Diagnostics bundle for bug reports. |
| `TestSupport`, `CrashHarness`, `ThroughputBenchmark` | Test helpers (`TestEvent`, fault injection), a child process for crash and kill tests, a benchmark. |

App data lives in `~/Library/Application Support/MacGacha/`: `Games/`, `Runtimes/`, `Prefixes/`, `Logs/`, `consent.json`. The bundle ID is `com.lo7ted.macgacha`.

## Build and test

```bash
scripts/bootstrap.sh          # generate MacGacha.xcodeproj from project.yml (needs xcodegen)
scripts/test.sh               # everything CI runs locally: headers, package tests, app tests, string catalog check, Release build
swift test --package-path Packages/LauncherKit --filter <Suite>   # one package suite
```

- **Run `scripts/test.sh` with `MACGACHA_DERIVED_DATA_PATH` pointing outside `~/Documents`**, for example `MACGACHA_DERIVED_DATA_PATH=/tmp/macgacha-dd scripts/test.sh`. Derived data inside `~/Documents` triggers a macOS privacy (TCC) prompt that hangs the test runner.
- CI (`.github/workflows/ci.yml`) also runs the `DownloadEngineTests` with one cooperative thread (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`). Run that step locally when you touch concurrency:
  ```bash
  LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 python3 scripts/test-package.py --events /tmp/strict.jsonl --timeout-seconds 240 --skip-build --test-product DownloadEngineTests --skip PlanScaleTests --skip operationStagesOneThousandBatchesWithLinearWork --parallel --num-workers 2
  ```
  Never block a cooperative thread: no semaphores, sleeps or synchronous waits in async code. Use `BlockingIO.run` for blocking syscalls.
- The build must have **zero Swift warnings**.
- `scripts/check-headers.sh`: every Swift file starts with the two-line SPDX and project header (copy it from any existing file). Python and shell scripts carry it as comments.
- `scripts/check-strings.py <derived-data>`: the string catalog must match the code. Run with `--write` to update `Localizable.xcstrings` after adding strings.
- The Steam shim has its own manual workflow (`steam-shim.yml`) and scripts (`build-steam-shim.sh`, `install-steam-shim-toolchain.py`). Its output must match `compat/steam-shim/SHA256SUMS` byte for byte.

## Code conventions

- Match the surrounding code: naming, comment density, file size. Comments explain *why*, not what.
- Tests use Swift Testing (`@Test`, `#expect`). New behavior comes with a test; bugs get a regression test first. Tests must be deterministic: no wall-clock pacing or sleeps that decide correctness. Use handshakes (`TestEvent`) and injected clocks and seams.
- **All file access goes through `ContainedFileSystem`.** Never build paths by string concatenation from untrusted input; use `SafeRelativePath`.
- Network access is limited to allowlisted HTTPS hosts (see `Sophon/DeliveryHostPolicy.swift` and the runtime manifest). Downloads are verified by size and SHA-256 before use.
- **User-visible text is localizable.** SwiftUI literals are automatic. Text built in code uses `String(localized:)` or `LocalizedStringResource` with format arguments, never concatenation. Sizes, dates and percentages go through formatters. Log and diagnostic text stays plain English.
- Errors shown to users go through `LauncherError` and `LauncherError+UserMessage.swift`, never raw payloads, URLs with tokens or paths with personal data.

## Product rules (hard requirements)

Code must keep these guarantees. A PR that weakens one won't be merged.

- **Game files are the user's data.**
  - Hide them only with non-replacing renames (`RENAME_EXCL`), recorded in the launch journal: "planned" before the rename, "done" after.
  - Never delete or overwrite a game file.
  - When unsure, keep the journal and report pending or conflict.
- **No `/etc/hosts` edits, no `sudo`, no system or security setting changes.** The Star Rail dispatch host is blocked by a per-session local proxy passed through `HTTP(S)_PROXY`.
- **No game data, game binaries or Apple D3DMetal/GPTK files in the repository or the app bundle.** D3DMetal is downloaded only after the user accepts Apple's terms, or imported from their own GPTK.
- **Anti-cheat workarounds** (jadeite, the Steam shim, the blocked host) are compatibility patches the user can turn off. Anything that injects code into the game process (FPS unlockers, mods) must be off by default and show a ban-risk warning before it's enabled.
- **Launched processes** get exactly the environment we build, a fresh process group, no inherited descriptors and default signal handling. Tests kill and reap every process they start.
- **New third-party components** in `runtime-manifest.json` need a pinned HTTPS URL, size, SHA-256 and license, with redistribution checked. Call them out in the PR description.

## Pull requests

1. Branch from `main`. Keep one change per PR: a feature, a fix or a refactor, not a mix.
2. Run `scripts/test.sh` (see Build and test) and make sure it passes with no warnings.
3. Don't commit build output, `MacGacha.xcodeproj`, `docs/`, `spike/`, secrets or downloaded binaries.
4. Write commit messages and PR descriptions in plain English: a short title, then bullets on what changed and why, then how it was tested.
5. If the change adds a module, script, feature or rule, update this file in the same PR, and the README roadmap when a user-visible feature lands.
6. CI (`.github/workflows/ci.yml`) must pass on the PR's latest commit. PRs are squash-merged.

## Current state

- **Done:**
  - download engine;
  - game install, update, verify and repair, voice packs, uninstall;
  - runtime manager with Wine, DXMT and D3DMetal bundles plus jadeite and Steam shim components;
  - HoYoPlay art;
  - diagnostics;
  - localization groundwork (English only so far).
- **In progress:** one-click Play.
  - Done so far: process spawner and inspector, recipes and resolver, session journal and file hiding, session proxy.
  - Next: prefix preparation, session lock, launch manager state machine, then app integration.
- **Planned:** HoYoPlay-style rotating banners and news, translations and content language, download ETA, surround and Spatial Audio, signed and notarized releases with Sparkle updates.

Update this section when a milestone task lands.
