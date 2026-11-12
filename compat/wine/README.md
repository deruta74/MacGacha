# Full MacGacha Wine candidate

## Source-built preview4

The source-only path uses `source-build.lock.json` (dependency/tool sources)
and `source-runtime.lock.json` (Wine/toolchain inputs). It does not fetch or
read the preview3 donor or prebuilt header SDKs. Core libraries and a selected
GStreamer/FFmpeg decoder stack are built in a private staging root. See
`SOURCE-NOTICE.md` for deliberate feature differences requiring qualification.

```sh
python3 -I scripts/build-wine-dependencies.py /tmp/deps-a --cache /tmp/deps-cache --fetch-only
python3 -I scripts/build-wine-dependencies.py /tmp/deps-a --cache /tmp/deps-cache --offline
python3 -I scripts/build-wine.py /tmp/wine-source-a --dependencies /tmp/deps-a --cache /tmp/wine-inputs --fetch-only
python3 -I scripts/build-wine.py /tmp/wine-source-a --dependencies /tmp/deps-a --cache /tmp/wine-inputs --offline --bison /tmp/deps-a/tools/bin/bison
python3 -I scripts/finalize-source-wine.py /tmp/wine-source-a /tmp/wine-final-a
python3 -I scripts/check-wine.py /tmp/wine-final-a /tmp/wine-source-probe --deny-read /tmp/deps-a
```

Both output roots must be absent. Bison, Ninja, Meson and pkgconf are built
from source; compiler/SDK versions remain locked. No `/opt/macgacha` system
installation is performed: fixed configure prefixes use DESTDIR. New private
libraries use rpath identities for later configure probes. Receipt checks
bind every staged file to a package and retain original source archives,
commands, build scripts and license texts. Wine verifies this receipt and
the retained source hashes before copying the SDK into its own private root.

Finalization verifies the base archive/receipt and matching build helper,
copies into a fresh root, removes native debug tables (`strip -S`) and repeats
deterministic UUID/signature normalization. This removes Nettle's N_SO/N_OSO
object paths without losing exported symbols. It only accepts source-built
candidates and refuses shared inodes; original builds are retained. The final
receipt records the original archive hash and packaging script. Its local-only
`work` link supports diagnostic compilation and is excluded from packages.

The manual workflow now builds two independent source SDK/Wine pairs without
network/Homebrew access and compares the preview4 archives. It uploads build
evidence only. The probe additionally requires system TLS trust anchors and
actual decoding of the synthetic two-frame H.264/MP4 fixture. These checks
do not establish long-session gameplay, every codec or source-license review.

## Retained preview3 donor path

The standalone candidate builds Wine 11.20 from the pinned fork with the
opt-in Dock icon patch from PR #126. This branch depends on that patch.
It includes x86_64 Unix modules, i386/x86_64 Windows modules and an arm64
wineserver. TLS, fonts, SDL and media support are mandatory. Apple graphics
are not packaged. The launcher wrapper uses the real
`$wrapper_dir/wine.real` command recognized by GameModeHelper.

## Rebuild

Use Apple Silicon with Rosetta, the locked Apple Clang/SDK from
`inputs.lock.json` and Bison 3.8.2. For this retained path the isolated
toolchain can be installed using `compat/crypt32-fix/toolchain.lock`;
the current manual workflow uses the source-built path above instead.
Python 3.9 or later is sufficient. Keep scratch/output outside Documents,
with no whitespace in its path. The output must not exist.

```sh
python3 -I scripts/test-wine-build.py
python3 -I scripts/build-wine.py /tmp/wine-a --cache /tmp/wine-inputs --fetch-only
python3 -I scripts/build-wine.py /tmp/wine-a --cache /tmp/wine-inputs --offline
```

After building, run `python3 -I scripts/check-wine.py /tmp/wine-a /tmp/wine-probe`
to verify the unpacked archive, native libraries, Windows command and fonts
with build inputs and installed runtimes denied. Probe output must be absent.

Use `--bison /absolute/path/to/bison` for the isolated locked toolchain.
`WINE_JOBS` controls parallelism (default 8). Downloads are a separate step;
offline mode refuses missing or changed inputs rather than fetching them.
The workflow additionally denies network access during builds.

Inputs pin source archives, LLVM MinGW, pkgconf, MacPorts development
headers, GStreamer development metadata and a dependency donor archive.
Only the donor's open-source dylibs/GStreamer payload is selected. The
builder never reads installed MacGacha runtimes. The donor libraries are
**reused prebuilt dependencies**, not fresh builds from their source.
See NOTICE.md for the remaining dependency-source distribution requirement.

## Dependency source preparation

`dependency-sources.lock.json` pins Cerbero 1.28.7 build recipes (including
their patches) and a **partial** set of source archives: GStreamer, FFmpeg
and the framework's zlib. Their hashes come from those pinned recipes.
These sources do not establish the donor's exact build configuration or
cover the root-level dependency libraries. See [DEPENDENCIES.md](DEPENDENCIES.md).

```sh
python3 -I scripts/test-wine-dependencies.py
python3 -I scripts/audit-wine-dependencies.py /path/to/candidate /tmp/dependency-audit.json --cache /tmp/wine-source-cache --fetch
```

Omit `--fetch` for an offline audit. The output must not exist. The audit
checks the entire unpacked runtime against its receipt, verifies cached
source hashes, and records every root library and framework entry plus
the framework's versions/license metadata. It never executes donor code,
changes the runtime or certifies complete corresponding-source delivery.
This audit is for legacy donor candidates; it is not needed for the
source-built SDK's package/file/source receipts.

Output contains `wine/`, a normalized tar.xz, SHA256SUMS, a complete file/
symlink receipt, build logs, relocations and corresponding Wine/build inputs.
`work/` remains for diagnosis and is not a distributable. The upstream
builder records a local snapshot commit; `inputs.lock.json.upstreamCommit`
is the actual upstream identity. Build-driver changes only add deterministic
compiler flags, disable build IDs, use relative source paths and install
a fixed prefix through DESTDIR; the Wine source change is the Dock patch.

## Qualification and publication

COFF object timestamps are disabled with `-mno-incremental-linker-compatible`;
relative configure paths keep WIDL headers and MSVC anonymous namespaces stable.
Fresh MacGacha-built Mach-O files receive content-derived UUIDv8 values and
deterministic ad-hoc signatures after relocation. macOS 27 requires LC_UUID;
removing it is not supported. No dSYM package is shipped. Existing dependency
binaries retain their upstream UUIDs and bytes unless relocation is required.

Build into two independent roots and compare their tar.xz bytes. The manual
workflow enforces this comparison and uploads build evidence (public in this
public repository). It does not upload candidate binaries/source bundles, create
releases or change the runtime catalog. Binary distribution remains gated on
complete dependency-source delivery. Normalized packaging alone
does not prove compiler-level reproducibility: compare complete builds.

Before publication, qualify the exact packaged binary with isolated prefix,
font/TLS/media probes and actual DXMT/D3DMetal compositions. Prior local
preview tests reached Genshin/ZZZ Global title/login screens on both graphics
backends and confirmed Game Mode. They do not qualify this fresh build or
long-session gameplay, CN, Star Rail, audio quality, catalog updates or rollback.
The current catalog/defaults are unchanged. Keep crypt32 and Surround as
separate ABI-scoped overlays until separately qualified.

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
and always sets `latest=false`. Publication remains the owner's step.
No release has been created or published by this integration task.
