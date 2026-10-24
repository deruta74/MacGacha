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
| `App/` | The SwiftUI app. `Model/`: `AppModel`, service adapters and launch integration (persisted region selection with three visible editions, lazy per-region remote status/art, other-region activity summaries, observable launch state, per-game/global settings, startup reattachment, recovery notices, a launch-slot reservation through preparation and recovery, guarded recovery retries (including unresolved startup journals), and verified-end window lifecycle). `Views/`. `Resources/`: `Localizable.xcstrings`, `runtime-manifest.json`, credits, `Assets.xcassets` (app icon). |
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
| `LauncherCore` | Shared foundations: `AppPaths`, `ContainedFileSystem` (all file access confined to a root, no symlink escape), `SafeRelativePath`, `Region` (Global and Mainland China endpoint/domain selection), `GameDefinition` / `GameFamily` (one six-edition registry for IDs, canonical install folders, executable names, voices and Unity log products), `Digest`, `BlockingIO`, `EventLog` (bounded best-effort `post`, drop counters, a serial writer on BlockingIO, and a joining async `log` API), `ProcessRunner` (cancellable command deadlines), `ProcessSpawner` / `ProcessInspector` (long-running game processes, identity = PID + kernel start time; one structural KERN_PROCARGS2 parser that tolerates Wine's rewritten argv padding, and environment queries limited to uppercase names so Darwin's auxiliary strings can't match), `WineServerProbe` (pinned-prefix device/inode server identity, checked private namespace, record-lock and nonblocking socket liveness), global launch preferences, durable launch-journal mutation barriers and plain log-location data. |
| `CZstd` | Vendored zstd decoder (decompression only). Don't edit upstream files. |
| `DownloadEngine` | Resumable, verified downloads: plans, crash-safe journal, staging, disk-space budget, parallel fetch pipeline, `URLSessionHTTPClient` with bounded buffering. |
| `Sophon` | HoYoverse delivery API client and delivery/redirect host policy selected by `Region`, region-pinned build descriptors (legacy snapshots default to Global), protobuf manifest reader, install/update/voice planner. Sanitized CN metadata fixtures and a metadata-only live test gated by `MACGACHA_LIVE_CN=1`. |
| `GameLibrary` | Game records for independent Global/CN editions, read-only contained adopt checks (executable plus region/distribution metadata, rejecting positive edition conflicts and Bilibili while accepting the selected edition when metadata is absent), operation lease (one game operation at a time), install/update/verify/adopt/uninstall bridge to the engine, with an optional `GameOperationGuard` checked before every per-game operation takes a lease or changes state, plus per-game session exclusion retained by the operation lease through pipeline drainage and a durable-journal barrier rechecked under that exclusion before reconciliation or mutation. |
| `RuntimeManager` | Runtime manifest (schema 3), components (Wine, DXMT, D3DMetal, jadeite, Steam shim), bundles, safe archive extraction, Wine prefixes with idle-process checks and isolated shell folders and revisioned launch preparation (WinINet, Retina and NVIDIA registry settings, a wineserver/registry persistence barrier and verified prefix-only copies; no third-party certificates), GPTK import, Apple consent, and exclusive component-pin exclusion held across runtime install/import publication, replacement cleanup and removal; unresolved launch journals block runtime mutation and staging cleanup. |
| `HoYoPlayAPI` | HoYoPlay game list and art (banners, backgrounds), with region-selected endpoints and art hosts and biz mapping from the shared game registry, separate cache indexes/assets per region, and Global content language as a parameter (CN always uses zh-cn). Global keeps its existing cache path; CN uses a contained subdirectory. |
| `Launch` | Registry-derived Global/CN launch recipes (CN builds remain unverified), `LaunchSettings` and its store, `LaunchResolver` (exact Wine command and environment), `LaunchSession` and `LaunchJournal`, `LaunchManager` (snapshot-based state machine, detached observer lifetime, exclusive watch/recovery ownership, watch/reattach and restore, explicit unresolved startup ownership and full startup grace for unrecorded prefix helpers), persisted `RecoveryNotice` acknowledgments, bounded best-effort session lifecycle lines plus always-on path-free `launch` operational events, with a durable `endLogged` checkpoint shared by watch and recovery, `SessionWatcher` (injected-clock startup grace and wineserver end confirmation), `LaunchManagerOperationGuard`, cross-process `SessionLock` ownership and shared `RuntimePin` component locks, `HiddenFiles` (inode-bound hiding and restoring of game files, with durable internal restore intents and user-facing reports only for preserved copies or pending recovery, and journaled owner-only recovery areas outside external-volume installations on their own volume), `SessionLog` (optional private Wine output, retained inode ownership, a five-second cap ticker and per-game retention), `LaunchCopies` (verified per-launch prefix copies), and `SessionProxy` (loopback HTTP/CONNECT proxy that blocks a recipe's hosts by exact name, with bounded buffers and deadlines). |
| `Diagnostics` | Diagnostics bundles with redacted event logs and caller-supplied session/game-log inputs; no dependency on Launch. Event and session logs are enumerated and opened through a Logs descriptor pinned from the app-data root; unsafe Logs roots are reported and skipped. Optional log discovery is best-effort and passes fixed-scope skip notices to the bundle. Optional logs are read completely within a 64 MiB safety limit and redacted before any tail/head selection; oversized, missing or unsafe inputs are reported and skipped. |
| `TestSupport`, `CrashHarness`, `ThroughputBenchmark` | Test helpers (`TestEvent`, fault injection), a child process for crash, kill and Wine record-lock tests, a benchmark. |

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
- The gated live Wine inspector probe runs only with `MACGACHA_LIVE_WINE=/absolute/path/to/wine`; it explicitly initializes an isolated temporary prefix with `wineboot --init`, polls the inspector for rewritten `cmd.exe` on a bounded clock deadline, then shuts down that prefix and reaps its direct child.
- `LaunchIntegrationTests` is gated on `MACGACHA_RUNTIME_FIXTURES`. It installs the pinned Wine 11.20/D3DMetal and Wine 11.0/DXMT bundles from local archives, then launches a D3D11 probe through the real manager, prefix preparation, proxy and logs. It SIGKILLs `CrashHarness` at hide/restore journal and rename boundaries, reattaches while Wine is live, and verifies conflict recovery through the next launch. All state lives in temporary roots. Every manager runs in a deadline-controlled `CrashHarness` child; cancellation cancels and joins that bounded child runner. Teardown runs in an uncancelled task with deadlines for `wineserver -k`/`-w`, checks both exit codes (Wine 11's empty-output `-k` status 1 additionally requires an idle pinned-prefix server namespace), and requires an empty successful prefix-scoped inspector scan before removing the pinned temporary root. Shutdown failures or inspection uncertainty retain the root and fail the test. `withProbeTestRoot` owns setup as well as execution: a failed/cancelled partial extraction is removed in an uncancelled task, while an unexpected prefix retains the root. `ProbeTeardownTests` covers partial setup, cancellation and deadline failures without Wine; the gated matrix also forces persistent live inspection failure and proves bounded exit and subsequent recovery. Package-only recipe overrides and file hooks select the test recipe and exact crash boundaries; shipped recipes remain the default.
  - The local fixtures also need `d3d11waitprobe.c` / `d3d11waitprobe.exe`: the C wrapper calls the original `d3d11probe.c`, flushes stdout, creates `probe-ready` in its working directory, and waits for `probe-release` with a bounded deadline. Build locally with `x86_64-w64-mingw32-gcc -O2 -o d3d11waitprobe.exe d3d11waitprobe.c -ld3d11 -ldxgi -ldxguid`. Never commit fixture binaries. Tests wait for file events and manager running confirmation before releasing the probe; readiness deadlines name the bundle, harness mode/checkpoint and signal, and include the durable child phase, signal states and last inspection error; elapsed time is only a failure bound. `TestSupport/LaunchIntegrationSupport.swift` shares the temporary configuration with the crash child. `ProbeTestLifetime.swift` owns the bounded child lifecycle and checked teardown; the harness's `cleanup` mode retries teardown for a retained root.
- Debug screenshots can combine `-MacGachaDebugRegion cn` with `-MacGachaDebugGameState playing` (or `launching`, `launchFailed`, `recoveryNeeded`, `progress`, `busy`, `ready`); fake states and recovery notices belong to the visible region.
- The build must have **zero Swift warnings**.
- `scripts/check-headers.sh`: every Swift file starts with the two-line SPDX and project header (copy it from any existing file). Python and shell scripts carry it as comments.
- `scripts/check-strings.py <derived-data>`: the string catalog must match the code, and every string (app and package catalogs) needs a Simplified Chinese (`zh-Hans`) translation with the same number of format arguments. Run with `--write` to add new strings to `Localizable.xcstrings`, then translate them.
- The Steam shim has its own manual workflow (`steam-shim.yml`) and scripts (`build-steam-shim.sh`, `install-steam-shim-toolchain.py`). Its output must match `compat/steam-shim/SHA256SUMS` byte for byte.

## Code conventions

- Match the surrounding code: naming, comment density, file size. Comments explain *why*, not what.
- Tests use Swift Testing (`@Test`, `#expect`). New behavior comes with a test; bugs get a regression test first. Tests must be deterministic: no wall-clock pacing or sleeps that decide correctness. Use handshakes (`TestEvent`) and injected clocks and seams.
- **All file access goes through `ContainedFileSystem`.** Never build paths by string concatenation from untrusted input; use `SafeRelativePath`.
- Network access is limited to allowlisted HTTPS hosts (see `Sophon/DeliveryHostPolicy.swift` and the runtime manifest). Downloads are verified by size and SHA-256 before use.
- **User-visible text is localizable.** SwiftUI literals are automatic. Text built in code uses `String(localized:)` or `LocalizedStringResource` with format arguments, never concatenation. Sizes, dates and percentages go through formatters. Log and diagnostic text stays plain English. New strings ship with their `zh-Hans` translation; use the games' official Chinese terms (原神, 崩坏：星穹铁道, 绝区零, 开始游戏, 校验, 语音包).
- Errors shown to users go through `LauncherError` and `LauncherError+UserMessage.swift`, never raw payloads, URLs with tokens or paths with personal data.

## Product rules (hard requirements)

Code must keep these guarantees. A PR that weakens one won't be merged.

- **Game files are the user's data.**
  - Hide them only with non-replacing renames (`RENAME_EXCL`), recorded in the launch journal: "planned" before the rename, "done" after.
  - Never delete or overwrite a game file.
  - When unsure, keep the journal and report pending or conflict.
- **Prefixes must not link to the user’s home folders.** After wineboot and on every launch preparation, replace every shell-folder symlink (including internal links and Public profiles) with prefix-owned directories without inspecting its target; preserve real directories and their contents. Unsafe profile ancestors fail before Wine runs. Repair holds prefix/session exclusion and requires an empty process scan and an idle wineserver namespace keyed by the pinned prefix’s device/inode, so aliases and trailing slashes cannot bypass it; concurrent same-user writers outside Wine are outside the threat model for our owned prefix. Revision 2 migrates existing prefixes and persists in-prefix shell-folder registry paths.
- **No `/etc/hosts` edits, no `sudo`, no system or security setting changes.** The Star Rail dispatch host is blocked by a per-session local proxy passed through `HTTP(S)_PROXY`.
- **No game data, game binaries or Apple D3DMetal/GPTK files in the repository or the app bundle.** D3DMetal is downloaded only after the user accepts Apple's terms, or imported from their own GPTK.
- **Anti-cheat workarounds** (jadeite, the Steam shim, the blocked host) are compatibility patches the user can turn off. Anything that injects code into the game process (FPS unlockers, mods) must be off by default and show a ban-risk warning before it's enabled.
- **Launched processes** get exactly the environment we build, a fresh process group, no inherited descriptors and default signal handling. Tests kill and reap every process they start.
- **Session supervision** belongs to `LaunchManager`, independently of event-stream consumers. Consumer cancellation detaches observation and leaves the game, proxy, locks and recovery supervised until verified end. Process-inspection uncertainty for plausible session processes (executable under the app Runtimes or snapshot install root, a recorded PID/start-time identity, or a live recorded spawned process group) keeps the proxy, journal and ownership in `recoveryPending`, with automatic retries on the injected clock. An unreadable process is foreign only with a readable executable path outside both roots and no live identity/group match; an unclassifiable path remains uncertain. Persisted group claims require the same boot plus the exact recorded leader PID/start-time identity or a verified surviving recorded member still in that group; a newer leader, launch-time lower bound or anonymous leaderless group confers no ownership. Only verified termination permits restore. A fully resolved conflict persists its recovery notice before deleting the resolved journal, preserves its recovery copy, and releases ownership. Completed restore snapshots retain a finalization checkpoint across unlink or directory-sync failure; retries sync even an absent journal before releasing ownership. Pending recovery notices survive restart until explicitly acknowledged; acknowledgment acquires session exclusion and waits for a durable resolved-journal removal barrier. Guards reserve recovery ownership across awaits and never restore while a watcher owns the session. Reattach uses persisted executable/log context and never recreates the session proxy or reads changed launch settings. Session-owned journal writes use their own atomic-temporary namespace so another game can download concurrently.
- **Game editions:** every Global and Mainland China edition has an independent game ID, record, prefix, settings, lock, journal and logs. Canonical install folder names do not follow the interface language: Global keeps its English folder names; CN uses `原神`, `崩坏星穹铁道`, `绝区零`. Adopt validates the executable and any `config.ini` / `game_version` edition and channel evidence before network access or record/plan mutation; only positive conflicting edition evidence or unsupported distributions (including Bilibili channel 14 / cps markers) cause edition refusal. Exact business keys in HoYoPlay uapc metadata count as edition evidence; sub_channel alone never identifies a distribution. Without edition evidence (including config-free Sophon installs), accept the selected edition and run normal verification. Semantic version numbers alone are not edition evidence; no reliable region-specific manifest samples are currently known for shared images. CN recipes have empty verified-build sets pending live verification. Region selection persists under `region`, defaults to Mainland China only for the Mac’s CN territory, and exposes three editions in rail order. Switching region never cancels operations or sessions; inactive regions keep local records and cached art without remote requests until selected.
- **Mutation barriers:** game operations recheck durable launch-journal absence after acquiring session exclusion, before reconciliation or mutation. Runtime publication/import/replacement and removal hold exclusive component pins through cleanup; any unresolved launch journal blocks runtime mutation, even if startup could not read it or rebuild its pins. Startup retains explicit unresolved games for app reservations, quit protection and guarded retries. A spawning journal with no identities receives the full confirmed-absence startup grace; prefix-matching helpers count as starting. Cross-volume conflicts use a contained, owner-only `.macgacha-recovery/<game>/<session>` beside the installation, journaled with directory identities before moving bytes; legacy failed cross-volume intents migrate only after verifying every hidden source remains owned.
- **Session logs** can be disabled globally with `sessionLogsEnabled` in the root `launch-settings.json` (default true, separate from per-game settings). Callers pass that snapshot to log creation, proxy logging and diagnostics, and use `ProcessOutput.discard` for child stdout/stderr. Enabled sessions spawn with `SessionLog.processOutput`, never by reopening the log URL. `finish()` performs the final cap; `recover(at:)` verifies the ownership sidecar, caps stale output and resumes supervision. Retention removes only recorded inodes. Periodic truncation permits growth between ticks, and an exited launcher cannot cap a surviving child's output. Disabling session logs preserves existing logs, journals, prefix markers and file-recovery state; the launcher's path-free operational events remain enabled. Supervision only enqueues lifecycle/event lines and final caps; it never waits for their storage. Recovered logs are opened lazily on the log writer. A full queue drops the oldest pending items and counts drops. Verified end is checkpointed in the journal before enqueueing its at-most-once end line, including ends found while MacGacha was closed. The UI toggle lands with app integration.
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
  - localization: English and Simplified Chinese; HoYoPlay art and news follow the interface language.
- **In progress:** one-click Play.
  - Done so far: process spawner and inspector, recipes and resolver, session journal and file hiding, session proxy, prefix launch preparation, session logs with a global off setting and per-launch copies, session locks and runtime pins, launch manager state machine with exclusive watch/reattach/restore ownership and acknowledged recovery notices; milestone safety fixes add under-lock journal barriers, unresolved-startup protection, pinned runtime replacement and same-volume external-install recovery.
  - App launch model integration includes guarded recovery retries (5/15/60 seconds, then every minute and on activation), explicit Retry, and a launch reservation through durable finalization; the Play footer, settings and quit/recovery presentation remain pending view-layer integration.
- Region endpoint, delivery policy and art-cache foundations support Mainland China; all six game definitions, independent install folders, CN recipes/log paths and edition-aware adopt checks are implemented. CN-3 model APIs now provide locale-based persisted region selection, three visible games per region, independent lazy art/status refresh and other-region activity without cancelling operations or sessions. The region picker and rail presentation are pending Claude’s view-layer integration.
- **Planned:** HoYoPlay-style rotating banners and news, more translations, mainland China region picker and live verification, download ETA, surround and Spatial Audio, signed and notarized releases with Sparkle updates.

Update this section when a milestone task lands.
