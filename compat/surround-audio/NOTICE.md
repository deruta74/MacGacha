<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Wine surround audio component

This component modifies Wine 11.20's Unix CoreAudio driver. Wine is copyright
its contributors, including Andrew Eikum (CodeWeavers) and Huw Davies, and is
licensed under LGPL-2.1-or-later. See COPYING.LIB and Wine's source headers.
The MacGacha patch and native probes are LGPL-2.1-or-later as well.

No code from other third-party projects is included. The module dynamically
uses macOS system audio frameworks, supplied by the operating system.

Corresponding source is the exact wine-11.20.tar.xz attached beside the ZIP,
plus the patch, build scripts and locked toolchain inputs in build-inputs/.
Source: https://dl.winehq.org/wine/source/11.x/wine-11.20.tar.xz
SHA-256: eac8ca448f9c0087f963026b4dc276d1e2b7fbb64056edc093e59bbb7e56fe28

Only d3dmetal-wine11.20-gptk4.0b3 is supported. Surround audio is opt-in through
the per-game setting. Shared runtimes and game files remain unchanged.

Revision 2 tolerates unavailable optional CoreAudio source-kind metadata and
preserves all channels with an explicit stereo downmix if spatial setup fails.
