#!/usr/bin/env bash
set -euo pipefail

derived_data_path="${MACGACHA_DERIVED_DATA_PATH:-.build/xcode}"

scripts/check-headers.sh
python3 -I scripts/make-appcast.py --self-check
xcrun swift -warnings-as-errors scripts/verify-sparkle-signature.swift --self-check
swift test --package-path Packages/LauncherKit
scripts/bootstrap.sh
xcodebuild \
  -project MacGacha.xcodeproj \
  -scheme MacGacha \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  test
python3 scripts/check-strings.py "$derived_data_path"
xcodebuild \
  -project MacGacha.xcodeproj \
  -scheme MacGacha \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_path" \
  build
