#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Bounded, offline PE/ZIP validation. Never loads or executes Windows binaries."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import zipfile

sys.dont_write_bytecode = True
COMPONENT = "genshin-fps-unlock-1"
ARCHIVE = COMPONENT + ".zip"
BINARIES = ("x86_64-windows/fpsstub.dll", "x86_64-windows/fpsinject.exe")
INPUTS = ("fpsstub.c", "fpsinject.c", "fpsshared.h", "build-inject.sh", "README.md", "NOTICE.md")
SCRIPTS = ("build-genshin-fps.sh", "check-genshin-fps.py", "test-genshin-fps.py",
           "install-steam-shim-toolchain.py", "check-steam-shim-toolchain.py")
MEMBERS = set(BINARIES) | {"README.md", "NOTICE.md", "LICENSE", "NOTICE"} | {
    "build-inputs/compat/genshin-fps/" + p for p in INPUTS
} | {"build-inputs/scripts/" + p for p in SCRIPTS} | {
    "build-inputs/compat/steam-shim/toolchain.lock", "build-inputs/LICENSE", "build-inputs/NOTICE"
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_pe(data, *, dll):
    require(64 <= len(data) <= 4 << 20 and data[:2] == b"MZ", "Invalid PE size or DOS signature")

    def unpack(fmt, at):
        size = struct.calcsize("<" + fmt)
        require(0 <= at <= len(data) - size, "Truncated PE")
        return struct.unpack_from("<" + fmt, data, at)

    pe, = unpack("I", 60)
    require(data[pe:pe + 4] == b"PE\0\0", "Invalid PE signature")
    machine, count, stamp, _, _, optional_size, flags = unpack("HHIIIHH", pe + 4)
    optional = pe + 24
    require(machine == 0x8664 and 1 <= count <= 96 and stamp == 0, "PE architecture/count/timestamp mismatch")
    require(optional_size == 240 and unpack("H", optional)[0] == 0x20b, "Expected PE32+")
    require(bool(flags & 0x2000) == dll and unpack("H", optional + 68)[0] == 3, "PE DLL/subsystem mismatch")
    require(unpack("I", optional + 108)[0] == 16, "Invalid PE directory count")
    headers, = unpack("I", optional + 60)
    sections = []
    for i in range(count):
        at = optional + optional_size + 40 * i
        _, rva, size, offset = unpack("IIII", at + 8)
        require(offset <= len(data) and size <= len(data) - offset, "Truncated PE section")
        sections.append((rva, size, offset))

    def locate(rva, size=1):
        locations = [(rva, headers)] if rva < headers and size <= headers - rva else []
        for start, raw_size, offset in sections:
            if rva >= start and size <= raw_size and rva - start <= raw_size - size:
                locations.append((offset + rva - start, offset + raw_size))
        require(len(locations) == 1, "Unmapped or ambiguous PE RVA")
        offset, end = locations[0]
        require(offset <= len(data) - size and end <= len(data), "Truncated PE RVA")
        return offset, end

    def text(rva):
        at, end = locate(rva)
        end = data.find(b"\0", at, min(end, at + 256))
        require(end > at, "Invalid PE name")
        value = data[at:end]
        require(all(32 < c < 127 for c in value), "Non-ASCII PE name")
        return value.decode("ascii")

    imports, functions = set(), set()
    start, length = unpack("II", optional + 120)
    require(start and 20 <= length <= 1 << 20, "Invalid PE import directory")
    locate(start, length)
    terminated = False
    for i in range(min(length // 20, 64)):
        at, _ = locate(start + 20 * i, 20)
        thunk, timestamp, chain, name, first = unpack("IIIII", at)
        if not any((thunk, timestamp, chain, name, first)):
            terminated = True; break
        dependency = text(name).lower()
        require(dependency in {"kernel32.dll", "user32.dll", "msvcrt.dll"} or
                re.fullmatch(r"api-ms-win-crt-[a-z0-9-]+\.dll", dependency), "Non-system PE import")
        imports.add(dependency)
        for j in range(4096):
            address, _ = locate((thunk or first) + 8 * j, 8)
            value, = unpack("Q", address)
            if not value: break
            if not value & (1 << 63): functions.add(text(value + 2))
        else: raise ValueError("Unterminated PE imports")
    require(terminated and imports, "Unterminated or empty PE import directory")
    require(not functions & {"WriteProcessMemory", "VirtualAllocEx", "VirtualProtectEx", "CreateRemoteThread"},
            "Unexpected remote-memory operation")
    if dll:
        require("VirtualProtect" not in functions, "Stub must not change page protection")
        start, length = unpack("II", optional + 112)
        at, _ = locate(start, 40)
        function_count, = unpack("I", at + 20)
        name_count, = unpack("I", at + 24)
        functions, names, ordinals = unpack("III", at + 28)
        require(name_count == 1 and function_count == 1 and length >= 40, "Unexpected PE exports")
        name, = unpack("I", locate(names, 4)[0])
        require(text(name) == "MacGachaFpsHook", "Missing hook export")
        ordinal, = unpack("H", locate(ordinals, 2)[0])
        require(ordinal < function_count, "Invalid hook ordinal")
        address, = unpack("I", locate(functions + ordinal * 4, 4)[0])
        require(not start <= address < start + length, "Forwarded hook export")
        locate(address)
    return imports


def check_archive(path):
    require(path.stat().st_size <= 8 << 20, "ZIP size limit")
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        require([p.filename for p in infos] == sorted(MEMBERS), "Unexpected ZIP layout/order")
        require(sum(p.file_size for p in infos) <= 8 << 20, "ZIP expansion limit")
        for info in infos:
            require(info.date_time == (1980, 1, 1, 0, 0, 0) and info.create_system == 3 and
                    info.external_attr >> 16 == 0o100644 and info.compress_type == zipfile.ZIP_STORED and
                    not info.extra and not info.comment and not info.flag_bits, "Non-deterministic ZIP metadata")
        for name in BINARIES:
            check_pe(archive.read(name), dll=name.endswith(".dll"))
        return sum(p.file_size for p in infos)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.self_check:
        subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("test-genshin-fps.py"))], check=True)
        return
    if args.output is None: parser.error("output or --self-check is required")
    path = args.output / ARCHIVE
    expanded = check_archive(path)
    with zipfile.ZipFile(path) as archive:
        for name in BINARIES:
            require((args.output / name).read_bytes() == archive.read(name), "ZIP/binary mismatch")
    if args.manifest:
        component = next(c for c in json.loads(args.manifest.read_text())["components"] if c["id"] == COMPONENT)
        require(component["size"] == path.stat().st_size and component["installedSize"] == expanded and
                component["sha256"] == {"algorithm": "sha256", "hex": hashlib.sha256(path.read_bytes()).hexdigest()} and
                component["rootPath"] == "x86_64-windows", "Manifest differs from built component")
    print("Genshin FPS PE files and deterministic ZIP passed offline checks")


if __name__ == "__main__":
    try: main()
    except (ValueError, OSError, zipfile.BadZipFile, KeyError, StopIteration) as error:
        sys.exit("genshin-fps: " + str(error))
