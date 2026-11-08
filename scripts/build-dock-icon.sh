#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
inputs="$repo_root/compat/dock-icon"
cache=${DOCK_ICON_CACHE_DIR:-/tmp/macgacha-dock-icon-sources}
archive="$cache/wine-a0598367.tar.gz"
source_sha=fdb4adbbe5d267e20ce55838f6b8457398ee28df688ee323c7fcebbcd3aae4c0
source_url=https://api.github.com/repos/dbc-hbin/wine-yaagl-d3dmetal/tarball/a05983676741c558ac46937a29a93e02b38de8c7
fail() { printf 'dock-icon: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || fail 'usage: build-dock-icon.sh OUTPUT [--offline|--fetch-only]'
output=$1; mode=${2:-build}
case "$mode" in build|--offline|--fetch-only) ;; *) fail 'unknown mode' ;; esac
if [[ "$mode" != --offline ]]; then
    mkdir -p "$cache"
    if [[ ! -f "$archive" ]]; then
        curl -q --fail --location --proto '=https' --proto-redir '=https' "$source_url" -o "$archive"
    fi
fi
[[ -f "$archive" ]] || fail 'missing source archive; offline mode never downloads'
actual=$(shasum -a 256 "$archive"); actual=${actual%% *}
[[ "$actual" == "$source_sha" ]] || fail 'source archive checksum mismatch'
(cd "$inputs" && shasum -a 256 -c PATCHSUMS)
[[ "$mode" != --fetch-only ]] || exit 0
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'requires Apple Silicon macOS'
[[ $(/usr/bin/clang --version | head -1) == 'Apple clang version 21.0.0 (clang-2100.3.34.2)' ]] || fail 'host clang changed'
[[ $(xcrun --show-sdk-version) == 27.0 ]] || fail 'host SDK changed'
python3 -I "$repo_root/scripts/check-steam-shim-toolchain.py" --lock "$repo_root/compat/crypt32-fix/toolchain.lock"
toolchain_prefix=${STEAM_SHIM_TOOLCHAIN_PREFIX:-$(brew --prefix)}
export BISON="$toolchain_prefix/opt/bison/bin/bison"
export BISON_PKGDATADIR="$toolchain_prefix/opt/bison/share/bison" M4=/usr/bin/m4
[[ -x "$BISON" ]] || fail 'locked Bison missing'
[[ "$output" = /* ]] || output="$PWD/$output"
[[ ! -e "$output" && ! -L "$output" ]] || fail 'output must be absent'
mkdir -p "$output/audit" "$output/x86_64-unix"
work=$(mktemp -d /tmp/macgacha-dock-icon.XXXXXXXX)
trap 'status=$?; if [[ -f "$work/build/config.log" ]]; then cp "$work/build/config.log" "$output/audit/config.log"; fi; rm -rf "$work"; exit "$status"' EXIT
mkdir -p "$work/src" "$work/build"
tar -xzf "$archive" --strip-components=1 -C "$work/src"
python3 -I "$repo_root/scripts/test-dock-icon.py" "$work/src" --expect-legacy > "$output/audit/legacy-test.log"
/usr/bin/patch --batch --fuzz=0 -d "$work/src" -p1 < "$inputs/wine-bundle-icon.patch" > "$output/audit/patch.log"
python3 -I "$repo_root/scripts/test-dock-icon.py" "$work/src" > "$output/audit/policy-test.log"
(
    cd "$work/build"
    export CC='/usr/bin/clang -arch x86_64' MACOSX_DEPLOYMENT_TARGET=26.0 MSGFMT=false ac_cv_func_pipe2=no
    export CFLAGS="-O2 -mmacosx-version-min=26.0 -ffile-prefix-map=$work=. -fdebug-prefix-map=$work=."
    export LDFLAGS='-arch x86_64 -mmacosx-version-min=26.0'
    export CROSSCFLAGS="-O2 -fno-ident -frandom-seed=dock-icon-1 -ffile-prefix-map=$work=. -fdebug-prefix-map=$work=."
    export CROSSLDFLAGS='-Wl,--no-insert-timestamp,--build-id=none'
    ../src/configure --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
        --enable-archs=x86_64 --disable-build-id --disable-tests --with-mac \
        --without-x --without-freetype --without-gnutls --without-vulkan --without-opencl \
        --without-sdl --without-gstreamer --without-cups --without-sane --without-usb \
        --without-v4l2 --without-pcap --without-krb5 --without-gphoto --without-netapi \
        --without-capi --without-inotify --without-dbus --without-pulse --without-alsa \
        --without-oss > "$output/audit/configure.log" 2>&1
    make -j"${DOCK_ICON_JOBS:-4}" __tooldeps__ > "$output/audit/tools.log" 2>&1
    make -j"${DOCK_ICON_JOBS:-4}" dlls/winemac.drv/winemac.so > "$output/audit/build.log" 2>&1
)
cp "$work/build/dlls/winemac.drv/winemac.so" "$output/x86_64-unix/"
codesign --force --sign - "$output/x86_64-unix/winemac.so"
codesign --verify --strict "$output/x86_64-unix/winemac.so"
lipo -verify_arch x86_64 "$output/x86_64-unix/winemac.so"
(cd "$output" && shasum -a 256 x86_64-unix/winemac.so > SHA256SUMS)
printf 'Test module built at %s; no installed runtime was changed.\n' "$output"
