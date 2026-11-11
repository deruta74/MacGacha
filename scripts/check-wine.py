#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Check the packaged bytes in a new prefix; retain all diagnostic state."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import pwd
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('candidate', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--deny-read', type=Path, action='append', default=[], help='Additional source SDK roots denied to runtime probes')
    args = p.parse_args()
    candidate = args.candidate.resolve(); output = args.output.absolute()
    if output.exists() or output.is_symlink(): raise ValueError('probe output must be absent')
    receipt = json.loads((candidate / 'receipt.json').read_text())
    package = candidate / (receipt['version'] + '.tar.xz')
    expected = (candidate / 'SHA256SUMS').read_text().split()[0]
    build.verify(package, expected)
    build.extract(package, output)
    runtime = output / 'wine'
    if build.inventory(runtime) != receipt['entries']: raise ValueError('unpacked package differs from receipt')
    prefix = output / 'prefix'
    for user in [pwd.getpwuid(os.getuid()).pw_name, 'Public']:
        for folder in ['Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos', 'Templates']:
            (prefix / 'drive_c/users' / user / folder).mkdir(parents=True, exist_ok=True)
    framework = runtime / 'lib/GStreamer.framework/Versions/1.0'
    env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(Path.home()),
               WINEPREFIX=str(prefix), WINESERVER=str(runtime / 'bin/wineserver'), WINELOADER=str(runtime / 'bin/wine'),
               WINEDLLOVERRIDES='mscoree,mshtml=', WINEDEBUG='-all',
               GST_PLUGIN_SYSTEM_PATH_1_0=str(framework / 'lib/gstreamer-1.0'),
               GST_PLUGIN_SCANNER=str(framework / 'libexec/gstreamer-1.0/gst-plugin-scanner'),
               GST_REGISTRY_1_0=str(output / 'gst-registry.bin'))
    results = []
    source_dependencies = receipt.get('dependencyOrigin') == 'Built from pinned sources; no donor libraries'
    if source_dependencies: env['MACGACHA_REQUIRE_TRUST'] = '1'
    def run(command, timeout=60, check=True):
        command = list(map(str, command))
        if command[0].startswith(str(runtime)) or command[0] in (str(output / 'native-probe'), str(output / 'media-probe')):
            # Prove these probes do not load the build SDK or installed runtimes.
            blocked = [(candidate / 'work').resolve(), Path('/opt/homebrew'), Path.home() / 'Library/Application Support/MacGacha', *[p.resolve() for p in args.deny_read]]
            profile = '(version 1) (allow default) ' + ' '.join('(deny file-read* (subpath ' + json.dumps(str(p)) + '))' for p in blocked)
            command = ['/usr/bin/sandbox-exec', '-p', profile, *command]
        completed = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
        results.append(dict(command=list(map(str, command)), exitCode=completed.returncode, output=completed.stdout))
        if check and (completed.returncode or 'Wine cannot find' in completed.stdout): raise RuntimeError(completed.stdout)
        return completed
    try:
        run(['/usr/bin/clang', '-arch', 'x86_64', ROOT / 'compat/wine/native-probe.c', '-o', output / 'native-probe'])
        run([output / 'native-probe', runtime])
        if source_dependencies:
            headers = candidate / 'work/dependencies/lib/GStreamer.framework/Versions/1.0'
            fixture = output / 'red.mp4'
            fixture.write_bytes(base64.b64decode((ROOT / 'compat/wine/red-h264.mp4.b64').read_bytes()))
            run(['/usr/bin/clang', '-arch', 'x86_64', ROOT / 'compat/wine/media-probe.c',
                 '-I' + str(headers / 'include/gstreamer-1.0'), '-I' + str(headers / 'include/glib-2.0'),
                 '-I' + str(headers / 'lib/glib-2.0/include'), '-L' + str(framework / 'lib'),
                 '-lgstreamer-1.0', '-lgobject-2.0', '-lglib-2.0', '-Wl,-rpath,' + str(framework / 'lib'),
                 '-o', output / 'media-probe'])
            run([output / 'media-probe', fixture])
        mingw, = (candidate / 'work/mingw-archive').iterdir()
        run([mingw / 'bin/x86_64-w64-mingw32-clang', ROOT / 'compat/wine/font-probe.c', '-o', output / 'font-probe.exe', '-lgdi32'])
        run([runtime / 'bin/wine', 'wineboot', '--init'], timeout=120)
        # Remove only prefix-owned link entries; never inspect or mutate their targets.
        for user in (prefix / 'drive_c/users').iterdir():
            if user.is_symlink(): continue
            for folder in ['Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos', 'Templates', 'My Documents', 'My Music', 'My Pictures', 'My Videos']:
                item = user / folder
                if item.is_symlink(): item.unlink(); item.mkdir()
        command = run([runtime / 'bin/wine', 'cmd', '/c', 'echo MACGACHA_PACKAGED_OK'])
        if 'MACGACHA_PACKAGED_OK' not in command.stdout: raise RuntimeError('Windows command marker missing')
        run([runtime / 'bin/wine', output / 'font-probe.exe'])
    finally:
        try:
            stopped = run([runtime / 'bin/wineserver', '-k'], timeout=15, check=False)
            if stopped.returncode not in (0, 1) or (stopped.returncode == 1 and stopped.stdout):
                raise RuntimeError('wineserver shutdown failed')
            run([runtime / 'bin/wineserver', '-w'], timeout=30)
            scan = run(['/usr/sbin/lsof', '-t', '+D', prefix], timeout=30, check=False)
            if scan.returncode != 1 or scan.stdout: raise RuntimeError('prefix still open or inspection uncertain; retained')
        finally:
            (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Packaged Wine native/font/Windows probes passed; prefix stopped:', output)

if __name__ == '__main__': main()
