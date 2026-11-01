<!-- SPDX-License-Identifier: GPL-3.0-only -->
<!-- MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). -->
# Genshin FPS helper component

Method from genshin-fps-unlock by 34736384, MIT:
<https://github.com/34736384/genshin-fps-unlock/tree/v3.5.0>.
This is independently written GPL-3.0-only code. No upstream source is copied.

This component packages the proven FPS-only spike. It does not integrate into
launch recipes or enable an FPS setting. Installing it does not start anything.
The owner reported 120 FPS for 3 h 35 min online on 2026-11-01 without a kick or
crash. That observation is not a promise about future game builds or sanctions.
The upstream README's FPS-only ban claim is not a guarantee from MacGacha.

## Scope and protocol

`fpsinject.exe` accepts `--target 61..360` and optional
`--deadline-seconds 1..600` (default 120). It requires exactly one
`GenshinImpact.exe` or `YuanShen.exe` and its visible `UnityWndClass` window.
It loads the adjacent DLL by absolute path, installs `MacGachaFpsHook` with
`WH_GETMESSAGE` on that window thread and posts `WM_NULL` while waiting for Ready.
The hook only calls `CallNextHookEx`.

The DLL does nothing in other hosts. In the game it pins itself and creates one
worker outside the loader lock. The worker opens
`Local\MacGachaFpsUnlock-<game pid>` using the version-1, 64-byte record in
`fpsshared.h`. It scans the main image's executable `il2cpp` section with
signature `unlocker35-il2cpp-e9-v2`: `B9 3C 00 00 00 E8 rel32`, initial `E9`,
up to eight cycle-checked E8/E9 thunks, then `89 0D disp32 C3`.
The first qualifying caller supplies the slot. Different qualifying slots,
unreadable scan bytes and an initial value outside 30–60 refuse all writes.
Bounds are 96 sections, 2 GiB per image and 256 distinct slots.

The slot must be four-byte aligned, inside writable non-executable main-image
data, committed `MEM_IMAGE`, and `PAGE_READWRITE` or `PAGE_WRITECOPY` without a
guard page. Every 62 ms the worker rechecks protection and uses a plain volatile
32-bit store at that one slot when its value differs from the target. It records
the last observed value, resets and heartbeat. The initial write counts as a
reset. Target zero disables writes and Stop ends the worker.

There are no remote memory writes, protection changes in the game, code patches,
mobile-UI patches, power-save patches, disassembler dependencies or other game
hooks. The stub enters `DllMain` directly, avoiding MinGW CRT pseudo-relocation
startup. The injector retains normal console CRT startup in its own process.

Game exit or Ctrl-C/console close stops the injector. Cleanup sets target zero
and Stop, then unhooks. Restart the game before another attempt after Stop or
Error because the DLL remains pinned. Forcibly killing the injector cannot
publish Stop and may leave writes active until game exit.

## Output and exit codes

Each output line starts with UTC `YYYY-MM-DDTHH:MM:SS.mmmZ`. Fields are path-free:

```text
mode=in-process target=120 deadline-seconds=120 signature=unlocker35-il2cpp-e9-v2
status=waiting pid=<decimal> thread=<decimal>
status=<1|2> error=<decimal> slot-rva=0x<hex> caller-rva=0x<hex> qualifying=<n> distinct-slots=<n> initial=<fps>
status=holding observed=<fps> resets=<n> heartbeat=<n>
status=stalled heartbeat=<n>
exit=<code> reason=<fixed-token>
```

Holding reports once per second. A stalled line reports a heartbeat unchanged
for more than five seconds. RVAs are relative to the main image.
Statuses: 0 None, 1 Ready, 2 Error, 3 Stop. Shared errors: 1 invalid image,
2 scan/no match/bounds failure, 3 different slots, 4 invalid slot/protection,
5 invalid target, 12 bad initial value.

| Exit | Meaning |
|---|---|
| 0 | Game exit or handled cancellation |
| 10 | No game |
| 11 | Ambiguous games, injection/pattern/deadline failure or stub Error |
| 12 | Initial value outside 30–60, before any write |
| 13 | Invalid CLI or other setup failure |

## Reproduce without Wine

Use the exact Steam shim MinGW bottle closure in
`compat/steam-shim/toolchain.lock` (GCC 16.2.0, binutils 2.47.20260726,
mingw-w64 14.0.0/UCRT). The installer can provision an isolated prefix, then
the build and check are offline:

```sh
python3 -I scripts/install-steam-shim-toolchain.py /absolute/new/toolchain
export STEAM_SHIM_TOOLCHAIN_PREFIX=/absolute/new/toolchain
export PATH="$STEAM_SHIM_TOOLCHAIN_PREFIX/bin:$PATH"
bash scripts/build-genshin-fps.sh /absolute/new/output --verify
python3 -I scripts/check-genshin-fps.py /absolute/new/output
python3 -I scripts/check-genshin-fps.py --self-check
```

The build validates the lock even without `--verify`. It uses C11, O2, warnings
as errors, static libgcc, stripped symbols, fixed image bases/random seeds/path
maps, no build IDs and zero PE timestamps. No executable is run. ZIP entries are
sorted, stored without compression (independent of host zlib), dated 1980-01-01
and carry fixed regular-file permissions. Audits stay outside the ZIP.

`genshin-fps-unlock-1.zip` contains `x86_64-windows/fpsstub.dll` and
`x86_64-windows/fpsinject.exe`, documentation, GPL license/notice and the exact
source/build inputs. The manifest selects `x86_64-windows` as the installed root,
keeping the DLL next to the injector. `SHA256SUMS` pins the whole ZIP.
Build it twice in independent output/work directories and compare the ZIPs.
The offline checker needs only Python's standard library. Its synthetic tests
require no toolchain and run in `scripts/test.sh` even when MinGW is absent.

The manual workflow builds twice, verifies the pin and manifest, and attaches
the ZIP to a draft release. It refuses published releases. Only the owner
publishes releases. Do not run the helper or Wine as part of build verification.
