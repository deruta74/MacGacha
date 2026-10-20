#!/usr/bin/env bash
set -euo pipefail

header1='// SPDX-License-Identifier: GPL-3.0-only'
header2='// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).'
failed=0

while IFS= read -r -d '' file; do
  if [[ "$file" == */Package.swift ]]; then
    first_line=2
  else
    first_line=1
  fi
  if [[ "$(sed -n "${first_line}p" "$file")" != "$header1" || "$(sed -n "$((first_line + 1))p" "$file")" != "$header2" ]]; then
    printf '%s\n' "$file"
    failed=1
  fi
done < <(find App Packages -type f -name '*.swift' -not -path '*/.build/*' -print0)

exit "$failed"
