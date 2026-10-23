#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1

# No Steamworks SDK or lsteamclient source is fetched or compiled.
proton_tag=proton-10.0-4
proton_commit=e2becb87430ca3ff510d949d9e75fa9b401da489
source_sha=e96f1a29ebbad5462631c172e282093448b859f1c63094920aa72fd760d0b02e
makefile_sha=68db082a9be8c943ee5873d6bb4d94af1318c1f108a435b09aa84560276cc2e9
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
cache=${STEAM_SHIM_CACHE_DIR:-"$repo_root/.build/steam-shim/sources"}
fail() { printf 'steam-shim: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail 'usage: build-steam-shim.sh OUTPUT [--fetch-only|--offline] [--verify]'
output=$1; shift
mode=build
verify=0
for option in "$@"; do
    case "$option" in
        --fetch-only|--offline)
            [[ "$mode" == build ]] || fail 'conflicting build modes'
            mode=$option ;;
        --verify)
            [[ "$verify" == 0 ]] || fail 'duplicate --verify'
            verify=1 ;;
        *) fail "unknown option: $option" ;;
    esac
done
[[ "$mode" != --fetch-only || "$verify" == 0 ]] || fail '--verify requires a build'
for name in git shasum mktemp python3; do command -v "$name" >/dev/null || fail "missing tool: $name"; done

check_sha() {
    local actual
    actual=$(shasum -a 256 "$1"); actual=${actual%% *}
    [[ "$actual" == "$2" ]] || fail "input digest mismatch: $1"
}

if [[ "$mode" != --offline ]]; then
    mkdir -p "$cache"
    if [[ ! -d "$cache/proton/.git" ]]; then
        git init -q "$cache/proton"
        git -C "$cache/proton" remote add origin https://github.com/ValveSoftware/Proton.git
    fi
    # A partial, shallow fetch: no submodules; materialize just the two required blobs.
    git -C "$cache/proton" config remote.origin.promisor true
    git -C "$cache/proton" config remote.origin.partialclonefilter blob:none
    git -C "$cache/proton" fetch --quiet --depth 1 --filter=blob:none origin \
        "refs/tags/$proton_tag:refs/tags/$proton_tag"
    actual=$(git -C "$cache/proton" rev-parse "refs/tags/$proton_tag^{commit}")
    [[ "$actual" == "$proton_commit" ]] || fail 'Proton tag no longer matches pinned commit'
    git -C "$cache/proton" show "$proton_commit:steam_helper/steam.c" > "$cache/steam.c"
    git -C "$cache/proton" show "$proton_commit:steam_helper/Makefile.in" > "$cache/Makefile.in"
fi
check_sha "$cache/steam.c" "$source_sha"
check_sha "$cache/Makefile.in" "$makefile_sha"
[[ "$mode" != --fetch-only ]] || exit 0
# From here on there is no network access, including Git lazy fetches.
export GIT_NO_LAZY_FETCH=1

for target in i686 x86_64; do
    prefix="$target-w64-mingw32"
    for tool in gcc as ld objdump; do command -v "$prefix-$tool" >/dev/null || fail "missing $prefix-$tool"; done
    [[ $("$prefix-gcc" -dumpfullversion) == 16.2.0 ]] || fail "$prefix requires GCC 16.2.0"
    [[ $("$prefix-gcc" -dumpmachine) == "$prefix" ]] || fail 'unexpected compiler target'
    for tool in as ld objdump; do
        version=$("$prefix-$tool" --version)
        [[ "${version%%$'\n'*}" == *'2.47.20260726'* ]] || fail "$prefix requires binutils 2.47.20260726"
    done
    macros=$(printf '#include <_mingw.h>\n' | "$prefix-gcc" -dM -E -x c -)
    for pair in '__MINGW64_VERSION_MAJOR 14' '__MINGW64_VERSION_MINOR 0' '__MINGW64_VERSION_BUGFIX 0'; do
        grep -Fx "#define $pair" <<< "$macros" >/dev/null || fail "$prefix requires mingw-w64 headers 14.0.0"
    done
    [[ "$macros" == *'#define _UCRT '* ]] || fail "$prefix requires the UCRT toolchain"
done

if [[ -e "$output" ]]; then
    [[ -d "$output" && -z $(ls -A "$output") ]] || fail 'output must be absent or empty'
fi
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/macgacha-steam-shim.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/include/wine" "$output/audit"
if [[ "$verify" == 1 ]]; then
    python3 "$repo_root/scripts/check-steam-shim-toolchain.py" | tee "$output/audit/toolchain-versions.txt"
fi
cp "$cache/steam.c" "$work/steam.c"
# This generated compatibility header is independently licensed BSD-3-Clause;
# the GPL license of this build script does not license the produced executables.
cat > "$work/include/wine/debug.h" <<'COMPAT'
/* SPDX-License-Identifier: BSD-3-Clause */
/* Independent MinGW adaptation; Copyright (c) 2026 deruta74. */
#ifndef MACGACHA_STEAM_COMPAT_H
#define MACGACHA_STEAM_COMPAT_H
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#define CP_UNIXCP 65010
#define RTL_CONSTANT_STRING(s) { sizeof(s) - sizeof((s)[0]), sizeof(s), (PWSTR)(s) }
#define debugstr_w wine_dbgstr_w
#define wine_dbgstr_a(s) ((s) ? (s) : "(null)")
#define debugstr_a(s) ((s) ? (s) : "(null)")
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define WINE_DEFAULT_DEBUG_CHANNEL(name)
#define WINE_TRACE(...) do { } while (0)
#define WINE_WARN(...) do { } while (0)
#define TRACE WINE_TRACE
#define WARN WINE_WARN
#define WINE_ERR(...) do { fprintf(stderr, "steam: " __VA_ARGS__); } while (0)
#define ERR WINE_ERR
static const char *wine_dbgstr_w(const WCHAR *text)
{
    return text ? "<UTF-16>" : "(null)";
}
typedef struct { UNICODE_STRING ObjectName; UNICODE_STRING ObjectTypeName; } DIRECTORY_BASIC_INFORMATION;
NTSYSAPI NTSTATUS NTAPI NtOpenDirectoryObject(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES);
NTSYSAPI NTSTATUS NTAPI NtQueryDirectoryObject(HANDLE, void *, ULONG, BOOLEAN, BOOLEAN, ULONG *, ULONG *);
static WCHAR *wine_get_dos_file_name(const char *path)
{
    typedef WCHAR *(CDECL *convert_fn)(const char *);
    convert_fn convert = (convert_fn)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "wine_get_dos_file_name");
    if (!convert) { SetLastError(ERROR_PROC_NOT_FOUND); return NULL; }
    return convert(path);
}
#endif
COMPAT

for bits in 32 64; do
    if [[ "$bits" == 32 ]]; then target=i686; else target=x86_64; fi
    prefix="$target-w64-mingw32"
    (
        cd "$work"
        "$prefix-gcc" -O2 -Werror -mwindows -fno-ident -frandom-seed="steam-$bits" \
            -ffile-prefix-map="$work"=. -fdebug-prefix-map="$work"=. \
            -Iinclude -MD -MF "deps$bits.d" -c steam.c -o "steam$bits.o"
        "$prefix-gcc" -mwindows -static-libgcc -s "steam$bits.o" -o "$output/steam$bits.exe" \
            -Wl,--no-insert-timestamp,--build-id=none,-Map,"$work/link$bits.map" \
            -luser32 -ladvapi32 -lshlwapi -lshell32 -lmsi -lole32 -lntdll
    )
    "$prefix-objdump" -p "$output/steam$bits.exe" > "$output/audit/pe$bits.txt"
    # Only OS/Wine-provided DLLs may be imported. No winpthread/libgcc/lsteamclient dependency.
    if grep -Ei 'DLL Name:.*(libgcc|winpthread|lsteamclient)' "$output/audit/pe$bits.txt"; then
        fail 'unexpected non-system DLL import'
    fi
    cp "$work/deps$bits.d" "$work/link$bits.map" "$output/audit/"
    "$prefix-gcc" -v > "$output/audit/compiler$bits.txt" 2>&1
done
cp "$work/include/wine/debug.h" "$output/audit/compat.h"
cp "$repo_root/compat/steam-shim/toolchain.lock" "$output/audit/toolchain.lock"
cp "$repo_root/compat/steam-shim/SHA256SUMS" "$output/audit/expected-SHA256SUMS"
cp "$repo_root/compat/steam-shim/NOTICE.md" "$repo_root/compat/steam-shim/README.md" "$output/"
(
    cd "$output"
    shasum -a 256 steam32.exe steam64.exe > SHA256SUMS
    if [[ "$verify" == 1 ]]; then
        shasum -a 256 -c "$repo_root/compat/steam-shim/SHA256SUMS"
    fi
)
printf 'Proton %s %s\n' "$proton_tag" "$proton_commit" > "$output/audit/source.txt"
printf 'Built PE32 + PE32+ launchers (no lsteamclient); %s\n' "$output"
cat "$output/SHA256SUMS"
