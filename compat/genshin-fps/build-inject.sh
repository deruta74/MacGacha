#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
exec bash "$repo_root/scripts/build-genshin-fps.sh" "$@"
