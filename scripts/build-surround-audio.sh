#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1

repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
inputs="$repo_root/compat/surround-audio"
cache=${SURROUND_AUDIO_CACHE_DIR:-"$repo_root/.build/surround-audio/sources"}
archive="$cache/wine-11.20.tar.xz"
source_url=https://dl.winehq.org/wine/source/11.x/wine-11.20.tar.xz
source_sha=eac8ca448f9c0087f963026b4dc276d1e2b7fbb64056edc093e59bbb7e56fe28
fail() { printf 'surround-audio: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail 'usage: build-surround-audio.sh OUTPUT [--fetch-only|--offline] [--verify]'
output=$1; shift
mode=build; verify=0
for option in "$@"; do
    case "$option" in
        --fetch-only|--offline) [[ "$mode" == build ]] || fail 'conflicting modes'; mode=$option ;;
        --verify) [[ "$verify" == 0 ]] || fail 'duplicate --verify'; verify=1 ;;
        *) fail "unknown option: $option" ;;
    esac
done
[[ "$mode" != --fetch-only || "$verify" == 0 ]] || fail '--verify requires build'
if [[ "$mode" != --offline ]]; then
    mkdir -p "$cache"
    if [[ ! -f "$archive" ]]; then
        curl -q --fail --location --proto '=https' --proto-redir '=https' "$source_url" -o "$archive"
    fi
fi
[[ -f "$archive" ]] || fail 'missing cached Wine source (offline mode never downloads)'
actual=$(shasum -a 256 "$archive"); actual=${actual%% *}
[[ "$actual" == "$source_sha" ]] || fail 'Wine source digest mismatch'
(cd "$inputs" && shasum -a 256 -c PATCHSUMS)
[[ "$mode" != --fetch-only ]] || exit 0
[[ $(uname -s) == Darwin && $(uname -m) == arm64 && $(uname -r) == 27.* ]] || fail 'requires arm64 macOS 27'
for tool in python3 x86_64-w64-mingw32-gcc x86_64-w64-mingw32-as x86_64-w64-mingw32-ld \
            x86_64-w64-mingw32-strip x86_64-w64-mingw32-objdump make; do
    command -v "$tool" >/dev/null || fail "missing local tool: $tool"
done
[[ $(x86_64-w64-mingw32-gcc -dumpfullversion) == 16.2.0 ]] || fail 'requires locked GCC 16.2.0'
[[ $(x86_64-w64-mingw32-gcc -dumpmachine) == x86_64-w64-mingw32 ]] || fail 'unexpected PE compiler target'
for tool in as ld strip objdump; do
    version=$("x86_64-w64-mingw32-$tool" --version)
    [[ "${version%%$'\n'*}" == *2.47.20260726* ]] || fail 'requires locked binutils 2.47.20260726'
done
[[ $(/usr/bin/clang --version | head -1) == 'Apple clang version 21.0.0 (clang-2100.3.34.2)' ]] || fail 'host clang changed'
[[ $(xcrun --show-sdk-version) == 27.0 ]] || fail 'host SDK changed'
python3 -I "$repo_root/scripts/check-steam-shim-toolchain.py" --lock "$repo_root/compat/crypt32-fix/toolchain.lock"
toolchain_prefix=${STEAM_SHIM_TOOLCHAIN_PREFIX:-$(brew --prefix)}
export BISON="$toolchain_prefix/opt/bison/bin/bison"
export BISON_PKGDATADIR="$toolchain_prefix/opt/bison/share/bison" M4=/usr/bin/m4
[[ -x "$BISON" ]] || fail 'locked Bison is not installed locally'
[[ $("$BISON" --version | head -1) == 'bison (GNU Bison) 3.8.2' ]] || fail 'requires locked Bison 3.8.2'
# Configure's x86_64 probes and Wine's host build tools need existing Rosetta.
# This is a receipt query, not a Wine/Rosetta installation or execution probe.
/usr/sbin/pkgutil --pkg-info com.apple.pkg.RosettaUpdateAuto >/dev/null 2>&1 || fail 'requires already installed Rosetta for x86_64 host build tools'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'output must be absent'
mkdir -p "$output/audit" "$output/x86_64-unix"
output=$(cd "$output" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/macgacha-surround.XXXXXXXX")
trap 'status=$?; if [[ -f "$work/build/config.log" ]]; then cp "$work/build/config.log" "$output/audit/config.log"; fi; rm -rf "$work"; exit "$status"' EXIT
mkdir -p "$work/build"
tar -xf "$archive" -C "$work"
/usr/bin/patch --batch --fuzz=0 -d "$work/wine-11.20" -p1 < "$inputs/winecoreaudio-surround.patch" > "$output/audit/patch.log"
(
    cd "$work/build"
    # crypt32 is PE-only: its native arm64 host compiler is NOT suitable here.
    # The pinned D3DMetal fixture loads x86_64-unix/winecoreaudio.so via Rosetta.
    export CC='/usr/bin/clang -arch x86_64'
    export MACOSX_DEPLOYMENT_TARGET=26.0 MSGFMT=false
    # SDK 27 exposes pipe2 even when targeting 26; keep Wine's portable fallback.
    export ac_cv_func_pipe2=no
    export CFLAGS="-O2 -mmacosx-version-min=26.0 -ffile-prefix-map=$work=. -fdebug-prefix-map=$work=."
    # Rosetta requires LC_UUID even for configure/build-tool executables.
    # Apple's default content-derived UUID is retained, then checked by rebuild.
    export LDFLAGS='-arch x86_64 -mmacosx-version-min=26.0'
    export CROSSCFLAGS="-O2 -fno-ident -frandom-seed=surround-audio-1 -ffile-prefix-map=$work=. -fdebug-prefix-map=$work=."
    export CROSSLDFLAGS='-Wl,--no-insert-timestamp,--build-id=none'
    ../wine-11.20/configure --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
        --enable-archs=x86_64 --disable-build-id --disable-tests --with-coreaudio \
        --without-x --without-freetype --without-gnutls --without-vulkan --without-opencl \
        --without-sdl --without-gstreamer --without-cups --without-sane --without-usb \
        --without-v4l2 --without-pcap --without-krb5 --without-gphoto --without-netapi \
        --without-capi --without-inotify --without-dbus --without-pulse --without-alsa \
        --without-oss > "$output/audit/configure.log" 2>&1
    make -j"${SURROUND_JOBS:-4}" __tooldeps__ > "$output/audit/tools.log" 2>&1
    make -j"${SURROUND_JOBS:-4}" dlls/winecoreaudio.drv/winecoreaudio.so > "$output/audit/build.log" 2>&1
)

module="$work/build/dlls/winecoreaudio.drv/winecoreaudio.so"
[[ -f "$module" ]] || module="$work/build/dlls/winecoreaudio.drv/x86_64-unix/winecoreaudio.so"
[[ -f "$module" ]] || fail "CoreAudio Unix module not produced; inspect $output/audit"
target="$output/x86_64-unix/winecoreaudio.so"
cp "$module" "$target"
[[ $(/usr/bin/lipo -archs "$target") == x86_64 ]] || fail 'wrong Unix module architecture'
/usr/bin/strip -S "$target"
/usr/bin/codesign --force --sign - --timestamp=none "$target"
/usr/bin/codesign --verify --strict "$target"
/usr/bin/file "$target" > "$output/audit/module.txt"
/usr/bin/otool -L "$target" > "$output/audit/dependencies.txt"
if /usr/bin/grep -E '/opt/homebrew/|/usr/local/|macgacha-surround\.' "$output/audit/dependencies.txt"; then
    fail 'non-system/build-path dependency in module'
fi
cp "$work/wine-11.20/COPYING.LIB" "$output/COPYING.LIB"
cp "$inputs/NOTICE.md" "$output/NOTICE.md"
mkdir -p "$output/build-inputs/compat/surround-audio" "$output/build-inputs/compat/crypt32-fix" "$output/build-inputs/compat/steam-shim" "$output/build-inputs/scripts"
cp "$inputs/winecoreaudio-surround.patch" "$inputs/PATCHSUMS" "$inputs/README.md" "$inputs/NOTICE.md" "$inputs/test-spatial.c" "$inputs/load-probe.c" "$output/build-inputs/compat/surround-audio/"
cp "$repo_root/compat/crypt32-fix/toolchain.lock" "$output/build-inputs/compat/crypt32-fix/"
cp "$repo_root/compat/steam-shim/toolchain.lock" "$output/build-inputs/compat/steam-shim/"
for script in build-surround-audio.sh check-surround-audio.py install-steam-shim-toolchain.py check-steam-shim-toolchain.py; do
    cp "$repo_root/scripts/$script" "$output/build-inputs/scripts/"
done
cp "$repo_root/LICENSE" "$repo_root/NOTICE" "$output/build-inputs/"
/usr/bin/clang -arch arm64 -Werror -Wall -Wextra -Wno-unused-parameter -Wno-multichar \
    -I"$work/wine-11.20/dlls/winecoreaudio.drv" "$inputs/test-spatial.c" -o "$output/audit/test-spatial"
"$output/audit/test-spatial" > "$output/audit/native.log" 2>&1
(cd "$output" && shasum -a 256 x86_64-unix/winecoreaudio.so > SHA256SUMS)
python3 -I - "$output" <<'ZIP'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / 'surround-audio-wine-11.20-1.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if not path.is_file() or relative.parts[0] == 'audit' or path.suffix == '.zip':
            continue
        info = zipfile.ZipInfo(relative.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
ZIP
python3 -I "$repo_root/scripts/check-surround-audio.py" "$output"
if [[ "$verify" == 1 ]]; then
    (cd "$output" && shasum -a 256 -c "$inputs/SHA256SUMS")
fi
shasum -a 256 "$output/surround-audio-wine-11.20-1.zip"
