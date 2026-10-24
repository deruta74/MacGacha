#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
# Builds the Release app and wraps it in a drag-to-Applications disk image.
# Usage: scripts/package-dmg.sh <release-name> [output-dir]   e.g. scripts/package-dmg.sh 0.1.0-beta
set -euo pipefail

name="${1:?usage: scripts/package-dmg.sh <release-name> [output-dir]}"
output_dir="${2:-.build/release}"
derived_data_path="${MACGACHA_DERIVED_DATA_PATH:-.build/xcode-release}"

if [[ ! "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  printf 'error: release name must look like 0.1.0 or 0.1.0-beta, got: %s\n' "$name" >&2
  exit 1
fi
# CFBundleShortVersionString only takes the numeric part; the suffix lives in the file and tag names.
marketing_version="${name%%-*}"
project_version=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
if [[ "$project_version" != "$marketing_version" ]]; then
  printf 'error: project.yml MARKETING_VERSION is %s, release %s needs %s\n' "$project_version" "$name" "$marketing_version" >&2
  exit 1
fi

scripts/bootstrap.sh
xcodebuild \
  -project MacGacha.xcodeproj \
  -scheme MacGacha \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  build

app="$derived_data_path/Build/Products/Release/MacGacha.app"
codesign --verify --strict "$app"

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/MacGacha.app"
ln -s /Applications "$staging/Applications"

mkdir -p "$output_dir"
dmg="$output_dir/MacGacha-$name.dmg"
rm -f "$dmg"
hdiutil create -volname "MacGacha $name" -srcfolder "$staging" -fs APFS -format ULFO -quiet "$dmg"
hdiutil verify -quiet "$dmg"
(cd "$output_dir" && shasum -a 256 "MacGacha-$name.dmg" > "MacGacha-$name.dmg.sha256")
printf '%s\n' "$dmg"
