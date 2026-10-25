#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline tests for release metadata; all signatures and keys are synthetic."""
import base64
import datetime
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).with_name("make-appcast.py"))
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class AppcastTests(unittest.TestCase):
    def make(self, **changes):
        args = dict(release="0.1.1-beta", build="42", length=12345,
                    signature=base64.b64encode(bytes(64)).decode(),
                    published=datetime.datetime(2026, 10, 25, 12, 0, tzinfo=datetime.timezone.utc))
        args.update(changes)
        return appcast.make_appcast(**args)

    def test_single_item_uses_build_counter_and_numeric_marketing_version(self):
        root = ET.fromstring(self.make())
        ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
        self.assertEqual(root.tag, "rss")
        self.assertEqual(len(root.findall("./channel/item")), 1)
        item = root.find("./channel/item")
        self.assertEqual(item.findtext("title"), "MacGacha 0.1.1-beta")
        self.assertEqual(item.findtext("sparkle:version", namespaces=ns), "42")
        self.assertEqual(item.findtext("sparkle:shortVersionString", namespaces=ns), "0.1.1")
        self.assertEqual(item.findtext("sparkle:minimumSystemVersion", namespaces=ns), "27.0")
        self.assertEqual(item.findtext("pubDate"), "Sun, 25 Oct 2026 12:00:00 GMT")
        self.assertEqual(item.findtext("sparkle:releaseNotesLink", namespaces=ns),
                         "https://github.com/deruta74/MacGacha/releases/tag/v0.1.1-beta")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/deruta74/MacGacha/releases/download/v0.1.1-beta/MacGacha-0.1.1-beta.dmg")
        self.assertEqual(enclosure.get("length"), "12345")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(len(base64.b64decode(enclosure.get(f"{{{ns['sparkle']}}}edSignature"))), 64)

    def test_rejects_invalid_release_and_build_number(self):
        for release in ["../0.1.1", "0.1", "0.1.1\n", "0.1.1-<xml>"]:
            with self.subTest(release=release), self.assertRaises(ValueError):
                self.make(release=release)
        for build in ["0", "-1", "01", "1.2", "1\n", "", "$(id)"]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                self.make(build=build)

    def test_rejects_empty_archive_or_malformed_signature(self):
        for length in [0, -1]:
            with self.subTest(length=length), self.assertRaises(ValueError):
                self.make(length=length)
        for signature in ["", "not base64!", base64.b64encode(bytes(32)).decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                self.make(signature=signature)

    def test_public_key_placeholder_cannot_release(self):
        for key in ["REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY", "", "$(SPARKLE_PUBLIC_ED_KEY)",
                    base64.b64encode(bytes(64)).decode()]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                appcast.validate_public_key(key)
        appcast.validate_public_key(base64.b64encode(bytes(32)).decode())

    def test_command_line_measures_the_actual_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            dmg, output = folder / "test.dmg", folder / "appcast.xml"
            dmg.write_bytes(bytes(123))
            result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("make-appcast.py")),
                                     "--release", "0.1.1-beta", "--build-number", "42", "--dmg", str(dmg),
                                     "--signature", base64.b64encode(bytes(64)).decode(), "--output", str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(ET.parse(output).find("./channel/item/enclosure").get("length"), "123")


class PackageBuildNumberTests(unittest.TestCase):
    def test_invalid_build_numbers_fail_before_building(self):
        root = Path(__file__).resolve().parent.parent
        for build in ["", "0", "-1", "1.2", "01", "1\n"]:
            env = {**os.environ, "MACGACHA_BUILD_NUMBER": build}
            result = subprocess.run(["bash", "scripts/package-dmg.sh", "0.1.0-beta"], cwd=root,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("MACGACHA_BUILD_NUMBER must be a positive integer", result.stderr)

    def test_packaging_forwards_explicit_and_default_build_numbers(self):
        root = Path(__file__).resolve().parent.parent
        version = re.search(r"MARKETING_VERSION: (\S+)", (root / "project.yml").read_text()).group(1)
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            tools = {
                "xcodegen": "exit 0",
                "xcodebuild": 'printf "%s\\n" "$@" > "$RECORDED_BUILD_ARGS"; '
                              'mkdir -p "$MACGACHA_DERIVED_DATA_PATH/Build/Products/Release/MacGacha.app"',
                "codesign": "exit 0",
                "ditto": 'mkdir -p "$2"',
                "hdiutil": 'if [[ "$1" == create ]]; then touch "${@: -1}"; fi',
            }
            for name, body in tools.items():
                path = folder / name
                path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
                path.chmod(0o700)
            env = {**os.environ, "PATH": f"{folder}:{os.environ['PATH']}",
                   "MACGACHA_DERIVED_DATA_PATH": str(folder / "derived"),
                   "RECORDED_BUILD_ARGS": str(folder / "arguments")}
            for value, expected in [("42", "42"), (None, "1")]:
                env.pop("MACGACHA_BUILD_NUMBER", None)
                if value is not None:
                    env["MACGACHA_BUILD_NUMBER"] = value
                result = subprocess.run(["bash", "scripts/package-dmg.sh", version + "-beta", str(folder / "out")],
                                        cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("CURRENT_PROJECT_VERSION=" + expected, (folder / "arguments").read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
