#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_dir="${MACGACHA_XCODE_PROJECT_DIR:-$repo_root}"
mkdir -p "$project_dir"
project_dir="$(cd "$project_dir" && pwd)"

if [[ "$project_dir" != "$repo_root" ]]; then
  # XcodeGen rebases source groups, but local package references and raw build
  # settings still use paths relative to the generated project directory.
  for entry in App Packages RosettaPrompt THIRD_PARTY_NOTICES; do
    destination="$project_dir/$entry"
    if [[ -e "$destination" || -L "$destination" ]]; then
      if [[ ! -L "$destination" || "$(readlink "$destination")" != "$repo_root/$entry" ]]; then
        echo "Refusing to replace an existing project input: $entry" >&2
        exit 1
      fi
    else
      ln -s "$repo_root/$entry" "$destination"
    fi
  done
fi

xcodegen generate --spec "$repo_root/project.yml" --project-root "$repo_root" --project "$project_dir"
