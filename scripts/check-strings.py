#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Keeps App/Resources/Localizable.xcstrings in step with the code.

After a Debug build, the compiler leaves one .stringsdata file per Swift source with every
localizable string it found. Xcode's editor merges them into the catalog after a build;
xcodebuild does not. This script does the same merge into a temporary copy and fails when
the committed catalog differs: a new string is missing, or an old one is now stale.
`--write` updates the committed catalog instead.

It also flags the few code shapes that bypass localization: a String literal returned,
concatenated or wrapped in Text(verbatim:). SwiftUI shows a String as-is, so such text
must go through String(localized:) or LocalizedStringResource.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
SOURCES = ROOT / "App"

# A user-facing sentence starts with a capital letter and has a space; identifiers,
# symbol names and log categories don't.
SENTENCE = r'"[A-Z][^"\n]* [^"\n]*"'
LITERAL_PATTERNS = [
    (re.compile(r'\breturn ' + SENTENCE), "returns a String literal"),
    (re.compile(r'\b(?:case [^"\n]*|default):\s*' + SENTENCE), "yields a String literal from a switch"),
    (re.compile(SENTENCE + r'\s*\+|\+\s*' + SENTENCE), "concatenates a String literal"),
    (re.compile(r'Text\(verbatim: "[^"\n]*[A-Za-z][^"\n]*"'), "shows a literal verbatim"),
]
# Logs and errors stay English so they remain greppable; LauncherError payloads never reach the UI.
ALLOWED = re.compile(r'\blog\b|\.log\(|Logger|metadata|LauncherError\.|String\(localized:|comment:')


def stringsdata(derived: Path) -> list[Path]:
    objects = derived / "Build/Intermediates.noindex/MacGacha.build/Debug/MacGacha.build/Objects-normal"
    current = {path.stem for path in SOURCES.rglob("*.swift")}
    # Incremental builds can keep files for deleted sources; only current sources count.
    files = sorted(path for path in objects.glob("*/*.stringsdata") if path.stem in current)
    if not files:
        sys.exit(f"error: no .stringsdata under {objects}; build the MacGacha scheme in Debug first")
    return files


def sync(catalog: Path, files: list[Path]) -> None:
    subprocess.run(["xcrun", "xcstringstool", "sync", str(catalog), "--stringsdata", *map(str, files)], check=True)


def catalog_problems(derived: Path) -> list[str]:
    files = stringsdata(derived)
    with tempfile.TemporaryDirectory() as temp:
        synced = Path(temp) / CATALOG.name
        shutil.copyfile(CATALOG, synced)
        sync(synced, files)
        before = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
        after = json.loads(synced.read_text(encoding="utf-8"))["strings"]
    problems = [f"missing from the catalog: {key!r}" for key in sorted(after.keys() - before.keys())]
    problems += [f"stale (no longer in code): {key!r}" for key in sorted(before.keys() - after.keys())]
    for key in sorted(after.keys() & before.keys()):
        if after[key].get("extractionState") == "stale":
            problems.append(f"stale (no longer in code): {key!r}")
        elif after[key] != before[key]:
            problems.append(f"out of date (comment or format changed): {key!r}")
    return problems


def literal_problems() -> list[str]:
    problems = []
    for path in sorted(SOURCES.rglob("*.swift")):
        in_debug = False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#if DEBUG"):
                in_debug = True
            elif stripped.startswith("#endif"):
                in_debug = False
            if in_debug or stripped.startswith("//") or ALLOWED.search(line):
                continue
            for pattern, reason in LITERAL_PATTERNS:
                if pattern.search(line):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: {reason}; use String(localized:)")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("derived_data", type=Path, help="the -derivedDataPath of a Debug build of MacGacha")
    parser.add_argument("--write", action="store_true", help="update the committed catalog instead of checking it")
    args = parser.parse_args()
    if args.write:
        sync(CATALOG, stringsdata(args.derived_data))
        return 0
    problems = catalog_problems(args.derived_data) + literal_problems()
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"Fix the code, or run: python3 scripts/check-strings.py --write {args.derived_data}", file=sys.stderr)
        return 1
    print("Localizable.xcstrings matches the code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
