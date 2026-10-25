#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
# Checks that a built app can load its embedded frameworks under its own code-signing rules.
# codesign --verify only checks signature integrity; library validation is decided by dyld at
# launch. A probe signed like the app (same identity, flags and entitlements) dlopens each
# framework, so a release that would crash at launch fails here instead.
# Usage: scripts/check-app-loads.sh <path/to/MacGacha.app>
set -euo pipefail

app="${1:?usage: scripts/check-app-loads.sh <app>}"
app=$(cd "$app" && pwd)
frameworks="$app/Contents/Frameworks"
[[ -d "$frameworks" ]] || { printf 'no embedded frameworks in %s\n' "$app"; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

codesign -d --entitlements - --xml "$app" > "$work/entitlements.plist" 2>/dev/null || true
details=$(codesign -dv "$app" 2>&1)
sign_args=(-s - -f)
if [[ "$details" == *"flags="*"runtime"* ]]; then sign_args+=(-o runtime); fi
if [[ -s "$work/entitlements.plist" ]]; then sign_args+=(--entitlements "$work/entitlements.plist"); fi
if [[ "$details" != *$'\n'"Signature=adhoc"* ]]; then
  printf 'error: %s is not ad-hoc signed; extend this check before using another identity\n' "$app" >&2
  exit 1
fi

cat > "$work/probe.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  int failed = 0;
  for (int i = 1; i < argc; i++) {
    if (!dlopen(argv[i], RTLD_NOW)) { fprintf(stderr, "error: cannot load %s\n%s\n", argv[i], dlerror()); failed = 1; }
  }
  return failed;
}
C
clang -arch arm64 -o "$work/probe" "$work/probe.c"
codesign "${sign_args[@]}" "$work/probe" 2>/dev/null

binaries=()
for framework in "$frameworks"/*.framework; do
  [[ -e "$framework" ]] || continue
  name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$framework/Resources/Info.plist")
  binaries+=("$framework/$name")
done
[[ ${#binaries[@]} -gt 0 ]] || { printf 'no embedded frameworks in %s\n' "$app"; exit 0; }

"$work/probe" "${binaries[@]}"
printf 'loaded %d embedded framework(s) under the app'"'"'s signing rules\n' "${#binaries[@]}"
