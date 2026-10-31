<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Wine 11.20 surround audio

ABI-scoped component `surround-audio-wine-11.20-1` for
`d3dmetal-wine11.20-gptk4.0b3`. The only binary is
`x86_64-unix/winecoreaudio.so`. No mmdevapi changes, game modifications, launch
requirements or per-game switch ship here. A later change will replace the
module in a verified per-game Game Mode helper; never replace shared runtimes.

Only the exact environment value `MACGACHA_SURROUND=1` activates the patch.
Unset, empty and other values use Wine's original format, endpoint IDs and
render path, without extra logging or AudioUnit calls. Capture stays stock.
Only mono/stereo output devices expose 7.1 surround float at the device's nominal
rate. Devices with six or more output channels keep their own layout (including
5.1), endpoint IDs and stock AUHAL discrete rendering. Unknown channel counts and
three-to-five-channel devices also stay stock. A pure C eligibility decision is
covered by all 16 combinations of 1/2/6/8-channel devices and streams. Device
channels are queried afresh from the selected endpoint during each stream's
Initialize; mid-stream changes follow Wine's existing re-initialization path.
Mono/stereo streams always bypass the mixer. A separate, reversible endpoint UID
namespace for virtualized mono/stereo devices keeps mmdevapi's cached
PhysicalSpeakers value separate from stock endpoints, entirely on the Unix
side; turning off the gate restores the original IDs and cached settings.
This can reset a game's saved Windows endpoint selection when opting in.

An 8-channel float 0x63f stream feeds Apple's AUSpatialMixer Ambience Bed through
a bounded planar bridge. Output routing follows the tested spike: headphones,
built-in speakers, or external speakers, with processed stereo output. This
version preserves Wine's native multichannel path and does not promise Control
Center spatial status. Other formats (including six-channel mixer inputs) and
any setup failure use stock Wine for that stream.
Failure to query, enable or confirm optional head tracking keeps spatial audio
running; external listener-orientation tracking is deferred. The render callback
allocates nothing, queries no properties and logs nothing. Opted-in stream setup
writes exactly one path-free stderr line:

```
macgacha-surround: stream output=<type> device-channels=<n> channels=<n> rate=<hz> spatial=<on|off:<reason>|fallback:<stage>:<osstatus>>
```

## Offline rebuild and verification

Reuse the crypt32 installer/checker and `compat/crypt32-fix/toolchain.lock`;
there is no independent toolchain lock. The locked compiler closure, Apple
clang 21.0.0 (clang-2100.3.34.2), SDK 27.0 and arm64 macOS 27 are required.
Rosetta must already be installed for x86_64 host tools and the synthetic load
probe. No Wine executable, prefix, game or audio device is opened by the checks.

```sh
SURROUND_AUDIO_CACHE_DIR=/path/to/cached/source scripts/build-surround-audio.sh /tmp/surround-a --offline --verify
SURROUND_AUDIO_CACHE_DIR=/path/to/cached/source scripts/build-surround-audio.sh /tmp/surround-b --offline --verify
cmp /tmp/surround-a/surround-audio-wine-11.20-1.zip /tmp/surround-b/surround-audio-wine-11.20-1.zip
MACGACHA_SURROUND_AUDIO_BUILD=/tmp/surround-a swift test --package-path Packages/LauncherKit --filter SurroundAudioIntegrationTests
```

The cache must contain the pinned `wine-11.20.tar.xz` (see NOTICE.md). Offline
mode never fetches anything. `--fetch-only` is for the manual workflow's separate
source-fetch phase. Each build uses fresh extracted sources and an out-of-tree
build. Fixed locale/epoch, deployment target, prefix maps, GCC seed, stripped
debug symbols, content-derived Mach-O UUIDs, timestamp-free ad-hoc signing and
fixed ZIP ordering, timestamps and modes make the output reproducible under
the locked host contract. Audit files are excluded. SHA256SUMS pins the ZIP;
PATCHSUMS pins the patch. The ZIP includes notices, LGPL text and build inputs.

Every build runs the native fake-AudioUnit tests (gate, formats, channel routing,
planar bounds, optional tracking and failure cleanup) and checks architecture,
exports, system-only dependencies, ZIP payload and a synthetic dyld load.
The load check substitutes an abort-only ntdll symbol stub and never calls a
Wine entry point: it proves dyld loading and exports, not real Wine ABI or game
audio acceptance. The gated Swift test additionally installs the pinned ZIP
through ComponentInstaller into a temporary root and removes it afterward.

The manual-only workflow builds twice offline, checks both ZIP bytes against
the pin and manifest, and attaches the ZIP plus original Wine source to a draft
release. Only the owner publishes it. Never commit build products or downloads.
