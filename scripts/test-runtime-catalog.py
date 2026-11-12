#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression checks for catalog publication policy."""
import copy
import hashlib
import io
import importlib.util
import json
import re
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("catalog", ROOT / "scripts/check-runtime-catalog.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CatalogPublicationTests(unittest.TestCase):
    def test_draft_upload_race_never_replaces_assets(self):
        spec = importlib.util.spec_from_file_location("upload", ROOT / "scripts/upload-immutable-release.py")
        upload = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(upload)
        for race, content in [(False, b"same"), (True, b"same"), (True, b"different")]:
            assets = {} if race else {"runtime.zip": content}
            calls = []
            def gh(*args):
                calls.append(args)
                self.assertNotIn("--clobber", args)
                self.assertNotIn("delete-asset", args)
                if args[1] == "view":
                    return json.dumps({"isDraft": True, "assets": [{"name": name} for name in assets]})
                if args[1] == "download":
                    (Path(args[-1]) / "runtime.zip").write_bytes(assets["runtime.zip"])
                    return ""
                if args[1] == "upload":
                    # A competing upload and publication occur after the draft check.
                    assets["runtime.zip"] = content
                    raise subprocess.CalledProcessError(1, "upload")
                self.fail("Unexpected release mutation")
            with tempfile.TemporaryDirectory() as directory, patch.object(upload, "gh", gh):
                asset = Path(directory) / "runtime.zip"
                asset.write_bytes(b"same")
                if content == b"different":
                    with self.assertRaises(ValueError): upload.upload("runtime-tag", [asset])
                else:
                    upload.upload("runtime-tag", [asset])
                self.assertEqual(assets["runtime.zip"], content)
                self.assertEqual(sum(call[1] == "upload" for call in calls), int(race))

    def test_immutable_release_assets_cannot_be_replaced(self):
        for name in ["crypt32-fix.yml", "surround-audio.yml", "wine.yml"]:
            self.assertNotIn("--clobber", (ROOT / ".github/workflows" / name).read_text())
        channel = (ROOT / ".github/workflows/runtime-catalog.yml").read_text()
        replacements = [line.strip() for line in channel.splitlines() if "--clobber" in line]
        self.assertEqual(replacements, ["gh release upload runtime-catalog-v1 RuntimeCatalog/runtime-catalog.json RuntimeCatalog/runtime-catalog.json.sig --clobber"])

    def test_workflow_actions_are_immutable(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for action in re.findall(r"uses:\s*(\S+)", path.read_text()):
                self.assertRegex(action, r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$", str(path))

    def test_catalog_key_configuration_rejects_placeholders_and_supports_rotation(self):
        import base64
        key_spec = importlib.util.spec_from_file_location("catalog_keys", ROOT / "scripts/check-runtime-catalog-keys.py")
        keys = importlib.util.module_from_spec(key_spec); key_spec.loader.exec_module(keys)
        first = base64.b64encode(bytes(range(32))).decode()
        second = base64.b64encode(bytes(range(1, 33))).decode()
        self.assertEqual(len(keys.validate(first + "," + second)), 2)
        for value in ["", "UNCONFIGURED", first + "," + first, base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(Exception): keys.validate(value)
    def setUp(self):
        self.catalog = json.loads((ROOT / "RuntimeCatalog/runtime-catalog.json").read_text())
        self.baseline = json.loads((ROOT / "App/Resources/runtime-manifest.json").read_text())

    def test_initial_catalog_and_strict_revision(self):
        module.validate(self.catalog, self.baseline)
        with self.assertRaises(ValueError):
            module.validate(self.catalog, self.baseline, self.catalog)
        next_catalog = copy.deepcopy(self.catalog)
        next_catalog["revision"] += 1
        module.validate(next_catalog, self.baseline, self.catalog)

    def test_rejects_identity_reuse_and_unknown_profile(self):
        for mutate in [lambda c: c["manifest"]["components"][0].update(size=1),
                       lambda c: c["bundleBindings"][0].update(profileID="unknown"),
                       lambda c: c.update(clientContract="unknown")]:
            candidate = copy.deepcopy(self.catalog)
            mutate(candidate)
            with self.assertRaises(ValueError): module.validate(candidate, self.baseline)

    def test_requires_https_and_pinned_archives(self):
        for mutate in [lambda c: c.update(url="http://example.com/archive"),
                       lambda c: c.update(sha256={"algorithm": "md5", "hex": "0" * 32})]:
            candidate = copy.deepcopy(self.catalog)
            component = candidate["manifest"]["components"][0]
            component["version"] += "-new"
            component["id"] += "-new"
            mutate(component)
            with self.assertRaises(ValueError): module.validate(candidate, self.baseline)

    def test_history_cannot_be_dropped_or_binding_changed(self):
        for mutate in [lambda c: c["manifest"]["components"].pop(),
                       lambda c: c["helperBindings"][0].update(profileIDs=[])]:
            candidate = copy.deepcopy(self.catalog)
            candidate["revision"] += 1
            mutate(candidate)
            with self.assertRaises(ValueError): module.validate(candidate, self.baseline, self.catalog)

    def test_client_layout_and_complete_recommendations(self):
        for key in ["recommendedBundles", "recommendedHelpers"]:
            candidate = copy.deepcopy(self.catalog)
            candidate[key] = {}
            with self.assertRaises(ValueError): module.validate(candidate, self.baseline)
        candidate = copy.deepcopy(self.catalog)
        component = copy.deepcopy(next(c for c in candidate["manifest"]["components"] if c["kind"] == "genshinFps"))
        original = component["id"]
        component.update(id=original + "-new", version=component["version"] + "-new", wineBinary="arbitrary.exe")
        candidate["manifest"]["components"].append(component)
        binding = copy.deepcopy(next(b for b in candidate["helperBindings"] if b["componentID"] == original))
        binding["componentID"] = component["id"]
        candidate["helperBindings"].append(binding)
        candidate["recommendedHelpers"]["genshinFps"] = component["id"]
        with self.assertRaises(ValueError): module.validate(candidate, self.baseline)

    def test_retry_uses_highest_immutable_snapshot_and_identical_bytes(self):
        newer = copy.deepcopy(self.catalog)
        newer["revision"] += 1
        previous = module.latest_previous([self.catalog, newer])
        self.assertEqual(previous, newer)
        with self.assertRaises(ValueError): module.validate(self.catalog, self.baseline, previous, resume_identical=True)
        module.validate(newer, self.baseline, previous, resume_identical=True)
        changed = copy.deepcopy(newer)
        changed["recommendedHelpers"]["surroundAudio"] = "surround-audio-wine-11.20-1"
        with self.assertRaises(ValueError): module.validate(changed, self.baseline, previous, resume_identical=True)
        with self.assertRaises(ValueError): module.latest_previous([changed, newer])
        self.assertIsNone(module.latest_previous([]))

    def test_missing_channel_and_incomplete_snapshot_are_recoverable(self):
        entries = [
            {"tag_name": "runtime-catalog-v1", "draft": False, "assets": []},
            {"tag_name": "runtime-catalog-v1-r1", "draft": False, "assets": [{"name": "runtime-catalog.json"}]},
            {"tag_name": "runtime-catalog-v1-r2", "draft": False, "assets": []},
            {"tag_name": "runtime-catalog-v1-r99", "draft": True, "assets": []},
        ]
        self.assertEqual(module.publication_state(entries), {
            "channelHasAsset": False, "latestCompleteSnapshot": "runtime-catalog-v1-r1", "highestRevision": 2})
        entries[2]["assets"] = [{"name": "runtime-catalog.json"}]
        self.assertEqual(module.publication_state(entries)["latestCompleteSnapshot"], "runtime-catalog-v1-r2")

    def test_apple_assets_use_release_metadata_without_downloading(self):
        candidate = copy.deepcopy(self.catalog)
        component = copy.deepcopy(next(c for c in candidate["manifest"]["components"] if c.get("consent") == "appleGPTK"))
        component.update(id=component["id"] + "-new", version=component["version"] + "-new")
        candidate["manifest"]["components"].append(component)
        asset = {"name": component["url"].rsplit("/", 1)[1], "browser_download_url": component["url"],
                 "size": component["size"], "state": "uploaded", "digest": "sha256:" + component["sha256"]["hex"]}
        class Result:
            stdout = json.dumps({"assets": [asset]})
        with patch.object(module.urllib.request, "build_opener") as opener:
            with patch.object(module.subprocess, "run", return_value=Result()):
                module.verify_assets(candidate, self.catalog["manifest"], None)
            opener.return_value.open.assert_not_called()
        asset["digest"] = "sha256:" + "0" * 64
        Result.stdout = json.dumps({"assets": [asset]})
        with patch.object(module.subprocess, "run", return_value=Result()):
            with self.assertRaises(ValueError): module.verify_assets(candidate, self.catalog["manifest"], None)

    def test_new_asset_requires_matching_bytes_and_size(self):
        candidate = copy.deepcopy(self.catalog)
        component = copy.deepcopy(candidate["manifest"]["components"][0])
        component.update(id=component["id"] + "-new", version=component["version"] + "-new",
                         size=3, sha256={"algorithm": "sha256", "hex": hashlib.sha256(b"abc").hexdigest()})
        candidate["manifest"]["components"].append(component)

        class Response(io.BytesIO):
            status = 200

        class Opener:
            def __init__(self, payload): self.payload = payload
            def open(self, request, timeout): return Response(self.payload)

        for payload in [b"ab", b"abcd", b"bad"]:
            with patch.object(module.urllib.request, "build_opener", return_value=Opener(payload)):
                with self.assertRaises(ValueError):
                    module.verify_assets(candidate, self.catalog["manifest"], None)
        with patch.object(module.urllib.request, "build_opener", return_value=Opener(b"abc")):
            module.verify_assets(candidate, self.catalog["manifest"], None)

if __name__ == "__main__": unittest.main()
