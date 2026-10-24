<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Wine 11.20 crypt32 compatibility fix

Mainland China Genshin Impact and Zenless Zone Zero can crash in MHYPBase.dll
after signature verification fails (AAGL issue #572). Wine 11.20 sorts the
authenticated attributes before hashing, even when the signer used a different
order. Wine MR [11824](https://gitlab.winehq.org/wine/wine/-/merge_requests/11824)
preserves the encoded order on verification; signing still uses canonical order.

This is a fix to Wine's implementation of a Windows API. It is not an anti-cheat
patch, does not modify a game and does not inject anything into a game process.
It applies even when game compatibility patches are switched off.

Only `d3dmetal-wine11.20-gptk4.0b3`, CN Genshin and CN ZZZ require this component.
Global editions, Star Rail and DXMT are unchanged. **Drop the component and its
requirement once the affected runtime uses Wine 11.21 or later.** Do not reuse
this DLL with a different Wine ABI. The installed runtime is dbc-hbin's
yaagl-wine-11.20, source commit `a05983676741c558ac46937a29a93e02b38de8c7`;
the owner verified a stock 11.20 DLL with this fix in that runtime.

## Pinned build inputs

- Source: <https://dl.winehq.org/wine/source/11.x/wine-11.20.tar.xz>
- SHA-256: `eac8ca448f9c0087f963026b4dc276d1e2b7fbb64056edc093e59bbb7e56fe28`.
- Fix: `a358d7ecf13b420d7fa65d54fcad1f96003d7a48`.
- Regression: `840a939ee526137639665ff5f587224d6a36403f`.
- Both unmodified commit patches are in `patches/`; the script verifies their
  digests and applies them with zero fuzz before building.
- The separately identified LGPL native-prefix patch initializes the Unix half
  by Wine's name-based `__wine_load_unix_lib` API when no builtin mapping exists,
  and releases that reference on dynamic detach. It loads the **existing runtime
  crypt32.so**, not a new or downloaded Unix module. No signature-verification
  code is changed by this adaptation.
- `toolchain.lock` extends the Steam shim's exact eight-bottle MinGW closure
  with Bison 3.8.2. GCC 16.2.0, MinGW-w64 14.0.0_3 UCRT and binutils
  2.47.20260726 are unchanged. The shared installer/checker accept `--lock`;
  omitting it retains the Steam shim's original lock and behavior.
- Host tools: arm64 macOS 27, Apple clang 21.0.0 (`clang-2100.3.34.2`), SDK 27.0,
  the OS flex/m4/make/patch tools. Host versions and configure output are audited.
  Optional gettext translations are disabled, so an ambient msgfmt cannot change
  the DLL's resources. GCC's direct-assembler driver is confined to the same
  locked prefix, including when Wine generates import libraries.
  The workflow's `xcode-27` runner label is mutable; pinned input/output hashes
  reject drift rather than pretending that a VM image is immutable.

## Rebuild

```sh
export STEAM_SHIM_TOOLCHAIN_PREFIX=/tmp/crypt32-toolchain
python3 -I scripts/install-steam-shim-toolchain.py "$STEAM_SHIM_TOOLCHAIN_PREFIX" \
  --lock compat/crypt32-fix/toolchain.lock
export PATH="$STEAM_SHIM_TOOLCHAIN_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CRYPT32_FIX_CACHE_DIR=/tmp/crypt32-cache-a scripts/build-crypt32-fix.sh /tmp/crypt32-a --fetch-only
CRYPT32_FIX_CACHE_DIR=/tmp/crypt32-cache-b scripts/build-crypt32-fix.sh /tmp/crypt32-b --fetch-only
CRYPT32_FIX_CACHE_DIR=/tmp/crypt32-cache-a sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  scripts/build-crypt32-fix.sh /tmp/crypt32-a --offline --verify
CRYPT32_FIX_CACHE_DIR=/tmp/crypt32-cache-b sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  scripts/build-crypt32-fix.sh /tmp/crypt32-b --offline --verify
cmp /tmp/crypt32-a/x86_64-windows/crypt32.dll /tmp/crypt32-b/x86_64-windows/crypt32.dll
cmp /tmp/crypt32-a/crypt32-fix-wine-11.20-1.zip /tmp/crypt32-b/crypt32-fix-wine-11.20-1.zip
```

Every build extracts a fresh source tree and uses a fresh out-of-tree build.
No installed runtime or prefix is used or modified. The source download and
the actual compilation are separate; offline builds never fetch inputs.
`SOURCE_DATE_EPOCH=0`, UTC/C locale, fixed GCC random seed, file/debug prefix maps,
zero PE timestamps, disabled linker build IDs and `strip --strip-debug` remove
variable build data. ZIP paths, order, timestamps and modes are fixed; local
audit logs containing paths are excluded. `SHA256SUMS` pins the DLL, and the
runtime manifest additionally pins the complete ZIP, so neither comparison
can silently bless different bytes. This is reproducibility with the locked
toolchain/host contract, not a claim about arbitrary compilers or operating systems.

The DLL ZIP includes notices, the LGPL text, patches, the build script and locked
toolchain inputs. The manual workflow creates a **draft** release named
`crypt32-fix-wine-11.20-1` with that ZIP and the exact Wine source tarball beside
it for LGPL corresponding-source access. Only the owner publishes it. Do not
commit downloaded sources, compiled DLLs, archives or build output.

## Loader choice and session ownership

Wine 11.20 `dlls/ntdll/unix/loader.c`, `set_dll_path()` (lines 295–315), appends
the installed `dll_dir` **before** the `WINEDLLPATH` entries. `find_builtin_dll()`
walks that list in order. Consequently WINEDLLPATH cannot override the runtime's
crypt32 builtin. Source: the pinned tarball above, also
<https://github.com/wine-mirror/wine/blob/wine-11.20/dlls/ntdll/unix/loader.c>.

LaunchManager uses LaunchCopies' inode-bound, verified prefix publication to
copy `x86_64-windows/crypt32.dll` into that session's system32 and sets
`WINEDLLOVERRIDES=crypt32=n,b`. A missing source is an error, never an optional
skip. Runtime files are read-only. The required component is pinned with the
session and its identity is persisted in the journal. The pinned runtime’s `bin/wine` wrapper unsets `WINEDLLOVERRIDES`;
LaunchPreparation also writes `crypt32=native,builtin` to this prefix’s
`HKCU\Software\Wine\DllOverrides`, using its existing wineserver/registry
persistence barrier. The wrapper keeps its D3DMetal policy and is not bypassed
or edited. This policy is not a system-wide Wine setting. The verified prefix copy
survives launcher death; reattachment only observes the snapshot and does not
re-evaluate recipes, copy files or recreate a process. Each game/bundle has its
own prefix, so the replacement cannot leak to Global, DXMT or a future bundle.

`load_builtin()` (lines 1264–1268 of the same source) also forces builtin-first
for files carrying winebuild's `Wine builtin DLL` signature, even with `n,b`.
The build therefore checks and clears that **32-byte DOS-stub marker** after
stripping. It changes no executable code, imports or PE layout. Keeping the
marker would silently load the runtime's unfixed DLL. This deliberate native
identification is part of the pinned output hash.
Wine's `libs/winecrt0/unix_lib.c` and `loader.c:load_unixlib_by_name()` provide
the name-based lookup used by the native-prefix initialization adaptation.

The build also creates `audit/crypt32-probe.exe` from the upstream synthetic
signature regression (no game files). Run the gated loader check with both
`MACGACHA_RUNTIME_FIXTURES` and `MACGACHA_CRYPT32_FIX_BUILD=/absolute/build/output`:
`swift test --package-path Packages/LauncherKit --filter Crypt32FixIntegrationTests`.
It installs an isolated 11.20 bundle/prefix, proves the stock DLL rejects the
signature and the prefix-only replacement accepts it, checks the runtime's DLL
digest is unchanged, then performs checked Wine shutdown before deleting state.

`runtimeSetupRequirements(for:)` includes `crypt32-fix-wine-11.20-1` after the
bundle for these exact game/bundle combinations, independently of the optional
game-patches toggle. The plan uses the localized component name and manifest
size. `missingComponents` derives from these same requirements, so Play remains
blocked until recommended setup installs the component.
