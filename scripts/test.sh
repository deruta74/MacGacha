#!/usr/bin/env bash
set -euo pipefail

swift test --package-path Packages/LauncherKit
scripts/bootstrap.sh
xcodebuild \
  -project MacGacha.xcodeproj \
  -scheme MacGacha \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode \
  build
