#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Build private x86_64 Wine dependencies exclusively from pinned source archives."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
CORE = '/opt/macgacha/deps'
MEDIA = '/opt/macgacha/media'


def validate_inputs(items):
    names = set()
    archives = set()
    for i in items:
        if i['kind'] not in ('tool', 'configure', 'meson', 'ffmpeg'):
            raise ValueError('only source build input kinds are permitted')
        for key in ('name', 'archive'):
            name = i[key]
            if not name or Path(name).name != name or name in ('.', '..') or '\\' in name:
                raise ValueError('unsafe input name')
        if i['name'] in names or i['archive'] in archives: raise ValueError('duplicate source input')
        names.add(i['name']); archives.add(i['archive'])


def prepare_root(output):
    if output.exists() or output.is_symlink(): raise ValueError('output must be absent')
    if any(c.isspace() for c in str(output)): raise ValueError('output must not contain whitespace')
    output.mkdir(parents=True)
    for d in ('sources', 'build', 'logs', 'tools/bin', 'stage', 'source-inputs',
              'stage' + CORE + '/lib', 'stage' + MEDIA + '/lib'): (output / d).mkdir(parents=True)


def environment(output):
    env = build.tool_environment('14.0')
    core = str(output / 'stage' / CORE[1:]); media = str(output / 'stage' / MEDIA[1:])
    flags = f'-O2 -arch x86_64 -ffile-prefix-map={output}=. -fdebug-prefix-map={output}=.'
    env.update(CC='/usr/bin/clang -arch x86_64', CXX='/usr/bin/clang++ -arch x86_64',
               CFLAGS=flags, CXXFLAGS=flags, OBJC='/usr/bin/clang -arch x86_64', OBJCFLAGS=flags,
               OBJCXX='/usr/bin/clang++ -arch x86_64', OBJCXXFLAGS=flags,
               CPPFLAGS=f'-I{core}/include -I{media}/include',
               LDFLAGS=f'-arch x86_64 -L{core}/lib -L{media}/lib -Wl,-rpath,{core}/lib -Wl,-rpath,{media}/lib -Wl,-headerpad_max_install_names',
               DYLD_FALLBACK_LIBRARY_PATH=f'{core}/lib:{media}/lib',
               PATH=str(output / 'tools/bin') + ':' + media + '/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               PKG_CONFIG=str(output / 'tools/bin/pkgconf'),
               PKG_CONFIG_LIBDIR=f'{core}/lib/pkgconfig:{media}/lib/pkgconfig:{core}/share/pkgconfig:{media}/share/pkgconfig',
               PKG_CONFIG_SYSROOT_DIR=str(output / 'stage'),
               PYTHON='/usr/bin/python3', PYTHONNOUSERSITE='1')
    return env


def relocate_stage(output):
    """Make new private libraries usable by subsequent configure probes via rpaths."""
    for path in sorted((output / 'stage').rglob('*')):
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as f: magic = f.read(4)
        if magic != b'\xcf\xfa\xed\xfe': continue
        if path.stat().st_nlink != 1: raise ValueError('refusing shared staged Mach-O')
        lines = subprocess.check_output(['/usr/bin/otool', '-L', path], text=True).splitlines()[1:]
        identity = subprocess.check_output(['/usr/bin/otool', '-D', path], text=True).splitlines()[1:]
        edits = []
        for line in lines:
            dep = line.strip().split(' (', 1)[0]
            if dep.startswith((CORE + '/', MEDIA + '/')):
                if dep in identity: edits += ['-id', '@rpath/' + Path(dep).name]
                else: edits += ['-change', dep, '@rpath/' + Path(dep).name]
        if edits:
            subprocess.run(['/usr/bin/install_name_tool', *edits, path], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', path], check=True, capture_output=True)


def execute(lock, cache, output):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64': raise ValueError('Apple Silicon required')
    env = build.tool_environment(lock['deploymentTarget'])
    clang = subprocess.check_output(['/usr/bin/clang', '--version'], env=env, text=True).splitlines()[0]
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], env=env, text=True).strip()
    if clang != lock['clang'] or sdk != lock['sdk']: raise ValueError('locked compiler/SDK mismatch')
    local_paths = [ROOT / 'scripts' / name for name in ('build-wine-dependencies.py', 'build-wine.py', 'test-wine-dependency-build.py')]
    local_paths.append(ROOT / 'compat/wine/source-build.lock.json')
    fingerprints = {str(p.relative_to(ROOT)): build.sha(p) for p in local_paths}
    prepare_root(output)
    inputs = output / 'source-inputs'
    shutil.copy2(ROOT / 'compat/wine/source-build.lock.json', inputs / 'source-build.lock.json')
    for script in ('build-wine-dependencies.py', 'build-wine.py', 'test-wine-dependency-build.py'):
        shutil.copy2(ROOT / 'scripts' / script, inputs / script)
    for name in ('LICENSE', 'NOTICE'): shutil.copy2(ROOT / name, inputs / name)
    receipts = []
    for item in lock['inputs']:
        before = build.inventory(output / 'stage')
        name = item['name']; archive = cache / item['archive']
        build.verify(archive, item['sha256'])
        shutil.copy2(archive, inputs / archive.name)
        expanded = output / 'sources' / name
        build.extract(archive, expanded)
        source, = expanded.iterdir()
        source_root = source
        if item.get('sourceSubdir'):
            subdir = item['sourceSubdir']
            if Path(subdir).name != subdir or subdir in ('.', '..'): raise ValueError('unsafe source subdirectory')
            source = source / subdir
        work = output / 'build' / name; work.mkdir()
        commands = []

        def run(args, cwd=work, environ=None, label=None):
            commands.append([str(a) for a in args])
            build.run(args, cwd=cwd, env=environ or environment(output),
                      log=output / 'logs' / f'{name}-{label or len(commands)}.log')

        if item['kind'] == 'tool':
            toolenv = build.tool_environment(lock['deploymentTarget'])
            if name == 'ninja':
                run(['/usr/bin/python3', source / 'configure.py', '--bootstrap'], cwd=source, environ=toolenv)
                shutil.copy2(source / 'ninja', output / 'tools/bin/ninja')
            elif name == 'meson':
                launcher = output / 'tools/bin/meson'
                launcher.write_text('#!/bin/sh\nexec /usr/bin/python3 "' + str(source / 'meson.py') + '" "$@"\n')
                launcher.chmod(0o755)
            elif name in ('pkgconf', 'bison'):
                run([source / 'configure', '--prefix=' + str(output / 'tools'), *item['args']], environ=toolenv)
                run(['/usr/bin/make', '-j8', 'install'], environ=toolenv)
            else: raise ValueError('unsupported tool')
        else:
            env = environment(output)
            prefix = CORE if item['group'] == 'core' else MEDIA
            if item['kind'] == 'meson':
                cross = work / 'cross.ini'
                cross.write_text("[binaries]\nc = ['/usr/bin/clang', '-arch', 'x86_64']\ncpp = ['/usr/bin/clang++', '-arch', 'x86_64']\nobjc = ['/usr/bin/clang', '-arch', 'x86_64']\nobjcpp = ['/usr/bin/clang++', '-arch', 'x86_64']\npkg-config = '" + str(output / 'tools/bin/pkgconf') + "'\n[host_machine]\nsystem = 'darwin'\nkernel = 'xnu'\nsubsystem = 'macos'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n[properties]\nneeds_exe_wrapper = false\n")
                run([output / 'tools/bin/meson', 'setup', work / 'b', source, '--cross-file', cross,
                     '--prefix=' + prefix, '--libdir=lib', '--buildtype=release', '--default-library=shared',
                     '--wrap-mode=nofallback', '--auto-features=disabled', *item['args']], environ=env)
                run([output / 'tools/bin/ninja', '-C', work / 'b', '-j8'], environ=env)
                run([output / 'tools/bin/meson', 'install', '-C', work / 'b', '--no-rebuild', '--destdir', output / 'stage'], environ=env)
            else:
                args = [source / 'configure', '--prefix=' + prefix]
                if name == 'zlib': args += ['--shared']
                elif item['kind'] == 'ffmpeg':
                    args += ['--cc=/usr/bin/clang', '--cxx=/usr/bin/clang++', '--arch=x86_64', '--target-os=darwin',
                             '--enable-cross-compile', '--extra-cflags=-arch x86_64', '--extra-ldflags=-arch x86_64',
                             '--enable-shared', '--disable-static', '--disable-programs', '--disable-doc',
                             '--disable-autodetect', '--disable-x86asm', '--disable-network', '--disable-avdevice',
                             '--disable-encoders', '--disable-muxers', '--disable-filters', '--disable-gpl', '--disable-nonfree']
                else: args += ['--host=x86_64-apple-darwin', '--enable-shared', '--disable-static']
                run([*args, *item['args']], environ=env)
                run(['/usr/bin/make', '-j8'], environ=env)
                run(['/usr/bin/make', 'install', 'DESTDIR=' + str(output / 'stage')], environ=env)
            relocate_stage(output)
            notices = output / 'stage' / prefix[1:] / 'share/licenses' / name
            notices.mkdir(parents=True)
            for path in source_root.iterdir():
                if path.is_file() and not path.is_symlink() and path.name.upper().startswith(('COPYING', 'LICENSE', 'AUTHORS', 'NOTICE', 'README')):
                    shutil.copy2(path, notices / path.name)
        after = build.inventory(output / 'stage')
        receipts.append({'name': name, 'source': item, 'commands': commands,
                         'installedEntries': {p: e for p, e in after.items() if before.get(p) != e},
                         'removedEntries': sorted(set(before) - set(after))})
        (output / 'progress.json').write_text(json.dumps(receipts, indent=2) + '\n')
        print('Built source dependency:', name, flush=True)
    if fingerprints != {str(p.relative_to(ROOT)): build.sha(p) for p in local_paths}:
        raise ValueError('source build inputs changed during execution; retain diagnostic output and rebuild')
    ownership = {}
    for package in receipts:
        for path in package['removedEntries']: ownership.pop(path, None)
        for path in package['installedEntries']: ownership[path] = package['name']
    if set(ownership) != set(build.inventory(output / 'stage')): raise ValueError('unattributed staged file')
    receipt = dict(schemaVersion=1, version=lock['version'], inputs=lock, packages=receipts, localInputs=fingerprints,
                   dependencyOrigin='Built from pinned sources; no donor libraries',
                   entries=build.inventory(output / 'stage'), sourceInputEntries=build.inventory(inputs), fileOwners=ownership)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--fetch-only', action='store_true')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    lock = json.loads((ROOT / 'compat/wine/source-build.lock.json').read_text())
    validate_inputs(lock['inputs'])
    build.fetch({'inputs': [dict(i, name=i['archive']) for i in lock['inputs']]}, args.cache, args.offline)
    if not args.fetch_only: execute(lock, args.cache.resolve(), args.output.absolute())


if __name__ == '__main__': main()
