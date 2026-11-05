#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline regression checks for catalog publication policy."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("catalog", ROOT / "scripts/check-runtime-catalog.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CatalogPublicationTests(unittest.TestCase):
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

if __name__ == "__main__": unittest.main()
