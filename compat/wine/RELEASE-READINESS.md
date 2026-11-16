# MacGacha Wine qualification

Wine 11.20 evidence below is historical and shipped with 0.3.0. The Wine 11.22
local candidate and remaining gates are recorded in the final section.

## Qualified local candidate

Wine `11.20-macgacha1-preview4`, SHA-256:
`c3b9d33653c6585fed36edf819e6239cae5a385f87fd4f0e2d093c848f15ec7e`.

Two independent source SDK/Wine builds followed by deterministic finalization produced identical archives. All 4147 runtime inventory entries matched. Twenty pinned source packages supply the SDK and build tools. TLS trust anchors, fonts, wineboot, Windows execution and actual synthetic H.264/MP4 decoding passed isolated probes.

Local Global Genshin 7.2 and ZZZ 3.3 reached startup/login screens with DXMT and D3DMetal. Genshin D3DMetal initially stopped at the terms dialog without accepting it automatically. One hour of stable Genshin gameplay was subsequently reported with D3DMetal, FPS Unlock 120 and working Surround on 2026-11-11. This is user-reported gameplay/audio evidence, distinct from automated probes. ZZZ/DXMT Game Mode was On on repeat without code changes. The earlier Off observation has no proven root cause.

Private screenshots, logs, account data and local machine inventories must not be committed.

## Integration and live checks — 2026-11-12

The candidate is integrated as the `wine-11.20-macgacha-1.0` component with DXMT and modular D3DMetal bundles, recommended for both backends in catalog revision 3. A Debug build with the signed revision 3 catalog installed and activated the new bundles automatically, kept Play available during background installation, and removed replaced versions after qualifying sessions. Global Star Rail ran on DXMT and D3DMetal, Global Genshin on D3DMetal with FPS unlock and Surround, and explicit rollback to the previous DXMT bundle worked. Star Rail's in-game hotfix restart showed no login window once. A normal relaunch logged in. Mainland China editions are not qualified by this matrix.

## Packaging check — 2026-11-11

The retained preview4 runtime and source-delivery archives passed SHA-256 and archive-member validation. Their unpacked runtime/source inventories matched the saved receipts. Packaged Wine probes were rerun successfully with original SDKs denied.

The complete local test script passed using a SwiftPM scratch directory and Xcode derived data outside Documents. An initial run inside the existing Documents `.build` failed code signing because of Finder metadata. Package tests, app tests, string checks and the Release build passed on the clean path. No Swift source compiler warnings were emitted. Xcode emitted AppIntents metadata and dependency-scan warnings.

A local preparation DMG was built and verified, including strict app code-signature verification, embedded framework loading and `hdiutil verify`. The 0.3.0 DMG is built by the release workflow.

## Wine 1.0 release mapping — 2026-11-12

MacGacha Wine 11.20, build 1.0, uses the qualified preview4 archive unchanged.
The preview label occurs only in the external build receipt and source lock,
not in any runtime archive member, wrapper or MACGACHA-NOTICE.md. The archive
contains `wine/bin/wine` and `wine/bin/wine.real`, matching the existing Wine
component root and loader layout.

Release asset: `wine-11.20-macgacha-1.0.tar.xz`, 91,726,084 bytes, SHA-256
`c3b9d33653c6585fed36edf819e6239cae5a385f87fd4f0e2d093c848f15ec7e`.
`prepare-wine-release.py CANDIDATE OUTPUT` verifies the retained inventories
and creates that unchanged binary, its checksum, and a complete source/notice
archive with the original receipt and release mapping. The optional manual
workflow step attaches these to a draft prerelease, refuses published releases
and always sets `latest=false`. Publication is a separate step.
No release has been created or published by this integration task.

## Launcher integration preparation

Catalog r2 adds MacGacha Wine 11.20 for DXMT through the existing profile.
Catalog r3 and the app baseline add modular D3DMetal with the consented graphics
payload. Old apps reject r3 and retain r2. The debug-only local catalog argument
allows qualification before any publication. Star Rail DXMT, Genshin and
ZZZ D3DMetal, optional Surround/FPS, imported GPTK and manual rollback still
require checks against this integrated build. The app version and
release-note filename remain unchanged as requested for this preparation.

## Wine 11.22 local candidate — 2026-11-15

The official `wine-11.22` tag points to
`9f8c4ae4d35c7ff4153267aba9618c026f5f5583`. The WineHQ archive SHA-256 is
`f172e9c1be73e862057deae1f0e03ce95919986c5df8a18e1c0829c34863c9ee`.
Both the release archive signature and annotated tag signature were verified
with signing fingerprint `DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D`.
Both MR 11824 commits, `a358d7ecf1` and `840a939ee5`, are ancestors of the tag.
No crypt32 patch is applied to this source.

The source lock retains the exact 11.20 fork archive as build support and
corresponding source for the compatibility delta. Only three build/staging
scripts are copied directly. Runtime changes enter through the pinned delta
and its 116-file result manifest, checked byte for byte before compilation.
The port retains paired MSync, the ARM64 server for x86 clients, D3DMetal/FSR
bridges and cursor handling. The macOS driver preserves upstream 11.22
IOSurface double buffering, alpha and shape handling with a reconciled queue
and window lifetime barrier. Server protocol tables were regenerated from the
11.22 protocol with the retained extensions. The opt-in Dock icon patch is
applied separately. Wine, fork and dependency notices accompany the sources.
Apple graphics and sidecars are not included in this Wine archive.

### Binary and source builds

Two fresh independent SDKs each built all 20 pinned source packages. Both
Wine builds used those separate SDKs and the locked Clang, macOS SDK, Bison
and LLVM MinGW inputs, with network and Homebrew reads denied. Deterministic
finalization produced identical tar.xz bytes and all 4152 runtime inventory
entries matched.

Release identity: `wine-11.22-macgacha-1.0`.
Archive: **91,950,420 bytes**, installed regular files: **620,124,132 bytes**.
SHA-256: `4daf157d0438c014ce3d9175cdf846f36ddc7f2b3514d4180ff3602b31591423`.
The original build receipt label is `11.22-macgacha1-preview1`. The release
mapping copies the verified archive unchanged and retains complete source
inputs and receipts. The source archive is 202,335,776 bytes, SHA-256
`2efc90b7a3ea76fd6e65d1a28ad384629ced845a4bad895703af68ab20ef0905`.
The receipt's original pre-comparison status is historical,
with the independent archive and inventory comparison recorded here.

Packaged probes passed with both SDKs, both original Wine work roots,
Homebrew and installed application runtimes denied. They checked native
library loading, system TLS trust anchors, FreeType/GStreamer, actual decoding
of the synthetic two-frame H.264 fixture, wineboot, Windows command execution,
font enumeration/text metrics and checked prefix shutdown. Native MSync and
cursor harnesses each passed eight tests. The production IOSurface queue
harness passed including AddressSanitizer. Its stand-in main-thread dispatcher
does not establish real AppKit scheduling or gameplay correctness.

### Catalog and ABI boundaries

The unsigned catalog source is revision 4, recommending the new Wine component
for DXMT and modular D3DMetal through distinct compiled 11.22 profiles. Every
published historical descriptor and binding remains unchanged. Current apps
with only the old profiles reject r4 and retain their working metadata.
New-app tests cover refresh retaining old pinned selections, explicit rollback,
generic helper compatibility and exclusion of the 11.20 ABI overlays.

crypt32 remains scoped to the original Wine 11.20 profiles. The 11.22 bundles
use Wine's upstream implementation and do not require that component.
The historical Surround modules remain scoped to Wine 11.20. The separate
`surround-audio-wine-11.22-1` module is now built and paired with the 11.22
D3DMetal profile. Automatic updates stage the installed unpinned helper with
Wine, verify both receipts and activate both selections together. Helper pins
remain authoritative. Explicit rollback pairs the compatible legacy helper,
including when only the helper needs installation. Failures and cancellation
retain the previous selection. Device and game audio quality still require
live acceptance.

### Reproduction and local integration checks

Use fresh roots outside Documents and the same sandbox policy as the manual
Wine workflow. Fetch inputs first, then run offline:

```sh
python3 -I scripts/build-wine-dependencies.py /tmp/deps-a --cache /tmp/deps-cache --fetch-only
python3 -I scripts/build-wine.py /tmp/wine-a --dependencies /tmp/deps-a --runtime-lock compat/wine/source-runtime-11.22.lock.json --cache /tmp/wine-cache --fetch-only
for suffix in a b; do
  python3 -I scripts/build-wine-dependencies.py /tmp/deps-$suffix --cache /tmp/deps-cache --offline
  python3 -I scripts/build-wine.py /tmp/wine-$suffix --dependencies /tmp/deps-$suffix --runtime-lock compat/wine/source-runtime-11.22.lock.json --cache /tmp/wine-cache --offline --bison /tmp/deps-$suffix/tools/bin/bison
  python3 -I scripts/finalize-source-wine.py /tmp/wine-$suffix /tmp/wine-final-$suffix
done
cmp /tmp/wine-final-a/11.22-macgacha1-preview1.tar.xz /tmp/wine-final-b/11.22-macgacha1-preview1.tar.xz
python3 -I scripts/check-wine.py /tmp/wine-final-a /tmp/wine-probe --deny-read /tmp/deps-a --deny-read /tmp/deps-b --deny-read /tmp/wine-b/work
python3 -I scripts/test-wine-surface-queue.py /tmp/wine-a/work/source-archive/wine-11.22 --sanitize-address
python3 -I scripts/prepare-wine-release.py /tmp/wine-final-a /tmp/wine-release --release wine-11.22-macgacha-1.0
```

The prepared Debug build trusts only its generated local test key. Its signed
r4 copy is separate from the unsigned repository source and uses no release
private key. The exact owner-run command is:

```sh
env CFFIXED_USER_HOME=/tmp/macgacha-1122/debug/home /tmp/macgacha-dd-wine1122-debug/Build/Products/Debug/MacGacha.app/Contents/MacOS/MacGacha -MacGachaDebugCatalog /tmp/macgacha-1122/debug/runtime-catalog.json -MacGachaDebugArchiveDirectory /tmp/macgacha-1122/archives
```

The command uses an isolated temporary home for application data. Foundation's home-directory resolution was verified separately without launching the app.
The application has not been launched by this task. The debug catalog tests
metadata and selection presentation. Its GitHub archive URLs become usable
only after separate publication. The Debug archive directory below supplies
verified local files for pre-publication qualification. Synthetic launch tests use verified local
archives through the real component installer and manager instead.

### Combined repository validation

The complete local test script passed with **1522 package tests**, **347 app
tests**, string checks, build/policy regression checks and a Release build.
No Swift source warnings were emitted. New tests cover source/patch/result
integrity, immutable r3-to-r4 migration and rollback, 11.22 helper exclusions,
Surround activation races and setup on both historical and current baselines.
The historical crypt32/Surround assertions remain tied to immutable r3 fixtures.

Opening the generated project under Documents blocked in NSFileCoordinator
despite locally readable contents. The same project specification and sources
passed with the generated project and derived data outside Documents. The
optional bootstrap path refuses to replace unrelated existing input paths.
No toolchain or source pin changed to accommodate this environment issue.

```sh
USER="$(id -un)" MACGACHA_XCODE_PROJECT_DIR=/tmp/macgacha-wine1122-full-project MACGACHA_DERIVED_DATA_PATH=/tmp/macgacha-dd-wine1122-final scripts/test.sh
```

### Remaining gates

Both synthetic D3D11 compositions passed through the real installer and
LaunchManager, including the ready/release handshake, verified running state
and checked teardown. The D3DMetal and DXMT probes each reported feature level
`0xb000`.
No real game has been launched. Global Genshin, Star Rail and ZZZ
on both backends, CN Genshin/ZZZ startup without the crypt32 component,
long-session stability, actual Game Mode/cursor behavior and audio quality
remain separate live acceptance. No runtime, catalog or app release is
published by this work.


### Surround 11.22 follow-up

The Unix-only patch retains the original gate, endpoint rules, multichannel
handling, spatial routing and channel-preserving stereo fallback. Both shared
spatial headers are byte-identical to the 11.20 patch. Wine 11.22's stock mixer
and delayed stock start remain on the stock path, with spatial cleanup on both
failure and release. No Wine entry point or audio device was opened.

Two fresh offline builds with networking denied produced identical modules and
ZIPs from the official Wine archive plus the exact MacGacha compatibility delta.
Compiler, SDK and dependency pins remain unchanged.

- ZIP: `/tmp/macgacha-surround-1122/build-c/surround-audio-wine-11.22-1.zip`
- Independent rebuild: `/tmp/macgacha-surround-1122/build-d/surround-audio-wine-11.22-1.zip`
- ZIP SHA-256: `749ff445d88eea75453a1fc0c4f7d62d4318fa1033138c2afee1930c3ac50a04`
- ZIP bytes: 250,245. Extracted regular bytes: 950,498 in 21 entries.
- Module SHA-256: `7ce6e1037456df68d8a4e8422e94c2702a667bbfb2bdaa9012398e737aec699b`

The native fake-AudioUnit matrix, strict export/import/dependency checks,
synthetic dyld load and gated ComponentInstaller installation/removal pass.
Unsigned catalog r4 and the app baseline recommend the new ABI-specific helper,
preserving every historical descriptor and binding. Paired update, cancellation,
rollback, startup adoption, per-game setup and recovery/session-pin checks cover
the new profile. See `../surround-audio/wine-11.22/BUILD.md` for reproduction.
The final full `scripts/test.sh` run passed with **1529 package tests**, **354
app tests**, both native audio harness variants, policy/string checks and a
Release build. No Swift source warnings were emitted. The complete log is
`/tmp/macgacha-surround1122-verified.log`. Generated project and derived data
remained outside Documents.
No workflow, publication, real game or real-device audio check was performed.


### Debug archives for pre-publication qualification

`-MacGachaDebugArchiveDirectory /absolute/dir` is accepted only in Debug.
Runtime component installation and automatic staging select a regular file
whose name exactly matches the descriptor URL's last path component. The file
is captured once per installation and streamed in bounded chunks through the
ordinary download size and SHA-256 checks. Missing regular files use the normal
network path. A local mismatch fails without selecting another file or falling
back to the network. Pipeline verification retries rewind the captured file.
Consent, catalog signatures, extraction rules and component pins remain enforced.
Release builds compile out the argument parser and local archive implementation.

The isolated Debug app has been rebuilt at
`/tmp/macgacha-dd-wine1122-debug/Build/Products/Debug/MacGacha.app` with the
existing local test public key. Its signed catalog at
`/tmp/macgacha-1122/debug/runtime-catalog.json` is byte-identical to the current
unsigned r4 source, including the separate Wine 11.22 Surround component.
The detached signature was verified with that local public key. No release
signing key is used.

The prepared `/tmp/macgacha-1122/archives` directory contains every new r4
runtime archive relative to the immutable r3 fixture, under its release name:

| Archive | Bytes | SHA-256 |
|---|---:|---|
| `wine-11.22-macgacha-1.0.tar.xz` | 91,950,420 | `4daf157d0438c014ce3d9175cdf846f36ddc7f2b3514d4180ff3602b31591423` |
| `surround-audio-wine-11.22-1.zip` | 250,245 | `749ff445d88eea75453a1fc0c4f7d62d4318fa1033138c2afee1930c3ac50a04` |

Both copies were verified against their r4 descriptors. Existing r3 archives
continue to use their normal published URLs when absent from this directory.
The exact launch command is the combined Debug-catalog command above.
It has not been executed. The prepared app has not been launched and no game
has run. Application execution was limited to `xcodebuild test` hosts.
No real application data, release assets or publication state was changed.

The final full `scripts/test.sh` run passed with 1533 package tests, 356 app
tests, policy/string checks, a Release build and zero Swift source warnings.
The strict cooperative-pool DownloadEngine run passed 302 tests. The Debug
argument marker is present in the isolated Debug binary and absent from the
Release binaries. The local catalog signature and the embedded test public
key were verified without launching the prepared app. The full test log is
`/tmp/macgacha-debug-archives-verified.log`, with strict-pool events in
`/tmp/debug-archives-strict.jsonl`.
