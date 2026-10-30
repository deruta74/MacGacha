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

SAMPLE_NOTES = "# What's new\n\n- Faster game setup.\n- Better launch recovery.\n"


class AppcastTests(unittest.TestCase):
    def make(self, **changes):
        args = dict(release="0.1.1-beta", build="42", length=12345,
                    signature=base64.b64encode(bytes(64)).decode(),
                    published=datetime.datetime(2026, 10, 25, 12, 0, tzinfo=datetime.timezone.utc), notes=SAMPLE_NOTES)
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
        self.assertEqual(item.findtext("sparkle:fullReleaseNotesLink", namespaces=ns),
                         "https://github.com/deruta74/MacGacha/releases")
        self.assertIsNone(item.find("sparkle:releaseNotesLink", namespaces=ns))
        description = item.find("description")
        self.assertEqual(description.text, SAMPLE_NOTES)
        self.assertEqual(description.get(f"{{{ns['sparkle']}}}format"), "markdown")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/deruta74/MacGacha/releases/download/v0.1.1-beta/MacGacha-0.1.1-beta.dmg")
        self.assertEqual(enclosure.get("length"), "12345")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(len(base64.b64decode(enclosure.get(f"{{{ns['sparkle']}}}edSignature"))), 64)

    def test_notes_are_embedded_verbatim_and_xml_escaped(self):
        notes = "\n# What changed\n\n- Keep <files> & folders.\n- Literal ]]> and 中文 text.\n\tDetails.\n"
        result = self.make(notes=notes)
        description = ET.fromstring(result).find("./channel/item/description")
        self.assertEqual(description.text, notes)
        self.assertEqual(description.get(f"{{{appcast.SPARKLE}}}format"), "markdown")
        self.assertIn(b"&lt;files&gt; &amp; folders", result)
        self.assertNotIn(b"<![CDATA[", result)

    def test_notes_validation_rejects_empty_oversized_and_unsafe_text(self):
        for notes in ["", " \n\t", "x" * 65537, "é" * 32769,
                      "text\x00", "text\r", "text\x1f", "text\x7f", "text\x85", "text\ufffe"]:
            with self.subTest(notes=repr(notes[:20])), self.assertRaises(ValueError):
                self.make(notes=notes)
        self.make(notes="x" * 65536)
        self.make(notes="# Changes\n\tA detail\n")

    def test_preflight_and_generation_share_notes_file_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            notes, dmg, output = folder / "notes.md", folder / "test.dmg", folder / "appcast.xml"
            dmg.write_bytes(b"synthetic archive")
            command = [sys.executable, "-I", str(Path(__file__).with_name("make-appcast.py"))]
            generate = ["--release", "0.1.1-beta", "--build-number", "42", "--dmg", str(dmg),
                        "--signature", base64.b64encode(bytes(64)).decode(), "--output", str(output)]
            for data, message in [(None, "missing"), (b"\xff", "UTF-8"), (b" \n\t", "empty"),
                                  (b"x" * 65537, "65536"), (b"bad\x00", "control")]:
                if data is None:
                    notes.unlink(missing_ok=True)
                else:
                    notes.write_bytes(data)
                for arguments in [["--check-notes", str(notes)], generate + ["--notes", str(notes)]]:
                    with self.subTest(data=message, arguments=arguments):
                        result = subprocess.run(command + arguments, capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(message, result.stderr)
                        self.assertFalse(output.exists())
            notes.write_text(SAMPLE_NOTES, encoding="utf-8")
            result = subprocess.run(command + ["--check-notes", str(notes)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(command + generate, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("--notes", result.stderr)
            self.assertFalse(output.exists())

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
            dmg, output, notes = folder / "test.dmg", folder / "appcast.xml", folder / "notes.md"
            dmg.write_bytes(bytes(123))
            notes.write_text(SAMPLE_NOTES, encoding="utf-8")
            result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("make-appcast.py")),
                                     "--release", "0.1.1-beta", "--build-number", "42", "--dmg", str(dmg),
                                     "--signature", base64.b64encode(bytes(64)).decode(), "--output", str(output), "--notes", str(notes)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(ET.parse(output).find("./channel/item/enclosure").get("length"), "123")
            self.assertEqual(ET.parse(output).findtext("./channel/item/description"), SAMPLE_NOTES)


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
