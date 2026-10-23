<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Steam launcher build

## Artifact and license gate

Only **`steam32.exe` and `steam64.exe`** are produced. These are PE32 i386 and
PE32+ x86-64 builds of Proton's launcher. They may be redistributed with the
notices in [NOTICE.md](NOTICE.md). No binary publishing is authorized by this
build, and no binaries or downloaded sources are committed.

**`lsteamclient32.dll` and `lsteamclient64.dll` are omitted.** They are not cleared
for redistribution: their Steamworks SDK license grants object-code distribution
only for SDK `redistributable_bin` files, not this custom DLL. A MinGW compilation
of `steamclient_main.c` also stops at the missing `wine/unixlib.h`; upstream
`Makefile.in` declares `UNIXLIB = lsteamclient.so`, and the PE code invokes
`WINE_UNIX_CALL`. Building PE entry points would not supply that Unix implementation.
We do not fabricate a Steam API stub, and do not ship the SDK or a Unix module.
See NOTICE for the exact terms. Adding this DLL is a new licensing/porting gate.

## Pinned inputs

- Proton tag: **`proton-10.0-4`**.
- Proton commit: **`e2becb87430ca3ff510d949d9e75fa9b401da489`**.
- Repository: <https://github.com/ValveSoftware/Proton>.
- Fetched blobs only: `steam_helper/steam.c` and `steam_helper/Makefile.in`.
  No checkout or submodule initialization. The script verifies both the tag's
  resolved commit and each blob's SHA-256, then compiles the unmodified `steam.c`.
- `steam.c` SHA-256:
  `e96f1a29ebbad5462631c172e282093448b859f1c63094920aa72fd760d0b02e`.
- `Makefile.in` SHA-256:
  `68db082a9be8c943ee5873d6bb4d94af1318c1f108a435b09aa84560276cc2e9`.
- Proton's Wine submodule commit, used only to inspect ABI declarations:
  `b8fdff8e1f855b5276ec4ddca0f31b2792554322`. No Wine header, `winegcc`, Wine source
  or `libwine` is needed in the build. MinGW provides the Windows SDK and import libs.

Toolchain used and checked by the script, for both target triples:

| Input | Version |
|---|---|
| `i686-w64-mingw32-gcc`, `x86_64-w64-mingw32-gcc` | GCC **16.2.0** |
| assembler, linker, objdump | GNU binutils **2.47.20260726** |
| MinGW-w64 Windows SDK / CRT | **14.0.0**, UCRT |
| Local Homebrew package | **14.0.0_3**, POSIX threads |

The complete active Homebrew runtime closure is pinned in
[`toolchain.lock`](toolchain.lock):

| Formula | Active package version |
|---|---|
| gmp | 6.3.0 |
| isl | 0.28 |
| mpfr | 4.2.2 |
| libmpc | 1.4.1 |
| lz4 | 1.10.0 |
| xz | 5.8.4 |
| zstd | 1.5.7_1 |
| mingw-w64 | 14.0.0_3 |

The lock also pins each `arm64_golden_gate` bottle SHA-256, in installation
order. CI uses `scripts/install-steam-shim-toolchain.py` to download and verify
**all eight bottles**, then extract them into a new isolated `Cellar`/`opt` prefix.
It never invokes Homebrew, resolves formulas, builds packages from source, or
writes to `/opt/homebrew`. Existing nonempty destinations are refused.

Downloads require HTTPS on every hop and allow only `ghcr.io` and
`pkg-containers.githubusercontent.com` (the observed GHCR bottle CDN).
Curl configuration is disabled with `-q`; redirects are followed manually only
after host/scheme checks, with a six-request limit and final effective-host
validation. The registry authorization header is not forwarded to the CDN.
Bottle SHA-256 verification remains mandatory before any archive processing.

The complete archive namespace and link graph are validated before writing:
cycles, escapes, duplicate members and non-directory ancestors are rejected.
Graph identities and link-component lookups use Unicode NFD normalization and
case folding, including on case-sensitive hosts. Case/normalization aliases
are rejected for both explicit members and implicit directory prefixes; the
single accepted original spelling is preserved during extraction.
Files are created first, hardlinks only to resolved regular members next, and
symlinks last. Extraction never traverses a symlink ancestor or delegates link
handling to `tar`.

Bottle host-library references are relocated to relative `@loader_path` paths,
and modified Mach-O tools/libraries are ad-hoc signed again. Text specs and
linker scripts have Homebrew placeholders relocated. For target COFF/archive
files, Homebrew's placeholder substitution must be undone to the original build
prefix to restore byte offsets; those paths are debug data, not host tool paths.

The shim-specific GCC wrappers use `-B` and explicit assembler/linker specs to
select the isolated assembler and BFD linker directly. This bypasses GCC's
absolute build-prefix defaults and collect2's hard-coded default linker; `-B`
alone does not override them when a system keg already exists. These wrappers
are for this C shim build, not a general C++/LTO toolchain installation. Both PE
artifacts remain byte-identical to the checked-in hashes. Local verification
also denies **all reads and writes to `/opt/homebrew`** during the offline build,
so successful compilation cannot hide fallback to the owner's toolchain.

The installer records each verified bottle's version/digest and derives the
runtime closure from its host Mach-O library references. With
`STEAM_SHIM_TOOLCHAIN_PREFIX` set, `scripts/check-steam-shim-toolchain.py` compares
that inventory, exact active `opt/` kegs, complete dependency closure and compiler
selection on PATH against the lock, without requiring `brew`. Without that
variable (or `--prefix`), the checker retains its existing Homebrew mode: print
`brew list --versions` and traverse installed runtime receipts without consulting
mutable formula APIs or changing the installed packages. Both modes work offline.
Installer/checker commands and their shebangs use Python isolated mode (`-I`),
so user-site modules, `PYTHONPATH` and environment-supplied startup code cannot
run before verification.

To install the same standalone toolchain locally on arm64 macOS 27:

```sh
export STEAM_SHIM_TOOLCHAIN_PREFIX=/private/tmp/macgacha-shim-toolchain
python3 -I scripts/install-steam-shim-toolchain.py "$STEAM_SHIM_TOOLCHAIN_PREFIX"
export PATH="$STEAM_SHIM_TOOLCHAIN_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
python3 -I scripts/check-steam-shim-toolchain.py
# Then run the build commands below, retaining both exports.
```

Downloads are cached beside the prefix (`PREFIX-bottles`), or at `--cache DIR`.
Every cached bottle is hash-checked again before extraction; a bad cache fails
closed. Nothing in the owner's Homebrew prefix is installed, upgraded or linked.

Run the offline archive/redirect security self-tests with:

```sh
python3 -I scripts/test-steam-shim-toolchain.py
```

The manual workflow uses the explicit `xcode-27` runner label, requires
arm64/macOS 27, and pins both actions by full commit SHA. **GitHub's macOS
`runs-on` API does not accept an immutable VM image SHA.** The label can receive
image updates; it is not described as an immutable environment. The checked-in
[`SHA256SUMS`](SHA256SUMS) is the cross-run reproducibility gate: CI verifies each
build against these expected bytes, in addition to comparing A with B. Toolchain
version logs explain failures; changing an image or dependency cannot silently
bless different output. A digest-addressed macOS VM would require a separately
provisioned runner image, not an invented `runs-on` SHA.

The workflow has only `workflow_dispatch`, read-only repository permissions,
and uploads a workflow artifact, never a release.

## Local adaptation

There is no patch to Valve's source. The build generates `include/wine/debug.h`
with independently written BSD-3 compatibility definitions (copyright 2026
deruta74); its full source is embedded in the script and copied to `audit/compat.h`.

- Wine TRACE/WARN diagnostics are no-ops. Errors still go to stderr; wide strings
  in errors are represented by `<UTF-16>` rather than using Wine's debug helpers.
  This avoids Wine-internal debug imports and an emulated-TLS/pthread dependency.
- Public NT directory-query declarations, `ARRAY_SIZE`, `RTL_CONSTANT_STRING`,
  and Wine's `CP_UNIXCP` value (65010) fill gaps in MinGW's headers.
- `wine_get_dos_file_name` is resolved from Wine's `kernel32.dll` at runtime and
  called using its real ABI. Missing export returns NULL and sets
  `ERROR_PROC_NOT_FOUND`; it does not pretend path conversion succeeded.
- All launcher registry/window/process/restart logic remains upstream. In
  particular, upstream tolerates a missing `lsteamclient` and skips its optional
  registry initializer. Whether this minimal set works for the games remains
  the coordinator's launch check; successful compilation does not prove that.
- No Unix executable, Unix library, Steamworks API implementation, Wine debug
  runtime, or extra MinGW runtime DLL is produced or required. Imports are
  Windows/Wine system DLLs, including UCRT API sets. `libgcc` support is static.

## Rebuild, including an enforced offline phase

Requires Bash, Git, Python 3, shasum and the exact cross toolchain above on PATH.
The default source cache is the ignored `.build/steam-shim/sources`; set
`STEAM_SHIM_CACHE_DIR` for an independent cache. Output must be absent or empty.
Run from the repository root:

```sh
STEAM_SHIM_CACHE_DIR=/tmp/shim-cache-a scripts/build-steam-shim.sh /tmp/shim-out-a --fetch-only
STEAM_SHIM_CACHE_DIR=/tmp/shim-cache-a sandbox-exec -p '(version 1) (allow default) (deny network*)' scripts/build-steam-shim.sh /tmp/shim-out-a --offline --verify
STEAM_SHIM_CACHE_DIR=/tmp/shim-cache-b scripts/build-steam-shim.sh /tmp/shim-out-b --fetch-only
STEAM_SHIM_CACHE_DIR=/tmp/shim-cache-b sandbox-exec -p '(version 1) (allow default) (deny network*)' scripts/build-steam-shim.sh /tmp/shim-out-b --offline --verify
cmp /tmp/shim-out-a/steam32.exe /tmp/shim-out-b/steam32.exe
cmp /tmp/shim-out-a/steam64.exe /tmp/shim-out-b/steam64.exe
diff -u /tmp/shim-out-a/SHA256SUMS /tmp/shim-out-b/SHA256SUMS
(cd /tmp/shim-out-a && shasum -a 256 -c SHA256SUMS)
```

`--verify` checks the active toolchain closure before compiling and fails unless
both PE hashes match the checked-in `compat/steam-shim/SHA256SUMS`. Without it,
a build can be used for investigation but is not a verified shipping artifact.
CI always uses `--verify` and independently checks the pinned manifest again.

Without mode flags, the script fetches and then builds. `--offline`
performs no Git command or network operation and checks the cached source hashes
before compiling. `sandbox-exec` additionally denies network access to the whole
compiler process tree. No Wine binary or game is executed by this task.

Build determinism controls: fixed source blobs and generated header, fixed
compiler/SDK versions, constant source filenames and random seeds, file/debug
prefix maps, no compiler ident strings, stripped PE files, zero PE timestamps,
no linker build ID, UTC/C locale and `SOURCE_DATE_EPOCH=0`. Audit `.d` and `.map`
files retain local toolchain paths for provenance; the byte-identity claim is
for the two PE binaries, not every audit/documentation file.

Each output contains the two launchers, `SHA256SUMS`, this README, NOTICE, and
`audit/`: full dependency lists, linker maps, compiler details, generated
compatibility header, imports/PE header reports, source identity, the toolchain
lock and expected hash manifest. Verified builds also record the full installed
and active formula version inventory.

## Two clean-build results (2026-10-23)

Two independent source caches and fresh build/output directories, with networking
denied during both compilations. The following hashes must match in **both**
`out-a` and `out-b`; a failed comparison invalidates the reproducibility claim:

| Artifact | SHA-256 (build A and build B) |
|---|---|
| `steam32.exe` | `158320bc63bb14e38dd2333608e5ebb8362bdb704e6a4dd67232cfdbaaf0b62b` |
| `steam64.exe` | `08052bb863aae7a01a3030242e0de126d6b0afc6d8d16dcf596fb81a5ae31043` |

**Result: bit-identical PE files on this arm64 macOS 27 host with this toolchain.**
This is not a claim of identical output across other compiler builds or host OSes.
The manual CI job independently repeats and compares its two builds.

Requested local outputs:
`/private/tmp/claude-501/-Users-deruta-Documents-hoyoverselauncher/b6742f2b-7ca5-46b6-bccd-c0ebc83a5700/scratchpad/g0/shim-build/out-a`
and the sibling `out-b`.

These hashes intentionally differ from the yaagl reference shims used in Phase 0.
The Genshin/ZZZ D3DMetal/DXMT launch checks and publication remain separate owner
steps; neither has been performed by this build task.
