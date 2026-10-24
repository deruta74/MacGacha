#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline installer security self-tests: python3 -I scripts/test-steam-shim-toolchain.py."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-steam-shim-toolchain.py"))
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)
ROOT = "fixture/1.0/"


def file(name, body=b"verified"):
    entry = tarfile.TarInfo(ROOT + name)
    entry.size = len(body)
    entry.mode = 0o644
    return entry, body


def link(name, target, hard=False):
    entry = tarfile.TarInfo(ROOT + name)
    entry.type = tarfile.LNKTYPE if hard else tarfile.SYMTYPE
    entry.linkname = target
    return entry, None


def archive(entries):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as output:
        for entry, body in entries:
            output.addfile(entry, io.BytesIO(body) if body is not None else None)
    data.seek(0)
    return tarfile.open(fileobj=data)


class ArchiveTests(unittest.TestCase):
    def reject(self, entries):
        with tempfile.TemporaryDirectory() as directory, archive(entries) as source:
            destination = Path(directory)
            with self.assertRaises(ValueError):
                INSTALLER.extract_bottle(source, destination, "fixture", "1.0")
            self.assertEqual(list(destination.iterdir()), [], "Validate the entire graph before writing")

    def test_review_symlink_component_escape(self):
        self.reject([link("a", "."), link("b", "a/a/a/a/../../../..")])

    def test_mixed_case_symlink_component_escape(self):
        self.reject([link("a", "."), link("b", "A/A/A/A/../../../..")])

    def test_nfc_nfd_symlink_component_escape(self):
        self.reject([link("caf\u00e9", "."), link("b", "cafe\u0301/cafe\u0301/cafe\u0301/../../..")])

    def test_case_and_unicode_normalization_aliases_are_rejected_before_writing(self):
        self.reject([file("Payload"), file("payload")])
        self.reject([file("caf\u00e9"), file("cafe\u0301")])
        # Implicit directories must not introduce ambiguous spellings either.
        self.reject([file("Folder/one"), file("folder/two")])
        self.reject([file("caf\u00e9/one"), file("cafe\u0301/two")])

    def test_case_variant_link_cycles_are_rejected(self):
        self.reject([link("a", "B"), link("b", "A")])

    def test_hardlinks_resolve_equivalent_names_to_original_member_spelling(self):
        entries = [link("copy", ROOT.upper() + "CAFE\u0301", hard=True), file("caf\u00e9")]
        with tempfile.TemporaryDirectory() as directory, archive(entries) as source:
            destination = Path(directory)
            INSTALLER.extract_bottle(source, destination, "fixture", "1.0")
            self.assertEqual((destination / ROOT / "copy").stat().st_ino, (destination / ROOT / "caf\u00e9").stat().st_ino)

    def test_cycles_including_unused_links_are_rejected(self):
        self.reject([file("data"), link("a", "b"), link("b", "a")])
        self.reject([link("a", ROOT + "b", hard=True), link("b", ROOT + "a", hard=True)])

    def test_no_member_may_have_a_symlink_ancestor(self):
        self.reject([link("a", "."), file("a/payload")])
        self.reject([file("a/payload"), link("a", ".")])
        self.reject([link("a", "."), link("a/another", "../data"), file("data")])

    def test_hardlink_target_may_not_escape_via_symlink_components(self):
        self.reject([link("a", "."), link("hard", ROOT + "a/a/a/../../..", hard=True)])

    def test_absolute_parent_and_duplicate_member_paths_are_rejected(self):
        for path in ("/outside", "fixture/1.0/../../outside", "other/1.0/data"):
            entry = tarfile.TarInfo(path)
            self.reject([(entry, b"")])
        self.reject([file("data"), file("data")])
        self.reject([link("absolute", "/tmp/outside")])

    def test_regular_file_cannot_be_an_ancestor(self):
        self.reject([file("a"), file("a/child")])

    def test_contained_symlink_chains_and_dangling_links_are_preserved(self):
        entries = [file("bin/tool"), link("lib/tool", "../bin/tool"), link("alias", "lib/tool"), link("optional", "missing")]
        with tempfile.TemporaryDirectory() as directory, archive(entries) as source:
            destination = Path(directory)
            INSTALLER.extract_bottle(source, destination, "fixture", "1.0")
            self.assertEqual((destination / ROOT / "alias").read_bytes(), b"verified")
            self.assertTrue((destination / ROOT / "optional").is_symlink())

    def test_out_of_order_hardlinks_resolve_to_regular_files(self):
        entries = [link("copy2", ROOT + "copy1", hard=True), link("copy1", ROOT + "data", hard=True), file("data")]
        with tempfile.TemporaryDirectory() as directory, archive(entries) as source:
            destination = Path(directory)
            INSTALLER.extract_bottle(source, destination, "fixture", "1.0")
            self.assertEqual((destination / ROOT / "data").stat().st_ino, (destination / ROOT / "copy2").stat().st_ino)


class RedirectTests(unittest.TestCase):
    def test_each_untrusted_redirect_is_rejected_before_a_request(self):
        for target in ("http://pkg-containers.githubusercontent.com/blob", "https://evil.example/blob",
                       "https://ghcr.io.evil.example/blob", "https://user@ghcr.io/blob", "https://ghcr.io:8443/blob"):
            with self.subTest(target=target), patch.object(INSTALLER.subprocess, "run") as curl:
                curl.return_value = subprocess.CompletedProcess([], 0, "307\nhttps://ghcr.io/blob\n" + target + "\n")
                with self.assertRaises(ValueError):
                    INSTALLER.download_bottle("https://ghcr.io/blob", Path("unused"))
                self.assertEqual(curl.call_count, 1)

    def test_allowed_redirect_uses_explicit_https_and_no_curl_config(self):
        cdn = "https://pkg-containers.githubusercontent.com/blob"
        with patch.object(INSTALLER.subprocess, "run") as curl:
            curl.side_effect = [subprocess.CompletedProcess([], 0, "307\nhttps://ghcr.io/blob\n" + cdn + "\n"),
                                subprocess.CompletedProcess([], 0, "200\n" + cdn + "\n\n")]
            INSTALLER.download_bottle("https://ghcr.io/blob", Path("unused"))
            for call in curl.call_args_list:
                args = call.args[0]
                self.assertEqual(args[:2], ["/usr/bin/curl", "-q"])
                self.assertEqual(args[args.index("--proto") + 1], "=https")
                self.assertEqual(args[args.index("--proto-redir") + 1], "=https")
                self.assertNotIn("--location", args)
            self.assertNotIn("Authorization: Bearer QQ==", curl.call_args_list[-1].args[0])

    def test_final_effective_host_is_also_validated(self):
        with patch.object(INSTALLER.subprocess, "run") as curl:
            curl.return_value = subprocess.CompletedProcess([], 0, "200\nhttps://evil.example/blob\n\n")
            with self.assertRaises(ValueError):
                INSTALLER.download_bottle("https://ghcr.io/blob", Path("unused"))

    def test_redirect_limit_is_bounded(self):
        with patch.object(INSTALLER.subprocess, "run") as curl:
            curl.return_value = subprocess.CompletedProcess([], 0, "307\nhttps://ghcr.io/blob\nhttps://ghcr.io/again\n")
            with self.assertRaises(ValueError):
                INSTALLER.download_bottle("https://ghcr.io/blob", Path("unused"))
            self.assertLessEqual(curl.call_count, 6)


class IsolationTests(unittest.TestCase):
    def test_crypt32_lock_extends_default_without_changing_steam_inputs(self):
        checker = INSTALLER.checker()
        default = checker.read_lock()
        crypt32 = checker.read_lock(Path(__file__).resolve().parent.parent / "compat/crypt32-fix/toolchain.lock")
        self.assertEqual({key: value for key, value in crypt32.items() if key != "bison"}, default)
        self.assertEqual(crypt32["bison"][0], "3.8.2")

    def test_direct_entrypoints_ignore_environment_startup_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "startup-ran"
            (root / "sitecustomize.py").write_text(f"open({str(marker)!r}, 'w').write('unexpected startup')\n")
            env = dict(os.environ, PYTHONPATH=str(root), PYTHONUSERBASE=str(root), PATH="/usr/bin:/bin")
            for name in ("install-steam-shim-toolchain.py", "check-steam-shim-toolchain.py"):
                result = subprocess.run([str(Path(__file__).with_name(name)), "--help"], env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(marker.exists(), "The shebang must isolate Python before startup")


if __name__ == "__main__":
    unittest.main(verbosity=2)
