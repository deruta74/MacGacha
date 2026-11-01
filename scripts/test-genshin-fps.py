#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Synthetic PE and archive checks. No compiler, network, Wine or game is used."""
import importlib.util
from pathlib import Path
import struct
import sys
sys.dont_write_bytecode = True
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("checker", Path(__file__).with_name("check-genshin-fps.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def pe(dll=True, dependency="KERNEL32.dll", export="MacGachaFpsHook"):
    """One bounded synthetic section with imports and an optional export."""
    data = bytearray(2048)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 64)
    data[64:68] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 68, 0x8664, 1, 0, 0, 0, 240, 0x2022 if dll else 0x22)
    struct.pack_into("<H", data, 88, 0x20b)
    struct.pack_into("<I", data, 104, 0x1000)
    struct.pack_into("<I", data, 148, 512)
    struct.pack_into("<H", data, 156, 3)
    struct.pack_into("<I", data, 196, 16)
    struct.pack_into("<II", data, 208, 0x1100, 40)
    data[328:336] = b".fixture"
    struct.pack_into("<IIII", data, 336, 1536, 0x1000, 1536, 512)
    struct.pack_into("<I", data, 364, 0x60000020)
    struct.pack_into("<IIIII", data, 768, 0x1180, 0, 0, 0x1160, 0x1180)
    name = dependency.encode() + b"\0"
    data[864:864 + len(name)] = name
    struct.pack_into("<QQ", data, 896, 0x11a0, 0)
    data[930:942] = b"CloseHandle\0"  # Hint/name record at RVA 0x11a0.
    if dll:
        struct.pack_into("<II", data, 200, 0x1200, 128)
        struct.pack_into("<IIIIII", data, 1040, 1, 1, 1, 0x1240, 0x1248, 0x1250)
        struct.pack_into("<I", data, 1088, 0x1000)
        struct.pack_into("<I", data, 1096, 0x1260)
        struct.pack_into("<H", data, 1104, 0)
        name = export.encode() + b"\0"
        data[1120:1120 + len(name)] = name
    return bytes(data)


class Checks(unittest.TestCase):
    def test_valid_pe(self):
        checker.check_pe(pe(), dll=True)
        checker.check_pe(pe(False), dll=False)
        data = bytearray(pe()) + bytearray(256)
        struct.pack_into("<IIII", data, 336, 1792, 0x1000, 1792, 512)
        struct.pack_into("<II", data, 208, 0x1100, 1400)
        checker.check_pe(bytes(data), dll=True)  # Directory size includes thunks/strings too.

    def test_invalid_headers_architecture_subsystem_and_timestamps(self):
        for offset, value, fmt in [(68, 0x14c, "H"), (72, 1, "I"), (88, 0x10b, "H"), (156, 2, "H")]:
            with self.subTest(offset=offset):
                data = bytearray(pe()); struct.pack_into("<" + fmt, data, offset, value)
                with self.assertRaises(ValueError): checker.check_pe(bytes(data), dll=True)
        for data in [b"MZ", pe()[:1000]]:
            with self.assertRaises(ValueError): checker.check_pe(data, dll=True)
        with self.assertRaises(ValueError): checker.check_pe(pe(False), dll=True)

    def test_rejects_third_party_imports_missing_exports_and_forwarders(self):
        for data in [pe(dependency="libgcc_s_seh-1.dll"), pe(export="OtherHook")]:
            with self.assertRaises(ValueError): checker.check_pe(data, dll=True)
        data = bytearray(pe()); struct.pack_into("<I", data, 1088, 0x1260)
        with self.assertRaises(ValueError): checker.check_pe(bytes(data), dll=True)
        data = bytearray(pe()); struct.pack_into("<I", data, 1096, 0xfffffff0)
        with self.assertRaises(ValueError): checker.check_pe(bytes(data), dll=True)

    def test_zip_layout_and_payload(self):
        with tempfile.TemporaryDirectory(prefix="genshin-fps-check-") as tmp:
            path = Path(tmp) / checker.ARCHIVE
            def archive(extra=None, missing=None, changed=None):
                with zipfile.ZipFile(path, "w") as out:
                    for name in sorted(checker.MEMBERS | ({extra} if extra else set())):
                        if name == missing: continue
                        content = pe(name.endswith(".dll")) if name in checker.BINARIES else b"source"
                        if name == changed: content = b"not a PE"
                        info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                        info.create_system = 3; info.external_attr = 0o100644 << 16
                        out.writestr(info, content)
            archive(); checker.check_archive(path)
            for kwargs in [dict(extra="../escape"), dict(missing="README.md"), dict(changed=checker.BINARIES[0])]:
                archive(**kwargs)
                with self.assertRaises(ValueError): checker.check_archive(path)


if __name__ == "__main__":
    unittest.main()
