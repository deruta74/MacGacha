#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Inspect and load the built module using an abort-only synthetic ntdll, never Wine."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

NTDLL_SYMBOLS = (
    'NtAllocateVirtualMemory NtClose NtDelayExecution NtFreeVirtualMemory '
    'NtQueryPerformanceCounter NtQuerySystemInformation NtSetEvent NtSetInformationThread '
    'NtWaitForSingleObject PsCreateSystemThread RtlInitUnicodeString '
    '__wine_dbg_header __wine_dbg_output __wine_dbg_strdup ntdll_umbstowcs'
).split()


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT, timeout=60)


def main():
    root = Path(sys.argv[1]).resolve(strict=True)
    module = root / 'x86_64-unix/winecoreaudio.so'
    assert run('/usr/bin/lipo', '-archs', str(module)).strip() == 'x86_64'
    run('/usr/bin/codesign', '--verify', '--strict', str(module))
    symbols = run('/usr/bin/nm', '-gU', str(module))
    for symbol in ('___wine_unix_call_funcs', '___wine_unix_call_wow64_funcs'):
        assert re.search(r'\b' + symbol + r'$', symbols, re.M), symbol
    dependencies = run('/usr/bin/otool', '-L', str(module)).splitlines()[1:]
    for line in dependencies:
        library = line.strip().split(' (')[0]
        assert library in ('@rpath/winecoreaudio.so', '@rpath/ntdll.so') or library.startswith(
            ('/System/Library/Frameworks/', '/usr/lib/')), library
    undefined = run('/usr/bin/nm', '-m', '-u', str(module))
    imported = re.findall(r'external _(\w+) \(from @rpath/ntdll.so\)', undefined)
    assert sorted(imported) == sorted(NTDLL_SYMBOLS), imported
    data = module.read_bytes()
    with zipfile.ZipFile(root / 'surround-audio-wine-11.20-1.zip') as archive:
        assert archive.read('x86_64-unix/winecoreaudio.so') == data
        assert not any(p.endswith(('.dll', '.exe')) for p in archive.namelist())
        digest = hashlib.sha256(data).hexdigest()
        assert archive.read('SHA256SUMS').decode() == f'{digest}  x86_64-unix/winecoreaudio.so\n'
        for info in archive.infolist():
            assert info.date_time == (1980, 1, 1, 0, 0, 0)
            assert info.external_attr >> 16 == 0o100644
    # Satisfy only the pinned import names, without loading any Wine code.
    # Every stub aborts: accidentally invoking a Wine function fails the check.
    with tempfile.TemporaryDirectory(prefix='surround-load-') as scratch:
        scratch = Path(scratch)
        stub = scratch / 'ntdll-stub.c'
        stub.write_text('#include <stdlib.h>\n' + ''.join(
            f'void {symbol}(void) {{ abort(); }}\n' for symbol in NTDLL_SYMBOLS))
        run('/usr/bin/clang', '-arch', 'x86_64', '-Werror', '-dynamiclib', str(stub),
            '-Wl,-install_name,@rpath/ntdll.so', '-o', str(scratch / 'ntdll.so'))
        probe = scratch / 'load-probe'
        source = Path(__file__).resolve().parent.parent / 'compat/surround-audio/load-probe.c'
        run('/usr/bin/clang', '-arch', 'x86_64', '-Werror', '-Wall', '-Wextra', str(source),
            f'-Wl,-rpath,{scratch}', '-o', str(probe))
        print(run(str(probe), str(module)).strip())


if __name__ == '__main__':
    main()
