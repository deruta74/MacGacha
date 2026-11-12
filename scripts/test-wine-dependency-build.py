#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline tests for source-only dependency build boundaries."""
import importlib.util
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class SourceBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('deps', ROOT / 'scripts/build-wine-dependencies.py')
        cls.deps = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.deps)

    def test_rejects_binary_donor_and_escaping_input(self):
        for item in [{'name': 'donor', 'archive': 'd.tar', 'kind': 'donor'},
                     {'name': 'zlib', 'archive': '../z.tar', 'kind': 'configure'}]:
            with self.assertRaises(ValueError): self.deps.validate_inputs([item])

    def test_rejects_duplicate_archive_names(self):
        item = {'name': 'zlib', 'archive': 'z.tar', 'kind': 'configure'}
        with self.assertRaises(ValueError): self.deps.validate_inputs([item, item])

    def test_environment_does_not_inherit_external_search_paths(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {
            'CPATH': '/untrusted', 'PKG_CONFIG_PATH': '/untrusted', 'DYLD_LIBRARY_PATH': '/untrusted',
            'SDKROOT': '/untrusted', 'CC': '/untrusted', 'CFLAGS': '/untrusted'}):
            env = self.deps.environment(Path(tmp))
            self.assertNotIn('/untrusted', str(env))
            self.assertIn('-arch x86_64', env['CC'])
            self.assertEqual(env['PKG_CONFIG_SYSROOT_DIR'], tmp + '/stage')

    def test_existing_output_is_not_reused(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'absent'):
                self.deps.prepare_root(Path(tmp))

    def test_staged_library_loads_without_installed_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); lib = root / 'stage/opt/macgacha/deps/lib'; lib.mkdir(parents=True)
            source = root / 'probe.c'; source.write_text('int probe(void) { return 7; }\n')
            dylib = lib / 'libprobe.dylib'
            subprocess.run(['/usr/bin/clang', '-dynamiclib', str(source), '-o', str(dylib),
                            '-Wl,-install_name,/opt/macgacha/deps/lib/libprobe.dylib'], check=True)
            self.deps.relocate_stage(root)
            source.write_text('int probe(void); int main(void) { return probe() != 7; }\n')
            binary = root / 'probe'
            subprocess.run(['/usr/bin/clang', str(source), '-L' + str(lib), '-lprobe',
                            '-Wl,-rpath,' + str(lib), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], env={'PATH': '/usr/bin:/bin'}, check=True)


if __name__ == '__main__': unittest.main()
