#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH GCC_EXEC_PREFIX COMPILER_PATH
repo_root=$(cd "$(dirname "$0")/.." && pwd -P)
inputs="$repo_root/compat/genshin-fps"
fail() { printf 'genshin-fps: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || fail 'usage: build-genshin-fps.sh OUTPUT [--verify]'
output=$1; verify=0
if [[ $# == 2 ]]; then
    [[ $2 == --verify ]] || fail 'unknown argument'
    verify=1
fi
for tool in gcc as ld objdump; do
    command -v "x86_64-w64-mingw32-$tool" >/dev/null || fail "missing x86_64-w64-mingw32-$tool"
done
[[ $(x86_64-w64-mingw32-gcc -dumpfullversion) == 16.2.0 ]] || fail 'requires GCC 16.2.0'
[[ $(x86_64-w64-mingw32-gcc -dumpmachine) == x86_64-w64-mingw32 ]] || fail 'unexpected compiler target'
for tool in as ld objdump; do
    version=$("x86_64-w64-mingw32-$tool" --version)
    [[ ${version%%$'\n'*} == *'2.47.20260726'* ]] || fail 'requires binutils 2.47.20260726'
done
macros=$(printf '#include <_mingw.h>\n' | x86_64-w64-mingw32-gcc -dM -E -x c -)
for pair in '__MINGW64_VERSION_MAJOR 14' '__MINGW64_VERSION_MINOR 0' '__MINGW64_VERSION_BUGFIX 0'; do
    grep -Fx "#define $pair" <<< "$macros" >/dev/null || fail 'requires mingw-w64 headers 14.0.0'
done
[[ $macros == *'#define _UCRT '* ]] || fail 'requires the UCRT toolchain'
[[ ! -e $output && ! -L $output ]] || fail 'output must be absent'
mkdir -p "$output/audit" "$output/x86_64-windows"
output=$(cd "$output" && pwd -P)
python3 -I "$repo_root/scripts/check-steam-shim-toolchain.py" --lock "$repo_root/compat/steam-shim/toolchain.lock" \
    | tee "$output/audit/toolchain-versions.txt"
work=$(mktemp -d "${TMPDIR:-/tmp}/macgacha-genshin-fps.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$inputs/fpsstub.c" "$inputs/fpsinject.c" "$inputs/fpsshared.h" "$work/"
flags=(-std=c11 -O2 -Wall -Wextra -Werror -static-libgcc -s -fno-ident
    -frandom-seed=genshin-fps-unlock-2 "-ffile-prefix-map=$work=." "-fdebug-prefix-map=$work=."
    -Wl,--no-insert-timestamp,--build-id=none)
(
    cd "$work"
    # Preserve the tested direct DllMain entry: no CRT pseudo-relocator in the game.
    x86_64-w64-mingw32-gcc "${flags[@]}" -shared -nostartfiles -Wl,--entry,DllMain,--image-base,0x180000000 \
        fpsstub.c -o "$output/x86_64-windows/fpsstub.dll" -luser32
    x86_64-w64-mingw32-gcc "${flags[@]}" -Wl,--image-base,0x140000000 \
        fpsinject.c -o "$output/x86_64-windows/fpsinject.exe" -luser32
)
for binary in fpsstub.dll fpsinject.exe; do
    x86_64-w64-mingw32-objdump -p "$output/x86_64-windows/$binary" > "$output/audit/$binary.txt"
done
cp "$inputs/README.md" "$inputs/NOTICE.md" "$repo_root/LICENSE" "$repo_root/NOTICE" "$output/"
mkdir -p "$output/build-inputs/compat/genshin-fps" "$output/build-inputs/compat/steam-shim" "$output/build-inputs/scripts"
for source in fpsstub.c fpsinject.c fpsshared.h build-inject.sh README.md NOTICE.md; do
    cp "$inputs/$source" "$output/build-inputs/compat/genshin-fps/"
done
cp "$repo_root/compat/steam-shim/toolchain.lock" "$output/build-inputs/compat/steam-shim/"
cp "$repo_root/LICENSE" "$repo_root/NOTICE" "$output/build-inputs/"
for script in build-genshin-fps.sh check-genshin-fps.py test-genshin-fps.py install-steam-shim-toolchain.py check-steam-shim-toolchain.py; do
    cp "$repo_root/scripts/$script" "$output/build-inputs/scripts/"
done
python3 -I - "$output" <<'PY'
from pathlib import Path
import sys
import zipfile
root = Path(sys.argv[1])
with zipfile.ZipFile(root / 'genshin-fps-unlock-2.zip', 'w', compression=zipfile.ZIP_STORED) as archive:
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if not path.is_file() or relative.parts[0] == 'audit' or path.suffix == '.zip':
            continue
        info = zipfile.ZipInfo(relative.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = 0o100644 << 16
        archive.writestr(info, path.read_bytes())
PY
python3 -I "$repo_root/scripts/check-genshin-fps.py" "$output"
if [[ $verify == 1 ]]; then
    (cd "$output" && shasum -a 256 -c "$inputs/SHA256SUMS")
fi
shasum -a 256 "$output/genshin-fps-unlock-2.zip"
