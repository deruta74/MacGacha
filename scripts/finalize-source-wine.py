#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Finalize a verified source-built candidate into a new private packaging root."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def strip_and_normalize(path, identifier):
    if path.is_symlink() or path.stat().st_nlink != 1: raise ValueError('refusing shared Mach-O inode')
    if 0x1d in build.macho_commands(path):
        subprocess.run(['/usr/bin/codesign', '--remove-signature', path], check=True, capture_output=True)
    # Nettle retains N_SO/N_OSO object paths in STABS even with prefix maps.
    # Remove debug entries only; exported and ordinary local symbols remain.
    subprocess.run(['/usr/bin/strip', '-S', path], check=True, capture_output=True)
    build.normalize_macho(path, identifier)


def finalize(candidate, output):
    if output.exists() or output.is_symlink(): raise ValueError('output must be absent')
    if build.inside(output, candidate) or build.inside(candidate, output): raise ValueError('roots must be separate')
    receipt = json.loads((candidate / 'receipt.json').read_text())
    if receipt.get('dependencyOrigin') != 'Built from pinned sources; no donor libraries':
        raise ValueError('only source-built candidates may be finalized')
    if build.sha(ROOT / 'scripts/build-wine.py') != receipt['localInputs']['scripts/build-wine.py']:
        raise ValueError('build helper differs from candidate inputs')
    archive = candidate / (receipt['version'] + '.tar.xz')
    sums = {line.split()[1]: line.split()[0] for line in (candidate / 'SHA256SUMS').read_text().splitlines()}
    build.verify(archive, sums[archive.name])
    if build.inventory(candidate / 'wine') != receipt['entries']: raise ValueError('candidate receipt mismatch')
    source_entries = build.inventory(candidate / 'source-inputs')
    output.mkdir(parents=True)
    runtime = output / 'wine'
    shutil.copytree(candidate / 'wine', runtime, symlinks=True)
    stripped = []
    for path in sorted(runtime.rglob('*')):
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as f: magic = f.read(4)
        if magic != b'\xcf\xfa\xed\xfe': continue
        relative = path.relative_to(runtime).as_posix()
        strip_and_normalize(path, 'com.lo7ted.macgacha.wine.' + relative.replace('/', '.'))
        stripped.append(relative)
    shutil.copytree(candidate / 'source-inputs', output / 'source-inputs', symlinks=True)
    if build.inventory(output / 'source-inputs') != source_entries: raise ValueError('source input copy mismatch')
    script = ROOT / 'scripts/finalize-source-wine.py'
    shutil.copy2(script, output / 'source-inputs/scripts' / script.name)
    shutil.copy2(ROOT / 'scripts/test-finalize-source-wine.py', output / 'source-inputs/scripts/test-finalize-source-wine.py')
    (output / 'source-inputs/FINALIZATION.md').write_text(
        '# Final packaging\n\nRebuild the base source candidate using the retained build inputs, then run\n'
        '`python3 -I scripts/finalize-source-wine.py BASE FINAL`. This removes\n'
        'native debug tables before deterministic UUID/ad-hoc signature normalization.\n'
        'Original compiled inputs and their hashes remain in receipt.json; this is\n'
        'a packaging pass over those builds, not a new compiler invocation.\n')
    receipt['entries'] = build.inventory(runtime)
    receipt['finalization'] = dict(inputArchiveSha256=build.sha(archive), scriptSha256=build.sha(script),
                                   nativeDebugTablesRemoved=stripped, compiledInputsUnchanged=True)
    receipt['sourceInputEntries'] = build.inventory(output / 'source-inputs')
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    # Local-only link for diagnostic compiler headers/tools; excluded from packages.
    (output / 'work').symlink_to((candidate / 'work').resolve(), target_is_directory=True)
    result = output / archive.name
    build.archive(runtime, result)
    (output / 'SHA256SUMS').write_text(build.sha(result) + '  ' + result.name + '\n')
    print('Finalized source candidate:', output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    finalize(args.candidate.resolve(), args.output.absolute())


if __name__ == '__main__': main()
