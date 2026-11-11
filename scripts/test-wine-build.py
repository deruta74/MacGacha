#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Offline build-input, archive and launcher contract regressions."""
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

class WineBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = ROOT / 'scripts/build-wine.py'
        if not script.exists():
            raise AssertionError('Wine build entry point has not been implemented')
        spec = importlib.util.spec_from_file_location('wine_build', script)
        cls.build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.build)

    def test_source_sdk_rejects_changed_payload_before_copy(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); sdk = root / 'sdk'; sdk.mkdir()
            stage = sdk / 'stage'; stage.mkdir()
            (stage / 'lib').mkdir(); (stage / 'lib/file').write_bytes(b'original')
            sources = sdk / 'source-inputs'; sources.mkdir()
            (sources / 'source.tar').write_bytes(b'source')
            receipt = dict(schemaVersion=1, dependencyOrigin='Built from pinned sources; no donor libraries',
                           entries=self.build.inventory(stage), sourceInputEntries=self.build.inventory(sources))
            (sdk / 'receipt.json').write_text(json.dumps(receipt))
            (stage / 'lib/file').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'receipt'):
                self.build.prepare_source_dependencies(sdk, root / 'work')
            self.assertFalse((root / 'work').exists())

    def test_source_sdk_copies_only_verified_core_and_media(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); sdk = root / 'sdk'; stage = sdk / 'stage'
            core = stage / 'opt/macgacha/deps'; media = stage / 'opt/macgacha/media'
            (core / 'lib').mkdir(parents=True); (media / 'lib').mkdir(parents=True)
            (core / 'lib/libcore.dylib').write_bytes(b'core')
            (media / 'lib/libmedia.dylib').write_bytes(b'media')
            sources = sdk / 'source-inputs'; sources.mkdir()
            archive = sources / 'package.tar'; archive.write_bytes(b'original source')
            item = {'archive': archive.name, 'sha256': self.build.sha(archive)}
            lock = {'inputs': [item]}; (sources / 'source-build.lock.json').write_text(json.dumps(lock))
            entries = self.build.inventory(stage)
            receipt = dict(schemaVersion=1, dependencyOrigin='Built from pinned sources; no donor libraries',
                           entries=entries, sourceInputEntries=self.build.inventory(sources),
                           inputs=lock, packages=[{'source': item}], fileOwners={p: 'package' for p in entries})
            (sdk / 'receipt.json').write_text(json.dumps(receipt))
            libs = self.build.prepare_source_dependencies(sdk, root / 'work')
            self.assertEqual((libs / 'libcore.dylib').read_bytes(), b'core')
            self.assertEqual((libs / 'GStreamer.framework/Versions/Current/lib/libmedia.dylib').read_bytes(), b'media')
            archive.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'receipt'):
                self.build.prepare_source_dependencies(sdk, root / 'other-work')
            self.assertFalse((root / 'other-work').exists())

    def test_build_tools_ignore_ambient_compiler_and_config(self):
        with patch.dict(os.environ, {'SDKROOT': '/untrusted/sdk', 'DEVELOPER_DIR': '/untrusted/xcode', 'CC': '/untrusted/clang', 'CONFIG_SITE': '/untrusted/site', 'CPATH': '/untrusted/include', 'LDFLAGS': '-L/untrusted', 'PATH': '/untrusted'}):
            env = self.build.tool_environment('14.0')
            result = subprocess.check_output(['/usr/bin/env'], env=env, text=True)
            self.assertNotIn('/untrusted', result)
            self.assertEqual(env['CC'], '/usr/bin/clang')
            self.assertEqual(env['CONFIG_SITE'], '/dev/null')

    def test_pe_machine_and_truncated_headers(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'module.dll'
            data = bytearray(256); data[:2] = b'MZ'
            struct.pack_into('<I', data, 0x3c, 64)
            data[64:68] = b'PE\0\0'
            struct.pack_into('<H', data, 68, 0x8664)
            struct.pack_into('<H', data, 84, 2)
            struct.pack_into('<H', data, 88, 0x20b)
            p.write_bytes(data)
            self.build.verify_pe(p, 'x86_64')
            with self.assertRaises(ValueError): self.build.verify_pe(p, 'i386')
            for truncated in [b'', b'MZ', data[:87]]:
                p.write_bytes(truncated)
                with self.assertRaises(ValueError): self.build.verify_pe(p, 'x86_64')

    def test_content_uuid_preserves_execution_and_deterministic_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'probe.c'; source.write_text('int main(void) {return 0;}\n')
            binaries = [root / 'one', root / 'two']
            for binary in binaries:
                subprocess.run(['/usr/bin/clang', str(source), '-o', str(binary)], check=True)
                self.build.normalize_macho(binary, 'com.lo7ted.macgacha.wine.probe')
                subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)
                subprocess.run([str(binary)], check=True)
            self.assertEqual(binaries[0].read_bytes(), binaries[1].read_bytes())

    def test_tampered_cached_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'input'; p.write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                self.build.verify(p, hashlib.sha256(b'expected').hexdigest())

    def test_extraction_rejects_escape_and_link_ancestors(self):
        for entries in [[('../escape', b'bad', None)], [('link', None, '../outside'), ('link/file', b'bad', None)]]:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); archive = root / 'bad.tar'
                with tarfile.open(archive, 'w') as t:
                    for name, data, link in entries:
                        m = tarfile.TarInfo(name)
                        if link:
                            m.type = tarfile.SYMTYPE; m.linkname = link; t.addfile(m)
                        else:
                            m.size = len(data); t.addfile(m, io.BytesIO(data))
                with self.assertRaises(ValueError):
                    self.build.extract(archive, root / 'out')
                self.assertFalse((root / 'escape').exists())
                self.assertFalse((root / 'outside').exists())

    def test_archive_reproducible_and_preserves_executable_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); tree = root / 'wine'; tree.mkdir()
            p = tree / 'run'; p.write_bytes(b'payload'); p.chmod(0o755)
            (tree / 'alias').symlink_to('run')
            a, b = root / 'a.tar.xz', root / 'b.tar.xz'
            self.build.archive(tree, a)
            os.utime(p, (123456789, 123456789))
            self.build.archive(tree, b)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            self.build.extract(a, root / 'unpacked')
            self.assertEqual((root / 'unpacked/wine/alias').readlink(), Path('run'))
            self.assertTrue(os.access(root / 'unpacked/wine/run', os.X_OK))

    def test_inventory_rejects_external_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'bad').symlink_to('/usr/lib')
            with self.assertRaises(ValueError): self.build.inventory(root)

    def test_wrapper_preserves_arguments_and_helper_contract(self):
        with tempfile.TemporaryDirectory(prefix='wine wrapper ') as tmp:
            root = Path(tmp).resolve(); (root / 'bin').mkdir()
            wrapper = ROOT / 'compat/wine/wine-wrapper.sh'
            p = root / 'bin/wine'; p.write_bytes(wrapper.read_bytes()); p.chmod(0o755)
            real = root / 'bin/wine.real'
            probe = root / 'probe.c'
            probe.write_text('#include <stdio.h>\n#include <stdlib.h>\nint main(int c,char **v){printf("%s\\n%s\\n%s\\n%s\\n",v[1],v[2],getenv("DYLD_FALLBACK_LIBRARY_PATH"),getenv("GST_PLUGIN_SCANNER"));}\n')
            subprocess.run(['cc', str(probe), '-o', str(real)], check=True)
            output = subprocess.check_output([str(p), 'one two', '$literal'], env={'PATH':'/usr/bin:/bin'}, text=True).splitlines()
            self.assertEqual(output[:2], ['one two', '$literal'])
            self.assertEqual(output[2], f'{root}/lib:{root}/lib/GStreamer.framework/Versions/1.0/lib')
            self.assertIn('$wrapper_dir/wine.real', wrapper.read_text())
            self.assertEqual(output[3], f'{root}/lib/GStreamer.framework/Versions/1.0/libexec/gstreamer-1.0/gst-plugin-scanner')

if __name__ == '__main__': unittest.main()
