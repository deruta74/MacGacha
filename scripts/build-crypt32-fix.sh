#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
inputs="$repo_root/compat/crypt32-fix"
cache=${CRYPT32_FIX_CACHE_DIR:-"$repo_root/.build/crypt32-fix/sources"}
source_url=https://dl.winehq.org/wine/source/11.x/wine-11.20.tar.xz
source_sha=eac8ca448f9c0087f963026b4dc276d1e2b7fbb64056edc093e59bbb7e56fe28
fail() { printf 'crypt32-fix: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail 'usage: build-crypt32-fix.sh OUTPUT [--fetch-only|--offline] [--verify]'
output=$1; shift
mode=build; verify=0
for option in "$@"; do
    case "$option" in
        --fetch-only|--offline) [[ "$mode" == build ]] || fail 'conflicting modes'; mode=$option ;;
        --verify) [[ "$verify" == 0 ]] || fail 'duplicate --verify'; verify=1 ;;
        *) fail "unknown option: $option" ;;
    esac
done
[[ "$mode" != --fetch-only || "$verify" == 0 ]] || fail '--verify requires a build'
check_sha() {
    local actual
    actual=$(shasum -a 256 "$1"); actual=${actual%% *}
    [[ "$actual" == "$2" ]] || fail "input digest mismatch: $1"
}
if [[ "$mode" != --offline ]]; then
    mkdir -p "$cache"
    if [[ ! -f "$cache/wine-11.20.tar.xz" ]]; then
        curl -q --fail --location --proto '=https' --proto-redir '=https' "$source_url" -o "$cache/wine-11.20.tar.xz"
    fi
fi
check_sha "$cache/wine-11.20.tar.xz" "$source_sha"
check_sha "$inputs/patches/0001-preserve-authenticated-attribute-order.patch" 56dd6533c255bcd784b4a53d7017abd3190abf86a672c718b54585e352d3d539
check_sha "$inputs/patches/0002-test-authenticated-attribute-order.patch" 3a5f8dfbdef3c7fbbb772e6194e2c00e03d292239cbbd3edeb2b413750ad10eb
check_sha "$inputs/patches/0003-native-prefix-unixlib.patch" 9e7a6e7cbf590a722184a8547954360c59b190486a2fc9bb6722fbb5a011e55a
patches=("$inputs"/patches/*.patch)
[[ ${#patches[@]} == 3 ]] || fail 'unexpected patch set'
[[ "$mode" != --fetch-only ]] || exit 0
[[ $(uname -s) == Darwin && $(uname -m) == arm64 && $(uname -r) == 27.* ]] || fail 'requires arm64 macOS 27'
[[ $(x86_64-w64-mingw32-gcc -dumpfullversion) == 16.2.0 ]] || fail 'requires locked GCC 16.2.0'
[[ $(x86_64-w64-mingw32-gcc -dumpmachine) == x86_64-w64-mingw32 ]] || fail 'unexpected target'
for tool in as ld strip objdump; do
    version=$("x86_64-w64-mingw32-$tool" --version)
    [[ "${version%%$'\n'*}" == *2.47.20260726* ]] || fail 'requires locked binutils 2.47.20260726'
done
[[ $(/usr/bin/clang --version | head -1) == 'Apple clang version 21.0.0 (clang-2100.3.34.2)' ]] || fail 'host clang changed'
[[ $(xcrun --show-sdk-version) == 27.0 ]] || fail 'host SDK changed'
[[ ! -e "$output" || ( -d "$output" && -z $(ls -A "$output") ) ]] || fail 'output must be absent or empty'
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/macgacha-crypt32.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/build" "$output/x86_64-windows" "$output/audit"
# The same locked MinGW/CRT closure and isolated installer as the Steam shim.
python3 -I "$repo_root/scripts/check-steam-shim-toolchain.py" --lock "$inputs/toolchain.lock" > "$output/audit/toolchain.txt"
toolchain_prefix=${STEAM_SHIM_TOOLCHAIN_PREFIX:-$(brew --prefix)}
export BISON="$toolchain_prefix/opt/bison/bin/bison"
export BISON_PKGDATADIR="$toolchain_prefix/opt/bison/share/bison" M4=/usr/bin/m4
[[ $("$BISON" --version | head -1) == 'bison (GNU Bison) 3.8.2' ]] || fail 'requires locked Bison 3.8.2'
tar -xf "$cache/wine-11.20.tar.xz" -C "$work"
for patch in "$inputs"/patches/*.patch; do
    /usr/bin/patch --batch --fuzz=0 -d "$work/wine-11.20" -p1 < "$patch"
done
(
    cd "$work/build"
    export CC=/usr/bin/clang
    # Do not let an optional, unpinned Homebrew gettext installation change resources.
    export MSGFMT=false
    export CROSSCFLAGS="-O2 -fno-ident -frandom-seed=crypt32-fix -ffile-prefix-map=$work=. -fdebug-prefix-map=$work=."
    export CROSSLDFLAGS='-Wl,--no-insert-timestamp,--build-id=none'
    ../wine-11.20/configure --enable-archs=x86_64 --disable-build-id --disable-tests \
        --without-x --without-freetype --without-gnutls --without-vulkan --without-opencl \
        --without-sdl --without-gstreamer --without-cups --without-sane --without-usb \
        --without-v4l2 --without-pcap --without-krb5 --without-gphoto --without-netapi \
        --without-capi --without-inotify --without-dbus --without-pulse --without-alsa \
        --without-oss --without-coreaudio > "$output/audit/configure.log" 2>&1
    make -j"${CRYPT32_FIX_JOBS:-4}" __tooldeps__ > "$output/audit/tools.log" 2>&1
    make -j"${CRYPT32_FIX_JOBS:-4}" dlls/crypt32/x86_64-windows/crypt32.dll > "$output/audit/build.log" 2>&1
)
cp "$work/build/dlls/crypt32/x86_64-windows/crypt32.dll" "$output/x86_64-windows/crypt32.dll"
x86_64-w64-mingw32-strip --strip-debug "$output/x86_64-windows/crypt32.dll"
# loader.c:load_builtin() ignores native-first for a Wine builtin signature.
# Remove only winebuild's 32-byte DOS-stub marker, not executable code or PE headers.
python3 -I - "$output/x86_64-windows/crypt32.dll" <<'PY'
import pathlib, struct, sys
path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
assert data[:2] == b'MZ' and struct.unpack_from('<I', data, 60)[0] >= 96
assert data[64:96] == b'Wine builtin DLL' + bytes(16)
data[64:96] = bytes(32)
path.write_bytes(data)
PY
# An executable regression probe, kept outside the distributable DLL archive.
python3 -I - "$work/wine-11.20/dlls/crypt32/tests/msg.c" "$output/audit/signature-fixture.h" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'static const BYTE msgWithUnsortedAuthAttrs\[\] = \{.*?\n\};', source, re.S)
assert match is not None
pathlib.Path(sys.argv[2]).write_text(match.group(0) + '\n')
PY
x86_64-w64-mingw32-gcc -O2 -fno-ident -static-libgcc -I"$output/audit" \
    "$inputs/regression-probe.c" -o "$output/audit/crypt32-probe.exe" -lcrypt32 \
    -Wl,--no-insert-timestamp,--build-id=none
x86_64-w64-mingw32-objdump -p "$output/x86_64-windows/crypt32.dll" > "$output/audit/pe.txt"
if grep -Ei 'DLL Name:.*(libgcc|winpthread)' "$output/audit/pe.txt"; then fail 'unexpected runtime DLL import'; fi
cp "$inputs/README.md" "$inputs/NOTICE.md" "$output/"
cp "$work/wine-11.20/COPYING.LIB" "$output/"
mkdir -p "$output/build-inputs/compat/crypt32-fix" "$output/build-inputs/compat/steam-shim" "$output/build-inputs/scripts"
cp -R "$inputs/" "$output/build-inputs/compat/crypt32-fix/"
cp "$repo_root/compat/steam-shim/toolchain.lock" "$output/build-inputs/compat/steam-shim/"
for script in build-crypt32-fix.sh install-steam-shim-toolchain.py check-steam-shim-toolchain.py; do
    cp "$repo_root/scripts/$script" "$output/build-inputs/scripts/"
done
cp "$repo_root/LICENSE" "$repo_root/NOTICE" "$output/build-inputs/"
(
    cd "$output"
    shasum -a 256 x86_64-windows/crypt32.dll > SHA256SUMS
    if [[ "$verify" == 1 ]]; then shasum -a 256 -c "$inputs/SHA256SUMS"; fi
)
# Archive only stable deliverables. Absolute-path configure/build audit logs stay local.
python3 -I - "$output" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / 'crypt32-fix-wine-11.20-1.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if not path.is_file() or relative.parts[0] == 'audit' or path.suffix == '.zip':
            continue
        info = zipfile.ZipInfo(relative.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
PY
cat "$output/SHA256SUMS"
