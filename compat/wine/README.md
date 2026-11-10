# Full MacGacha Wine candidate

The standalone candidate builds Wine 11.20 from the pinned fork with the
opt-in Dock icon patch from PR #126. This branch depends on that patch.
It includes x86_64 Unix modules, i386/x86_64 Windows modules and an arm64
wineserver. TLS, fonts, SDL and media support are mandatory. Apple graphics
are not packaged. The launcher wrapper uses the real
`$wrapper_dir/wine.real` command recognized by GameModeHelper.

## Rebuild

Use Apple Silicon with Rosetta, the locked Apple Clang/SDK from
`inputs.lock.json` and Bison 3.8.2. The manual workflow installs Bison using
`compat/crypt32-fix/toolchain.lock`; no Homebrew fallback occurs in the build.
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
