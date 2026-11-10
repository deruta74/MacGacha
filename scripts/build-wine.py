#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Locked, offline-capable full Wine build; never accesses installed runtimes."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import subprocess
import struct
import tarfile

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / 'compat/wine'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def verify(path, expected):
    if path.is_symlink() or not path.is_file() or sha(path) != expected:
        raise ValueError(f'input checksum mismatch: {path.name}')


def inside(path, root):
    return path.resolve().is_relative_to(root.resolve())


def extract(source, destination, select=lambda name: True):
    """Reject escaping names, special files and symlink parents before writing."""
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(source) as t:
        members = []
        for m in t:
            m.name = str(PurePosixPath(m.name))
            if select(m.name): members.append(m)
        names = set()
        for m in members:
            name = PurePosixPath(m.name)
            if name.is_absolute() or '..' in name.parts or m.name in names:
                raise ValueError(f'unsafe archive path: {m.name}')
            names.add(m.name)
            if not (m.isfile() or m.isdir() or m.issym()):
                raise ValueError(f'unsupported archive entry: {m.name}')
            if m.issym() and (os.path.isabs(m.linkname) or not inside(destination / m.name / '..' / m.linkname, destination)):
                raise ValueError(f'escaping archive symlink: {m.name}')
        links = {PurePosixPath(m.name) for m in members if m.issym()}
        for m in members:
            if any(p in links for p in PurePosixPath(m.name).parents):
                raise ValueError(f'archive entry under symlink: {m.name}')
            p = destination / m.name
            if m.isdir(): p.mkdir(parents=True, exist_ok=True)
            elif m.isfile():
                p.parent.mkdir(parents=True, exist_ok=True)
                with t.extractfile(m) as src, p.open('xb') as dst: shutil.copyfileobj(src, dst)
                p.chmod(0o755 if m.mode & 0o111 else 0o644)
                os.utime(p, (m.mtime, m.mtime))
        for m in members:
            if m.issym():
                p = destination / m.name; p.parent.mkdir(parents=True, exist_ok=True); p.symlink_to(m.linkname)
    inventory(destination)


def inventory(root):
    entries = {}
    for p in sorted(root.rglob('*')):
        name = p.relative_to(root).as_posix()
        if p.is_symlink():
            if not inside(p, root) or not p.exists(): raise ValueError(f'unsafe runtime symlink: {name}')
            entries[name] = {'target': os.readlink(p)}
        elif p.is_file(): entries[name] = {'sha256': sha(p), 'executable': bool(p.stat().st_mode & 0o111)}
        elif not p.is_dir(): raise ValueError(f'unsupported runtime entry: {name}')
    return entries


def verify_pe(path, architecture):
    with path.open('rb') as f: data = f.read(1024 * 1024)
    if len(data) < 64 or data[:2] != b'MZ': raise ValueError('truncated or invalid DOS header: ' + str(path))
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    if offset < 64 or offset + 26 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError('truncated or invalid PE header: ' + str(path))
    machine = struct.unpack_from('<H', data, offset + 4)[0]
    optional_size = struct.unpack_from('<H', data, offset + 20)[0]
    magic = struct.unpack_from('<H', data, offset + 24)[0]
    if optional_size < 2 or offset + 24 + optional_size > len(data): raise ValueError('truncated optional header: ' + str(path))
    if (machine, magic) != {'i386': (0x14c, 0x10b), 'x86_64': (0x8664, 0x20b)}[architecture]:
        raise ValueError('PE architecture mismatch: ' + str(path))


def macho_commands(path):
    data = path.read_bytes()
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe': raise ValueError('expected own thin 64-bit Mach-O: ' + str(path))
    offset = 32; commands = {}
    count, size = struct.unpack_from('<II', data, 16)
    if 32 + size > len(data): raise ValueError('truncated Mach-O commands')
    for _ in range(count):
        if offset + 8 > 32 + size: raise ValueError('truncated Mach-O command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size: raise ValueError('invalid Mach-O command size')
        if command in (0x1b, 0x1d):
            if command in commands: raise ValueError('duplicate UUID/signature command')
            if length != (24 if command == 0x1b else 16): raise ValueError('invalid UUID/signature size')
            commands[command] = offset
        offset += length
    if offset != 32 + size or 0x1b not in commands: raise ValueError('missing Mach-O UUID or invalid command bounds')
    return commands


def normalize_macho(path, identifier):
    # Only call on fresh, private Wine build outputs, never donor/shared files.
    if path.is_symlink() or path.stat().st_nlink != 1: raise ValueError('refusing linked Mach-O')
    if 0x1d in macho_commands(path):
        subprocess.run(['/usr/bin/codesign', '--remove-signature', path], check=True, capture_output=True)
    data = bytearray(path.read_bytes()); offset = macho_commands(path)[0x1b] + 8
    data[offset:offset + 16] = bytes(16)
    uuid = bytearray(hashlib.sha256(data).digest()[:16])
    uuid[6] = (uuid[6] & 15) | 128  # UUIDv8: implementation-defined content hash.
    uuid[8] = (uuid[8] & 63) | 128
    data[offset:offset + 16] = uuid
    path.write_bytes(data)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--identifier', identifier, path], check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', path], check=True, capture_output=True)


def archive(tree, output):
    inventory(tree)
    with tarfile.open(output, 'x:xz', format=tarfile.PAX_FORMAT) as t:
        for p in [tree, *sorted(tree.rglob('*'))]:
            info = t.gettarinfo(str(p), arcname=(Path(tree.name) / p.relative_to(tree)).as_posix())
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''; info.pax_headers = {}
            info.mode = 0o755 if p.is_dir() or info.mode & 0o111 else 0o644
            if info.isfile():
                with p.open('rb') as f: t.addfile(info, f)
            else: t.addfile(info)


def run(args, cwd=None, env=None, log=None):
    print('Running:', args[0], args[1] if len(args) > 1 else '', flush=True)
    if log:
        with log.open('w') as f: subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    else: subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def fetch(lock, cache, offline):
    cache.mkdir(parents=True, exist_ok=True)
    for item in lock['inputs']:
        p = cache / item['name']
        if not p.exists() and not p.is_symlink() and not offline:
            part = p.with_suffix(p.suffix + '.part')
            if part.exists() or part.is_symlink(): raise ValueError(f'remove incomplete download first: {part}')
            run(['/usr/bin/curl', '-q', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https', '--retry', '3', item['url'], '-o', part])
            verify(part, item['sha256']); part.rename(p)
        verify(p, item['sha256'])


def tool_environment(deployment):
    env = {k: os.environ[k] for k in ('HOME', 'TMPDIR') if k in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', CC='/usr/bin/clang', CXX='/usr/bin/clang++',
               CONFIG_SITE='/dev/null', MACOSX_DEPLOYMENT_TARGET=deployment, LC_ALL='C', TZ='UTC',
               SOURCE_DATE_EPOCH='0', ZERO_AR_DATE='1')
    env['SDKROOT'] = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    return env


def prepare(lock, cache, work, bison):
    extract(cache / 'wine-source.tar.gz', work / 'source-archive')
    source, = (work / 'source-archive').iterdir()
    extract(cache / 'llvm-mingw.tar.xz', work / 'mingw-archive')
    mingw, = (work / 'mingw-archive').iterdir()
    extract(cache / 'pkgconf.tar.xz', work / 'pkgconf-archive')
    pkgsrc, = (work / 'pkgconf-archive').iterdir()
    tools = work / 'tools'
    tool_env = tool_environment(lock['deploymentTarget'])
    run([pkgsrc / 'configure', '--prefix=' + str(tools)], cwd=pkgsrc, env=tool_env, log=work / 'pkgconf-configure.log')
    run(['/usr/bin/make', '-j4', 'install'], cwd=pkgsrc, env=tool_env, log=work / 'pkgconf-build.log')
    # Select open-source dependency files only; no Apple framework/graphics payload.
    extract(cache / 'dependency-donor.tar.xz', work / 'donor', lambda n: n.startswith('wine/lib/GStreamer.framework/') or (n.startswith('wine/lib/') and '/' not in n[len('wine/lib/'):] and n.endswith('.dylib')))
    libraries = work / 'donor/wine/lib'
    deps = work / 'headers'; deps.mkdir()
    for item in lock['inputs']:
        if item.get('kind') != 'headers': continue
        dest = deps / item['name']
        extract(cache / item['name'], dest, lambda n: n.startswith(('opt/local/include/', 'opt/local/lib/pkgconfig/', 'opt/local/share/pkgconfig/')))
        shutil.copytree(dest / 'opt/local', work / 'devel', dirs_exist_ok=True, symlinks=True)
    framework = libraries / 'GStreamer.framework/Versions/1.0'
    # pkgutil expands signed payloads; it does not run installer scripts.
    run(['/usr/sbin/pkgutil', '--expand-full', cache / 'gstreamer-devel.pkg', work / 'gst-sdk'], log=work / 'gst-expand.log')
    for payload in sorted((work / 'gst-sdk').glob('*/Payload')):
        for rel in ['include', 'lib/pkgconfig', 'share/pkgconfig', 'lib/glib-2.0/include', 'lib/gstreamer-1.0/include']:
            if (payload / rel).is_dir(): shutil.copytree(payload / rel, framework / rel, dirs_exist_ok=True, symlinks=True)
    for pc in (work / 'devel').rglob('*.pc'):
        text = pc.read_text().replace('/opt/local/lib', str(libraries)).replace('/opt/local', str(work / 'devel'))
        # Some files use ${prefix}/lib rather than the literal prefix.
        text = text.replace('libdir=${prefix}/lib', 'libdir=' + str(libraries)).replace('libdir=${exec_prefix}/lib', 'libdir=' + str(libraries))
        pc.write_text(text)
    for pc in framework.rglob('*.pc'):
        pc.write_text(pc.read_text().replace('/Library/Frameworks/GStreamer.framework/Versions/1.0', str(framework)))
    env = tool_environment(lock['deploymentTarget'])
    env.update(CC='/usr/bin/clang -arch x86_64', CXX='/usr/bin/clang++ -arch x86_64', PATH='/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL='C', TZ='UTC', SOURCE_DATE_EPOCH='0', ZERO_AR_DATE='1',
               WINE_MINGW_ROOT=str(mingw), WINE_MINGW_CLANG=str(mingw / 'bin/clang'), WINE_BISON=str(bison),
               BISON_PKGDATADIR=str(bison.parent.parent / 'share/bison'), M4='/usr/bin/m4',
               WINE_PKG_CONFIG=str(tools / 'bin/pkgconf'), MACOSX_DEPLOYMENT_TARGET=lock['deploymentTarget'],
               WINE_SOURCE_DIR=str(source), WINE_P3_ROOT=str(work / 'build'), WINE_NATIVE_SERVER='yes', WINE_JOBS=os.environ.get('WINE_JOBS', '8'),
               CPPFLAGS=f'-I{work}/devel/include -I{framework}/include',
               LDFLAGS=f'-L{libraries} -L{framework}/lib -Wl,-rpath,{libraries} -Wl,-rpath,{framework}/lib',
               CFLAGS=f'-O2 -ffile-prefix-map={work}=. -fdebug-prefix-map={work}=.',
               CROSSCFLAGS=f'-O2 -fno-ident -mno-incremental-linker-compatible -ffile-prefix-map={work}=. -fdebug-prefix-map={work}=.',
               CROSSLDFLAGS='-Wl,/timestamp:0')
    env['PKG_CONFIG_LIBDIR'] = ':'.join(map(str, [work / 'devel/lib/pkgconfig', work / 'devel/share/pkgconfig', framework / 'lib/pkgconfig', framework / 'share/pkgconfig']))
    env['PKG_CONFIG_PATH'] = env['PKG_CONFIG_LIBDIR']
    return source, libraries, env


def local_inputs():
    files = [ROOT / 'scripts' / n for n in ['build-wine.py', 'check-wine.py', 'test-wine-build.py', 'test-dock-icon.py']]
    files += [ROOT / 'LICENSE', ROOT / 'NOTICE']
    files += [p for directory in ['compat/wine', 'compat/dock-icon'] for p in (ROOT / directory).rglob('*') if p.is_file()]
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(files)}


def build(lock, cache, output, bison):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64': raise ValueError('Apple Silicon macOS required')
    host_env = tool_environment(lock['deploymentTarget'])
    clang = subprocess.check_output(['/usr/bin/clang', '--version'], env=host_env, text=True).splitlines()[0]
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], env=host_env, text=True).strip()
    if clang != lock['clang'] or sdk != lock['sdk']: raise ValueError('locked Apple Clang/SDK mismatch')
    if subprocess.check_output([bison, '--version'], text=True).splitlines()[0] != 'bison (GNU Bison) ' + lock['bison']:
        raise ValueError('locked Bison version mismatch')
    if output.exists() or output.is_symlink(): raise ValueError('output must be absent')
    if any(c.isspace() for c in str(output)): raise ValueError('build root must not contain whitespace (upstream configure)')
    input_fingerprint = local_inputs()
    output.mkdir(parents=True)
    work = output / 'work'; work.mkdir()
    source, libraries, env = prepare(lock, cache, work, bison)
    patch = ROOT / 'compat/dock-icon/wine-bundle-icon.patch'
    verify(patch, lock['patchSha256'])
    run(['python3', '-I', ROOT / 'scripts/test-dock-icon.py', source, '--expect-legacy'], log=output / 'dock-legacy.log')
    with patch.open('rb') as f:
        subprocess.run(['/usr/bin/patch', '--batch', '--fuzz=0', '-p1', '-d', source], stdin=f, check=True)
    run(['python3', '-I', ROOT / 'scripts/test-dock-icon.py', source], log=output / 'dock-policy.log')
    # Keep upstream build mechanics, adding deterministic flags to its native-server environment.
    driver = source / 'scripts/build-wine-p3.sh'
    text = driver.read_text().replace("-O2 -g -DWINE_TUNED_X86_SERVER", f'-O2 -DWINE_TUNED_X86_SERVER -ffile-prefix-map={work}=. -fdebug-prefix-map={work}=.')
    text = text.replace('--disable-tests', '--disable-tests --disable-build-id')
    # A temporary --prefix is compiled into Wine tools; debug prefix maps do not fix it.
    # Install with DESTDIR instead, keeping the compiled prefix identical across roots.
    if text.count('\"--prefix=$host_dir\"') != 2: raise ValueError('upstream configure prefix contract changed')
    text = text.replace('\"--prefix=$host_dir\"', '--prefix=/opt/macgacha/wine')
    install = '/usr/bin/arch -x86_64 /usr/bin/make -C \"$build_dir\" install'
    if text.count(install) != 1: raise ValueError('upstream install contract changed')
    text = text.replace(install, install + ' DESTDIR=\"$root/stage\"\n    mv \"$root/stage/opt/macgacha/wine\" \"$host_dir\"')
    configure = '(cd "$target" && /usr/bin/arch "-$architecture" "$source_dir/configure" "$@")'
    if text.count(configure) != 1: raise ValueError('upstream configure invocation changed')
    # Clang's MSVC anonymous-namespace names and WIDL banners use input filenames.
    # Invoke configure relatively so those names match in independent build roots.
    relative = os.path.relpath(source / 'configure', work / 'build/build-x64')
    text = text.replace(configure, '(cd "$target" && /usr/bin/arch "-$architecture" "' + relative + '" "$@")')
    driver.write_text(text)
    # Upstream records actual source bytes via git. This local snapshot commit is not the upstream pin.
    run(['/usr/bin/git', 'init', '-q', source])
    run(['/usr/bin/git', '-C', source, 'add', '.'])
    run(['/usr/bin/git', '-C', source, '-c', 'user.name=MacGacha build', '-c', 'user.email=build@localhost', 'commit', '-qm', 'Locked source plus MacGacha build inputs'])
    run(['/bin/sh', driver, 'all'], env=env, log=output / 'build.log')
    spec = importlib.util.spec_from_file_location('stage_full', source / 'scripts/stage-full-wine-runtime.py')
    stage = importlib.util.module_from_spec(spec); spec.loader.exec_module(stage)
    config = (work / 'build/build-x64/include/config.h').read_text()
    for macro in ['HAVE_FFMPEG', 'SONAME_LIBFREETYPE', 'SONAME_LIBGNUTLS', 'SONAME_LIBSDL2']:
        if '#define ' + macro + ' ' not in config: raise ValueError('required feature missing: ' + macro)
    if local_inputs() != input_fingerprint: raise ValueError('local build inputs changed during build; rerun from final inputs')
    runtime = output / 'wine'
    shutil.copytree(work / 'build/host', runtime, symlinks=True)
    stage.copy_dependencies(libraries, libraries / 'GStreamer.framework', runtime)
    changes = stage.relocate_runtime(runtime)
    (output / 'relocations.json').write_text(json.dumps(changes, indent=2) + '\n')
    (runtime / 'bin/wine').rename(runtime / 'bin/wine.real')
    shutil.copy2(INPUTS / 'wine-wrapper.sh', runtime / 'bin/wine'); (runtime / 'bin/wine').chmod(0o755)
    for name in ['COPYING.LIB', 'AUTHORS', 'NOTICES.md']: shutil.copy2(source / name, runtime / name)
    shutil.copy2(INPUTS / 'NOTICE.md', runtime / 'MACGACHA-NOTICE.md')
    run(['/usr/bin/lipo', '-verify_arch', 'arm64', runtime / 'bin/wineserver'])
    for name in ['bin/wine.real', 'lib/wine/x86_64-unix/ntdll.so', 'lib/wine/x86_64-unix/winemac.so']:
        run(['/usr/bin/lipo', '-verify_arch', 'x86_64', runtime / name])
    for arch in ['i386', 'x86_64']:
        for dll in ['ntdll.dll', 'kernel32.dll', 'crypt32.dll', 'd3d11.dll']:
            verify_pe(runtime / f'lib/wine/{arch}-windows' / dll, arch)
    for name in ['winegstreamer.so', 'winedmo.so', 'winemac.so', 'winecoreaudio.so']:
        if not (runtime / 'lib/wine/x86_64-unix' / name).is_file(): raise ValueError('missing required module ' + name)
    for directory in [runtime / 'bin', runtime / 'lib/wine']:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink() or not path.is_file(): continue
            with path.open('rb') as f: magic = f.read(4)
            if magic == b'\xcf\xfa\xed\xfe':
                identifier = 'com.lo7ted.macgacha.wine.' + path.relative_to(runtime).as_posix().replace('/', '.')
                normalize_macho(path, identifier)
    entries = inventory(runtime)
    receipt = dict(schemaVersion=1, version=lock['version'], status='local-candidate-not-published', inputs=lock,
                   wrapperSha256=sha(INPUTS / 'wine-wrapper.sh'), localInputs=input_fingerprint, appleGraphicsIncluded=False,
                   dependencyOrigin='Pinned donor archive; reused open-source libraries, not fresh dependency builds',
                   byteReproducibility='not-yet-proven', entries=entries)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    archive(runtime, output / (lock['version'] + '.tar.xz'))
    # Corresponding build inputs are retained alongside the binary; never include private evidence.
    inputs = output / 'source-inputs'; inputs.mkdir()
    shutil.copy2(cache / 'wine-source.tar.gz', inputs / 'wine-source.tar.gz')
    shutil.copytree(INPUTS, inputs / 'compat/wine')
    shutil.copytree(ROOT / 'compat/dock-icon', inputs / 'compat/dock-icon')
    (inputs / 'scripts').mkdir()
    for name in ['build-wine.py', 'test-wine-build.py', 'test-dock-icon.py', 'check-wine.py']:
        shutil.copy2(ROOT / 'scripts' / name, inputs / 'scripts' / name)
    for name in ['LICENSE', 'NOTICE']:
        shutil.copy2(ROOT / name, inputs / name)
    if local_inputs() != input_fingerprint: raise ValueError('local build inputs changed during packaging; discard candidate')
    (output / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(output.glob('*.tar.xz'))))
    print('Candidate built:', output, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--fetch-only', action='store_true')
    parser.add_argument('--bison', type=Path, default=Path('/opt/homebrew/opt/bison/bin/bison'))
    args = parser.parse_args()
    lock = json.loads((INPUTS / 'inputs.lock.json').read_text())
    fetch(lock, args.cache.resolve(), args.offline)
    if not args.fetch_only: build(lock, args.cache.resolve(), args.output.absolute(), args.bison.resolve())

if __name__ == '__main__': main()
