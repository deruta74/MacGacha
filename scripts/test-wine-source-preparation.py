#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Exercise official-source compatibility preparation without a compiler or network."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SourcePreparationTests(unittest.TestCase):
    def fixture(self, root):
        cache = root / 'cache'; cache.mkdir()
        inputs = root / 'inputs'; inputs.mkdir()
        def archive(name, files):
            path = cache / name
            with tarfile.open(path, 'w:gz') as target:
                for filename, value in files.items():
                    entry = tarfile.TarInfo('source/' + filename)
                    entry.size = len(value)
                    target.addfile(entry, io.BytesIO(value))
            return dict(name=name, sha256=build.sha(path))
        source = archive('upstream.tar.xz', {'VERSION': b'Wine version 11.22\n', 'file': b'upstream\n'})
        support = archive('support.tar.gz', {'scripts/driver.sh': b'build glue\n', 'dlls/crypt32/file': b'old fork code\n'})
        patch = inputs / 'compat.patch'
        patch.write_text('--- a/file\n+++ b/file\n@@ -1 +1 @@\n-upstream\n+compatible\n')
        result = inputs / 'result.json'
        result.write_text(json.dumps({'file': hashlib.sha256(b'compatible\n').hexdigest()}))
        lock = dict(sourceArchive=source['name'], inputs=[source, support],
                    compatibility=dict(archive=support['name'], patch=patch.name,
                                       sha256=build.sha(patch), scripts=['driver.sh'],
                                       resultManifest=result.name, resultManifestSha256=build.sha(result)))
        return cache, inputs, lock

    def test_applies_verified_delta_and_only_selected_build_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cache, inputs, lock = self.fixture(root)
            source = build.prepare_wine_source(lock, cache, root / 'work', inputs)
            self.assertEqual((source / 'file').read_text(), 'compatible\n')
            self.assertEqual((source / 'VERSION').read_text(), 'Wine version 11.22\n')
            self.assertEqual((source / 'scripts/driver.sh').read_text(), 'build glue\n')
            self.assertFalse((source / 'dlls/crypt32').exists())

    def test_rejects_changed_patch_and_support_before_extracting_source(self):
        for target in ('patch', 'support'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cache, inputs, lock = self.fixture(root)
                path = inputs / 'compat.patch' if target == 'patch' else cache / 'support.tar.gz'
                path.write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    build.prepare_wine_source(lock, cache, root / 'work', inputs)
                self.assertFalse((root / 'work').exists())

    def test_rejects_incompatible_delta(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cache, inputs, lock = self.fixture(root)
            patch = inputs / 'compat.patch'
            patch.write_text(patch.read_text().replace('-upstream', '-another-version'))
            lock['compatibility']['sha256'] = hashlib.sha256(patch.read_bytes()).hexdigest()
            with self.assertRaises(subprocess.CalledProcessError):
                build.prepare_wine_source(lock, cache, root / 'work', inputs)

    def test_rejects_successfully_applied_but_incorrect_source_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cache, inputs, lock = self.fixture(root)
            patch = inputs / 'compat.patch'
            patch.write_text(patch.read_text().replace('+compatible', '+corrupted'))
            lock['compatibility']['sha256'] = build.sha(patch)
            with self.assertRaisesRegex(ValueError, 'checksum'):
                build.prepare_wine_source(lock, cache, root / 'work', inputs)


if __name__ == '__main__': unittest.main()
