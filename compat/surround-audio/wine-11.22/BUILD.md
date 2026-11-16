<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Surround for Wine 11.22

Component `surround-audio-wine-11.22-1` supports only
`d3dmetal-wine11.22mg1.0-gptk4.0b3`. Historical 11.20 revisions, archives,
checksums and scopes are retained unchanged. Installing a module never enables
the per-game Surround preference.

The source is reconstructed from the official Wine 11.22 archive and the exact
compatibility delta in `../../wine/source-runtime-11.22.lock.json`. The separate
audio patch modifies only the Unix CoreAudio driver. Its two shared spatial
headers are unchanged from the 11.20 patch. The port retains Wine 11.22's stock
mixer and late stock output start outside the spatial path, and disposes spatial
resources on both failed initialization and stream release. The native harness
retains the gate, endpoint, 1/2/6/8 device-by-stream matrix, optional source-kind
and tracking failures, channel-preserving downmix and cleanup checks.

Use the existing crypt32 toolchain lock. Apple clang 21.0.0, SDK 27.0, arm64
macOS 27 and already installed Rosetta are required. The build uses no installed
Wine runtime. Fetch is separate from both fresh offline builds:

```sh
SURROUND_AUDIO_CACHE_DIR=/tmp/surround-cache scripts/build-surround-audio-1122.sh /tmp/surround-unused --fetch-only
profile='(version 1) (allow default) (deny network*)'
SURROUND_AUDIO_CACHE_DIR=/tmp/surround-cache sandbox-exec -p "$profile" scripts/build-surround-audio-1122.sh /tmp/surround-1122-a --offline --verify
SURROUND_AUDIO_CACHE_DIR=/tmp/surround-cache sandbox-exec -p "$profile" scripts/build-surround-audio-1122.sh /tmp/surround-1122-b --offline --verify
cmp /tmp/surround-1122-a/x86_64-unix/winecoreaudio.so /tmp/surround-1122-b/x86_64-unix/winecoreaudio.so
cmp /tmp/surround-1122-a/surround-audio-wine-11.22-1.zip /tmp/surround-1122-b/surround-audio-wine-11.22-1.zip
python3 -I scripts/test-surround-audio.py --wine-1122
MACGACHA_SURROUND_AUDIO_1122_BUILD=/tmp/surround-1122-a swift test --package-path Packages/LauncherKit --filter SurroundAudioIntegrationTests
```

The cache contains `wine-source.tar.xz` and
`wine-11.20-build-support.tar.gz`, authenticated by the source lock. The ZIP
contains the module, LGPL text, notices, module checksum and exact patch/build
inputs. Corresponding source delivery also requires both original archives.
The manual-only `surround-audio-1122.yml` attaches those inputs to a draft,
without publishing it. It was not dispatched during local qualification.

Local qualification on 2026-11-16 produced identical network-denied builds:

| Item | Value |
|---|---|
| ZIP | `/tmp/macgacha-surround-1122/build-c/surround-audio-wine-11.22-1.zip` |
| Independent ZIP | `/tmp/macgacha-surround-1122/build-d/surround-audio-wine-11.22-1.zip` |
| ZIP SHA-256 | `749ff445d88eea75453a1fc0c4f7d62d4318fa1033138c2afee1930c3ac50a04` |
| ZIP bytes | 250,245 |
| Extracted regular bytes | 950,498 across 21 entries |
| Module SHA-256 | `7ce6e1037456df68d8a4e8422e94c2702a667bbfb2bdaa9012398e737aec699b` |

The checker validates x86_64 architecture, strict ad-hoc signature, Unix-call
exports, the exact ntdll import list, system-only dependencies, deterministic
ZIP metadata and synthetic dyld loading with abort-only ntdll stubs. The gated
Swift test verifies the manifest pin, installs through ComponentInstaller in a
temporary root, checks module bytes, loads synthetically and removes the module.
These checks do not execute Wine entry points, open an audio device or prove
device/game audio quality. Real-device and gameplay acceptance remain pending.

Unsigned catalog r4 and the app baseline recommend this module for 11.22.
Bundle switches pair compatible unpinned helpers in one selection transaction.
Automatic updates stage an installed ABI helper alongside Wine and verify both
receipts before activation. Failed or cancelled staging retains the old selection.
Explicit rollback selects and, if necessary, installs the legacy matching helper.
Incompatible helper pins block the switch. Metadata refresh remains selection
neutral and session/recovery pins keep the exact captured component identity.

The final `scripts/test.sh` run passed with 1529 package tests, 354 app tests,
both native harness variants, policy/string checks, a Release build and zero
Swift source warnings. The full log is `/tmp/macgacha-surround1122-verified.log`.
