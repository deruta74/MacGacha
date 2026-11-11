#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline provenance audit regressions; no Wine, network or installed runtimes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('audit', ROOT / 'scripts/audit-wine-dependencies.py')
        cls.audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.audit)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / 'wine'
        self.share = self.runtime / 'lib/GStreamer.framework/Versions/1.0/share'
        self.share.mkdir(parents=True)
        (self.share / 'versions.txt').write_text('cerbero 1.28.7\nzlib 1.3.1\n')
        (self.runtime / 'lib/libz.dylib').write_bytes(b'library')
        self.recipe = self.root / 'recipe.tar.gz'
        self.recipe.write_bytes(b'pinned recipe archive')
        self.lock = {'schemaVersion': 1, 'cerberoVersion': '1.28.7', 'recipeArchive': {
            'name': self.recipe.name, 'sha256': self.audit.build.sha(self.recipe)}}
        self.receipt = {'schemaVersion': 1, 'version': 'test', 'inputs': {'inputs': [
            {'name': 'dependency-donor.tar.xz', 'kind': 'donor', 'sha256': 'a' * 64}]},
            'entries': self.audit.build.inventory(self.runtime)}

    def run_audit(self):
        return self.audit.audit(self.runtime, self.receipt, self.lock, self.root)

    def test_deterministic_report_does_not_claim_source_delivery(self):
        first = self.run_audit()
        self.assertEqual(first, self.run_audit())
        self.assertFalse(first['sourceDeliveryComplete'])
        self.assertEqual(first['framework']['reportedVersions']['zlib'], '1.3.1')
        self.assertIn('lib/libz.dylib', first['unresolvedRootLibraries'])
        self.assertNotIn(str(self.root), json.dumps(first))

    def test_changed_or_added_runtime_file_rejected(self):
        for name in ['lib/libz.dylib', 'lib/new.dylib']:
            with self.subTest(name=name):
                p = self.runtime / name
                before = p.read_bytes() if p.exists() else None
                p.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'receipt'): self.run_audit()
                if before is None: p.unlink()
                else: p.write_bytes(before)

    def test_escaping_symlink_rejected(self):
        (self.runtime / 'escape').symlink_to(self.recipe)
        with self.assertRaises(ValueError): self.run_audit()

    def test_recipe_tampering_rejected(self):
        self.recipe.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'): self.run_audit()

    def test_partial_sources_are_verified_without_claiming_completeness(self):
        source = self.root / 'zlib.tar.gz'
        source.write_bytes(b'source')
        self.lock['sourceArchives'] = [{'name': source.name, 'sha256': self.audit.build.sha(source)}]
        report = self.run_audit()
        self.assertEqual(len(report['verifiedSourceArchives']), 1)
        self.assertFalse(report['sourceDeliveryComplete'])
        source.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'): self.run_audit()

    def test_recipe_name_cannot_escape_cache(self):
        self.lock['recipeArchive']['name'] = '../recipe.tar.gz'
        with self.assertRaisesRegex(ValueError, 'name'): self.run_audit()

    def test_missing_or_ambiguous_versions_rejected(self):
        path = self.share / 'versions.txt'
        for text in ['', 'cerbero 1.28.6\n', 'cerbero 1.28.7\nzlib 1\nzlib 2\n']:
            path.write_text(text)
            self.receipt['entries'] = self.audit.build.inventory(self.runtime)
            with self.assertRaises(ValueError): self.run_audit()


if __name__ == '__main__': unittest.main()
