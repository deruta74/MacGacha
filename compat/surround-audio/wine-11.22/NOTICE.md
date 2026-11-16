<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Wine 11.22 surround audio component

This component modifies the Unix CoreAudio driver of MacGacha Wine 11.22.
Wine and the MacGacha audio patch/probes are LGPL-2.1-or-later. Wine copyright
and license notices remain in the original source headers and COPYING.LIB.
Only the x86_64 Unix module is distributed. No PE DLL, game modification or
Apple graphics payload is included. System audio frameworks remain supplied
by macOS.

The official Wine 11.22 archive is pinned to SHA-256
`f172e9c1be73e862057deae1f0e03ce95919986c5df8a18e1c0829c34863c9ee`
from https://dl.winehq.org/wine/source/11.x/wine-11.22.tar.xz.
The same checksum-pinned compatibility delta and fork build support as
MacGacha Wine 11.22 are retained under build-inputs/compat/wine. Corresponding
source consists of those exact original source archives, the Wine compatibility
delta and the separate audio patch, with their retained build scripts and locks.
The complete Wine 11.22 source-delivery archive also retains both original
archives. No installed runtime is used as a build input.

Component `surround-audio-wine-11.22-1` is ABI-scoped to
`d3dmetal-wine11.22mg1.0-gptk4.0b3`. It must not be selected for Wine 11.20.
Wine 11.20 component identities and ABI scopes remain separate.

The exact MACGACHA_SURROUND=1 opt-in gate, virtual endpoint namespace,
mono/stereo-device eligibility, native multichannel handling, spatial output
routing and channel-preserving stereo fallback retain the original behavior.
The shared spatial headers are unchanged. Wine 11.22's stock mixer remains
active only on the stock path. Shared runtimes, prefixes and game files are
not modified by installing this component.

Synthetic fake-AudioUnit and abort-only dyld probes establish module packaging
and controlled behavior. They do not establish device or game audio quality.
