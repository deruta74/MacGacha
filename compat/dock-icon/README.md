<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Preserve the helper's Dock icon in Wine

This is source-only preparation for a compatible Wine runtime update. **The
published runtimes do not contain this patch.** The launcher plist key alone
does not fix their live Dock icons. No runtime catalog entry or downloadable
component is published by this change.

PR #125 rounds the ICNS stored in each Game Mode helper. Wine's macOS driver
subsequently promotes the `LSUIElement` process to a regular application and
replaces that icon with the Windows executable's `RT_GROUP_ICON` resource.
Restarting Dock does not prevent this replacement.

`wine-bundle-icon.patch` leaves that foreground transition and its menu setup
unchanged. Only when the main bundle sets `MacGachaPreserveBundleIcon = true`
does it skip `setApplicationIconImage:` and retain the bundle icon. Bundles
without the key, or with it disabled, retain Wine's existing behavior. No game
files, Windows DLLs, process injection or graphics configuration are involved.

The helper must remain `LSUIElement=true`: changing it to `false` preserved the
icon in a live test but produced two Genshin icons in Dock.

## Build and test

The source is the exact Wine fork commit used by the D3DMetal runtime:
`dbc-hbin/wine-yaagl-d3dmetal@a05983676741c558ac46937a29a93e02b38de8c7`.
The GitHub source archive has SHA-256
`fdb4adbbe5d267e20ce55838f6b8457398ee28df688ee323c7fcebbcd3aae4c0`.
The script fails closed if archive bytes change. The host compiler/SDK and
shared `compat/crypt32-fix/toolchain.lock` are checked before building.

```sh
scripts/build-dock-icon.sh /tmp/dock-icon-a --fetch-only
scripts/build-dock-icon.sh /tmp/dock-icon-a --offline
scripts/build-dock-icon.sh /tmp/dock-icon-b --offline
cmp /tmp/dock-icon-a/x86_64-unix/winemac.so /tmp/dock-icon-b/x86_64-unix/winemac.so
```

The build runs `scripts/test-dock-icon.py` against both the original and patched
Wine source. The harness compiles the actual icon-selection block and executes
it in real x86_64 `.app` bundles with absent, false and true plist values. It
verifies whether Wine installs the Windows icon; it does not simulate the
entire Wine process or prove Dock behavior on its own.

The output is a signed test `x86_64-unix/winemac.so` plus audit logs and its
checksum. It is **not** an installer, release archive, or general-purpose
replacement driver. The build omits Vulkan and has only been exercised on the
pinned Wine 11.20 D3DMetal route. Do not install it into Wine 11.0/DXMT, replace
the existing component, or overwrite a helper file: helper files are hard links
to immutable runtime files. A production runtime must be built with its full
original feature configuration, tested, and published under a new immutable ID.

## Live evidence and remaining work

On 2026-11-08, Global Genshin 7.2 on D3DMetal with a private cloned runtime and
the opt-in helper plist showed one rounded Dock icon while the game was running.
The loaded helper module was verified to share the private test module's inode.
The user also confirmed the rounded icon. Original runtime bytes were unchanged.
The unpatched D3DMetal and DXMT routes, and the route with Game Mode off, showed
the square Windows icon. These observations are icon/launch checks, not a new
long-session gameplay qualification.

Before enabling delivery: test ZZZ after installation, qualify the complete
production Wine build, test the supported Wine 11.0/DXMT build separately, and
publish compatible runtime versions through the normal immutable catalog flow.
The fallback route without a helper has no bundle icon to preserve.
