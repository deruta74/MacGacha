#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Keeps App/Resources/Localizable.xcstrings in step with the code.

After a Debug build, the compiler leaves one .stringsdata file per Swift source with every
localizable string it found. Xcode's editor merges them into the catalog after a build;
xcodebuild does not. This script does the same merge into a temporary copy and fails when
the committed catalog differs: a new string is missing, or an old one is now stale.
`--write` updates the committed catalog instead.

Every string must also be translated into each language in TRANSLATIONS, with matching
format argument positions and types in every variation, so a new string can't ship in English only.

It also flags the few code shapes that bypass localization: a String literal returned,
concatenated or wrapped in Text(verbatim:). SwiftUI shows a String as-is, so such text
must go through String(localized:) or LocalizedStringResource.
"""
from __future__ import annotations

import argparse
from collections import Counter
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
# Package catalogs aren't synced from code here (SwiftPM builds them), but their
# translations are checked like the app's.
PACKAGE_CATALOGS = sorted((ROOT / "Packages/LauncherKit/Sources").glob("*/Localizable.xcstrings"))
TRANSLATIONS = ["zh-Hans", "zh-Hant", "ja", "ko", "ru", "uk", "de", "fr", "es", "pt", "id", "th", "vi"]
# Preserve length modifiers: %@, %d, %ld and %lld are different argument types.
FORMAT_ARGUMENT = re.compile(
    r"%%|%(?:(?P<position>[1-9]\d*)\$)?[-+ #0']*"
    r"(?P<width>\d+|\*(?:[1-9]\d*\$)?)?"
    r"(?:\.(?P<precision>\d+|\*(?:[1-9]\d*\$)?))?"
    r"(?P<length>hh|ll|h|l|j|z|t|q|L)?(?P<type>[@diuoxXfFeEgGaAcCsSpn])"
)
# Apple's content-addressed legal text remains verbatim, rather than being translated.
APPLE_LICENSE_TITLE = "Apple Game Porting Toolkit License"
APPLE_LICENSE_PREFIX = "ENGLISH\n\u00a0\nAPPLE INC. \nSOFTWARE LICENSE AGREEMENT FOR GAME PORTING TOOLKIT"

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


def translation_problems(catalog: Path) -> list[str]:
    problems = []
    name = catalog.relative_to(ROOT)
    for key, entry in sorted(json.loads(catalog.read_text(encoding="utf-8"))["strings"].items()):
        for language in TRANSLATIONS:
            problems += entry_translation_problems(key, entry, language, str(name))
    return problems


def string_units(node: dict, path: str = "") -> list[tuple[str, dict]]:
    if not node:
        return [(path, {})]
    units = []
    for key, value in node.items():
        branch = f"{path}.{key}" if path else key
        if key == "stringUnit":
            units.append((branch, value if isinstance(value, dict) else {}))
        elif isinstance(value, dict):
            units += string_units(value, branch)
    return units


def missing_variation_defaults(node: dict, path: str = "") -> list[str]:
    missing = []
    variations = node.get("variations", {})
    if isinstance(variations, dict):
        for dimension, branches in variations.items():
            if dimension in ("plural", "device") and (
                not isinstance(branches, dict) or not isinstance(branches.get("other"), dict)
            ):
                prefix = f"{path}." if path else ""
                missing.append(f"{prefix}variations.{dimension}.other")
    for key, value in node.items():
        if isinstance(value, dict):
            missing += missing_variation_defaults(value, f"{path}.{key}" if path else key)
    return missing


def entry_translation_problems(key: str, entry: dict, language: str, name: str) -> list[str]:
    if entry.get("shouldTranslate") is False or key == APPLE_LICENSE_TITLE or key.startswith(APPLE_LICENSE_PREFIX):
        return []
    localization = entry.get("localizations", {}).get(language, {})
    problems = [f"{name}: {language} translation of {key!r} is missing mandatory variation {branch}"
                for branch in missing_variation_defaults(localization)]
    units = string_units(localization)
    if not units:
        return problems + [f"{name}: no {language} translation for {key!r}"]
    for branch, unit in units:
        value = unit.get("value")
        if unit.get("state") != "translated" or not isinstance(value, str) or not value:
            problems.append(f"{name}: no {language} translation for {key!r} ({branch})")
        elif not format_arguments_match(key, value):
            problems.append(f"{name}: {language} translation of {key!r} has different format arguments ({branch})")
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


def format_arguments(text: str) -> Counter:
    result = Counter()
    implicit = 1
    modes = set()
    offset = 0

    def argument(position: str | None, kind: str) -> None:
        nonlocal implicit
        modes.add("explicit" if position else "implicit")
        index = int(position) if position else implicit
        if not position:
            implicit += 1
        result[(index, kind)] += 1

    while (offset := text.find("%", offset)) != -1:
        match = FORMAT_ARGUMENT.match(text, offset)
        if match is None:
            raise ValueError("invalid format specifier")
        offset = match.end()
        if match.group() == "%%":
            continue
        for field in [match.group("width"), match.group("precision")]:
            if field and field.startswith("*"):
                argument(field[1:-1] if field.endswith("$") else None, "d")
        argument(match.group("position"), (match.group("length") or "") + match.group("type"))
    if len(modes) > 1:
        raise ValueError("mixed positional and sequential arguments")
    return result


def format_arguments_match(source: str, translated: str) -> bool:
    try:
        return format_arguments(source) == format_arguments(translated)
    except ValueError:
        return False


def self_check() -> None:
    rejected = [("Value %@", "值 %lld"), ("%1$@ %2$@", "%1$@ %1$@"), ("%@", "%%"),
                ("%ld", "%lld"), ("%u", "%d"), ("%1$@ %2$lld", "%2$ld %1$@"),
                ("%@", "%"), ("%*.*f", "%f"), ("%@ %@", "%1$@ %@")]
    accepted = [("%1$@ %2$lld", "%2$lld %1$@"), ("%% %@", "%% %@"),
                ("%@ %@", "%2$@ %1$@"), ("%lld", "%1$lld"), ("plain", "普通"),
                ("%*.*f", "%3$*1$.*2$f"), ("%1$@ %1$@", "%1$@ %1$@")]
    for source, translated in rejected:
        assert not format_arguments_match(source, translated), (source, translated)
    for source, translated in accepted:
        assert format_arguments_match(source, translated), (source, translated)

    def unit(text: str) -> dict:
        return {"stringUnit": {"state": "translated", "value": text}}

    entry = {"localizations": {"zh-Hans": {"variations": {"plural": {
        "one": unit("%lld 个"), "other": unit("%lld 个")}}}}}
    assert not entry_translation_problems("%lld items", entry, "zh-Hans", "fixture")
    entry["localizations"]["zh-Hans"]["variations"]["plural"]["other"] = unit("%ld 个")
    errors = entry_translation_problems("%lld items", entry, "zh-Hans", "fixture")
    assert len(errors) == 1 and "other" in errors[0], errors
    entry["localizations"]["zh-Hans"]["variations"]["plural"]["other"] = unit("%%")
    assert entry_translation_problems("%lld items", entry, "zh-Hans", "fixture")
    entry["localizations"]["zh-Hans"]["variations"]["plural"]["other"] = {}
    errors = entry_translation_problems("%lld items", entry, "zh-Hans", "fixture")
    assert len(errors) == 1 and "other" in errors[0], errors
    for dimension, category in [("plural", "one"), ("device", "mac")]:
        missing_other = {"localizations": {"ru": {"variations": {dimension: {
            category: unit("%lld")}}}}}
        errors = entry_translation_problems("%lld", missing_other, "ru", "fixture")
        assert len(errors) == 1 and f"{dimension}.other" in errors[0], errors
        missing_other["localizations"]["ru"]["variations"][dimension]["other"] = unit("%lld")
        assert not entry_translation_problems("%lld", missing_other, "ru", "fixture")
        missing_other["localizations"]["ru"]["variations"][dimension]["other"] = None
        assert entry_translation_problems("%lld", missing_other, "ru", "fixture")
    nested = {"localizations": {"ru": {"variations": {"device": {
        "mac": {"variations": {"plural": {"one": unit("%lld")}}}, "other": unit("%lld")}}}}}
    errors = entry_translation_problems("%lld", nested, "ru", "fixture")
    assert len(errors) == 1 and "device.mac.variations.plural.other" in errors[0], errors
    nested["localizations"]["ru"]["variations"]["device"]["mac"]["variations"]["plural"]["other"] = unit("%lld")
    assert not entry_translation_problems("%lld", nested, "ru", "fixture")
    assert entry_translation_problems("Value %@", {}, "zh-Hans", "fixture")
    assert not entry_translation_problems("Value %@", {"shouldTranslate": False}, "zh-Hans", "fixture")
    for legal in [APPLE_LICENSE_TITLE, APPLE_LICENSE_PREFIX + "\nTerms"]:
        assert not entry_translation_problems(legal, {}, "ja", "fixture")
    assert entry_translation_problems("Read Apple's license terms", {}, "ja", "fixture")
    assert len(TRANSLATIONS) == 13 and len(set(TRANSLATIONS)) == 13 and "en" not in TRANSLATIONS
    print("String format self-check passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("derived_data", nargs="?", type=Path, help="the -derivedDataPath of a Debug build of MacGacha")
    parser.add_argument("--write", action="store_true", help="update the committed catalog instead of checking it")
    parser.add_argument("--self-check", action="store_true", help="check format validation without a build")
    args = parser.parse_args()
    if args.self_check:
        self_check()
        return 0
    if args.derived_data is None:
        parser.error("derived_data is required unless --self-check is used")
    if args.write:
        sync(CATALOG, stringsdata(args.derived_data))
        return 0
    problems = catalog_problems(args.derived_data) + literal_problems()
    for catalog in [CATALOG, *PACKAGE_CATALOGS]:
        problems += translation_problems(catalog)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"Fix the code, or run: python3 scripts/check-strings.py --write {args.derived_data}", file=sys.stderr)
        return 1
    print("Localizable.xcstrings matches the code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
