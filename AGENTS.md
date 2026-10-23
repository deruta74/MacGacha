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
| `docs/`, `spike/` | **Local only, gitignored.** Design notes and experiments. Read them if present; never commit or link them. |

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
| `Launch` | Per-game launch recipes, `LaunchSettings` and its store, `LaunchResolver` (exact Wine command and environment). Next: the launch session journal and the hiding and restoring of game files. |
| `Diagnostics` | Diagnostics bundle for bug reports. |
| `TestSupport`, `CrashHarness`, `ThroughputBenchmark` | Test helpers (`TestEvent`, fault injection), a child process for crash and kill tests, a benchmark. |

App data lives in `~/Library/Application Support/MacGacha/`: `Games/`, `Runtimes/`, `Prefixes/`, `Logs/`, `consent.json`. The bundle ID is `com.lo7ted.macgacha`.

## Build and test

```bash
scripts/bootstrap.sh          # generate MacGacha.xcodeproj from project.yml (needs xcodegen)
scripts/test.sh               # everything CI runs locally: headers, package tests, app tests, string catalog check, Release build
swift test --package-path Packages/LauncherKit --filter <Suite>   # one package suite
```

- **Run `scripts/test.sh` with `MACGACHA_DERIVED_DATA_PATH` pointing outside `~/Documents`**, for example `MACGACHA_DERIVED_DATA_PATH=/tmp/macgacha-dd scripts/test.sh`. Derived data inside `~/Documents` triggers a macOS privacy (TCC) prompt that hangs the test runner. Never click TCC dialogs on the user's behalf.
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

## Safety rules (hard requirements)

These protect users' games, accounts and machines.

- **Game files are the user's data.**
  - Hide them only with non-replacing renames (`RENAME_EXCL`), recorded in the launch journal: "planned" before the rename, "done" after.
  - Never delete or overwrite a game file.
  - When unsure, keep the journal and report pending or conflict.
- **Never modify `/etc/hosts`, never require or run `sudo`**, never change system or security settings. The Star Rail dispatch host is blocked by a per-session local proxy passed through `HTTP(S)_PROXY`.
- **Never bundle or commit game data, game binaries, or Apple's D3DMetal/GPTK files.** D3DMetal is downloaded only after the user accepts Apple's terms, or imported from their own GPTK.
- **Anti-cheat workarounds** (jadeite, the Steam shim, the blocked host) are opt-out compatibility patches. Never add anything that injects code into the game process (FPS unlockers, mods) without the user turning it on and a ban-risk warning shown first.
- **Process hygiene.**
  - Launched game processes get exactly the environment we build, a fresh process group, no inherited descriptors and default signal handling.
  - Tests must kill and reap every process they start.
  - Never kill a MacGacha or Wine process you didn't start.
- **Downloading new third-party binaries** (a new runtime, a tool) needs the maintainer's approval first: name, source, size, license.

## Git and PR workflow

- One PR per task. Branch from `main`, and use a separate git worktree for parallel work.
- Merge with `gh pr merge <N> --squash`, only after CI is green on the PR's head commit. Never use `--auto` (the repo has no branch protection, so `--auto` merges immediately).
- Never commit `docs/`, `spike/`, build output, `.xcodeproj` or secrets.
- PR descriptions: plain English, short bullets on what changed and why, then test results.
- Code and docs here may be written with AI assistance; the README says so. That doesn't change the rules above.

## Current state

- **Done:**
  - download engine;
  - game install, update, verify and repair, voice packs, uninstall;
  - runtime manager with Wine, DXMT and D3DMetal bundles plus jadeite and Steam shim components;
  - HoYoPlay art;
  - diagnostics;
  - localization groundwork (English only so far).
- **In progress:** milestone M2b, one-click Play.
  - Done so far: process spawner and inspector, recipes and resolver.
  - Being built: the session journal with file hiding.
  - Next: session proxy, prefix preparation, session lock, launch manager state machine, then app integration.
- **Planned:** HoYoPlay-style rotating banners and news, translations and content language, download ETA, surround and Spatial Audio, signed and notarized releases with Sparkle updates.

Update this section when a milestone task lands.
