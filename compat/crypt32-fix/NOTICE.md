<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Third-party notices: crypt32-fix-wine-11.20-1

`x86_64-windows/crypt32.dll` is built from Wine 11.20 with Wine MR 11824 and the
documented native-prefix Unix-companion initialization adaptation (Copyright
(c) 2026 deruta74, LGPL-2.1-or-later). The Wine builtin DOS marker is cleared.
Wine and its contributors retain their copyrights. This library and the two
upstream patches are **LGPL-2.1-or-later**, not MacGacha's GPL license.
The complete LGPL 2.1 text is provided in COPYING.LIB. No game code, Apple code
or Microsoft DLL is included. The synthetic signature fixture is upstream Wine
test data, not a game binary or third-party signed executable.

Wine source: <https://dl.winehq.org/wine/source/11.x/wine-11.20.tar.xz>
(SHA-256 recorded in README.md). The exact archive is also attached to the same
release as the DLL at
<https://github.com/deruta74/MacGacha/releases/tag/crypt32-fix-wine-11.20-1>.
The release ZIP's build-inputs directory provides both patches, build scripts
and toolchain locks. Together these are the corresponding build inputs; users
may modify, rebuild and replace the library under the LGPL. MacGacha does not
restrict reverse engineering for debugging modifications of this library.

Upstream fix by Michael Nelson, commits:
- <https://github.com/wine-mirror/wine/commit/a358d7ecf13b420d7fa65d54fcad1f96003d7a48>
- <https://github.com/wine-mirror/wine/commit/840a939ee526137639665ff5f587224d6a36403f>

MacGacha's original build scripts and documentation remain GPL-3.0-only, with
the additional attribution term in the root NOTICE. The shared MinGW installer
uses separately licensed Homebrew toolchain bottles only as build inputs; they
are not shipped as part of the DLL component. See compat/steam-shim for those
locked-toolchain details. Publishing this artifact requires the owner's action.
