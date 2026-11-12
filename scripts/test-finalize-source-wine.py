#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Regression for private source-built Mach-O debug-table normalization."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FinalizeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('finalize', ROOT / 'scripts/finalize-source-wine.py')
        cls.finalize = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.finalize)

    def test_debug_object_paths_removed_without_losing_exports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); outputs = []
            for name in ['one', 'two']:
                directory = root / name; directory.mkdir()
                source = directory / 'probe.c'; source.write_text('int probe(void) { return 42; }\n')
                binary = directory / 'libprobe.dylib'
                subprocess.run(['/usr/bin/clang', '-g', '-dynamiclib', source, '-o', binary,
                                '-Wl,-install_name,@rpath/libprobe.dylib'], check=True)
                self.finalize.strip_and_normalize(binary, 'com.lo7ted.macgacha.test.probe')
                self.assertIn('_probe', subprocess.check_output(['/usr/bin/nm', '-gU', binary], text=True))
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', binary], check=True)
                outputs.append(binary.read_bytes())
            self.assertEqual(*outputs)

    def test_shared_inode_refused_before_strip(self):
        import os
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); original = root / 'original'; original.write_bytes(b'keep')
            alias = root / 'alias'; os.link(original, alias)
            with self.assertRaisesRegex(ValueError, 'shared'):
                self.finalize.strip_and_normalize(alias, 'test')
            self.assertEqual(original.read_bytes(), b'keep')

    def test_donor_candidate_refused_without_creating_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); candidate = root / 'base'; candidate.mkdir()
            (candidate / 'receipt.json').write_text(json.dumps({'dependencyOrigin': 'donor'}))
            output = root / 'final'
            with self.assertRaisesRegex(ValueError, 'source-built'):
                self.finalize.finalize(candidate, output)
            self.assertFalse(output.exists())

    def test_nested_output_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, 'separate'):
                self.finalize.finalize(root, root / 'final')
            self.assertFalse((root / 'final').exists())


if __name__ == '__main__': unittest.main()
