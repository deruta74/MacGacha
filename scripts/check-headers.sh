#!/usr/bin/env bash
set -euo pipefail

header1='// SPDX-License-Identifier: GPL-3.0-only'
header2='// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).'
failed=0
file_count=0

for dir in App Packages; do
  if [[ ! -d "$dir" ]]; then
    printf 'error: required source directory is missing: %s\n' "$dir" >&2
    exit 1
  fi
done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if ! find App Packages -type f -name '*.swift' -not -path '*/.build/*' -print0 > "$tmp"; then
  printf 'error: failed to enumerate Swift files under App/ and Packages/\n' >&2
  exit 1
fi

while IFS= read -r -d '' file; do
  ((file_count += 1))
  if [[ "$file" == */Package.swift ]]; then
    first_line=2
  else
    first_line=1
  fi
  if [[ "$(sed -n "${first_line}p" "$file")" != "$header1" || "$(sed -n "$((first_line + 1))p" "$file")" != "$header2" ]]; then
    printf '%s\n' "$file"
    failed=1
  fi
done < "$tmp"

if (( file_count == 0 )); then
  printf 'error: no Swift files found under App/ or Packages/\n' >&2
  exit 1
fi

exit "$failed"
