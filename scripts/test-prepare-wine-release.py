#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline release mapping and source-closure regressions."""
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WineReleaseTests(unittest.TestCase):
    def test_maps_qualified_bytes_and_retains_complete_sources(self):
        spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/prepare-wine-release.py')
        release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(release)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); candidate = root / 'candidate'; candidate.mkdir()
            runtime = candidate / 'wine'; (runtime / 'bin').mkdir(parents=True)
            (runtime / 'bin/wine').write_text('wrapper')
            (runtime / 'bin/wine.real').write_bytes(b'loader')
            sources = candidate / 'source-inputs'; sources.mkdir()
            (sources / 'original.tar.gz').write_bytes(b'original source')
            receipt = dict(version='preview4', entries=release.build.inventory(runtime),
                           sourceInputEntries=release.build.inventory(sources))
            (candidate / 'receipt.json').write_text(json.dumps(receipt))
            release.build.archive(runtime, candidate / 'preview4.tar.xz')
            expected = release.build.sha(candidate / 'preview4.tar.xz')
            release.prepare(candidate, root / 'release', expected)
            binary = root / 'release/wine-11.20-macgacha-1.0.tar.xz'
            self.assertEqual(release.build.sha(binary), expected)
            with tarfile.open(root / 'release/wine-11.20-macgacha-1.0-sources.tar.xz') as archive:
                self.assertEqual(archive.extractfile('sources/source-inputs/original.tar.gz').read(), b'original source')
                self.assertIn('sources/receipt.json', archive.getnames())
            (sources / 'original.tar.gz').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'source'):
                release.prepare(candidate, root / 'bad', expected)
            self.assertFalse((root / 'bad').exists())


if __name__ == '__main__': unittest.main()
