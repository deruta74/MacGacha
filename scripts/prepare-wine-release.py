#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Prepare unchanged qualified Wine bytes and complete retained sources, without publishing."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
NAME = 'wine-11.20-macgacha-1.0'
QUALIFIED_SHA256 = 'c3b9d33653c6585fed36edf819e6239cae5a385f87fd4f0e2d093c848f15ec7e'
QUALIFIED_RELEASES = {
    NAME: QUALIFIED_SHA256,
    'wine-11.22-macgacha-1.0': '4daf157d0438c014ce3d9175cdf846f36ddc7f2b3514d4180ff3602b31591423',
}


def prepare(candidate, output, expected=QUALIFIED_SHA256, name=NAME):
    if not re.fullmatch(r'wine-[0-9]+(?:\.[0-9]+)*-macgacha-[0-9]+(?:\.[0-9]+)*', name):
        raise ValueError('invalid Wine release name')
    if output.exists() or output.is_symlink(): raise ValueError('output must be absent')
    receipt = json.loads((candidate / 'receipt.json').read_text())
    archive = candidate / (receipt['version'] + '.tar.xz')
    build.verify(archive, expected)
    if build.inventory(candidate / 'wine') != receipt['entries']: raise ValueError('runtime receipt mismatch')
    if build.inventory(candidate / 'source-inputs') != receipt['sourceInputEntries']:
        raise ValueError('source receipt mismatch')
    for loader in ['bin/wine', 'bin/wine.real']:
        if not (candidate / 'wine' / loader).is_file(): raise ValueError('missing Wine loader')
    for path in (candidate / 'wine').rglob('*'):
        if path.is_file() and not path.is_symlink() and receipt['version'].encode() in path.read_bytes():
            raise ValueError('candidate label embedded in runtime')
    output.mkdir(parents=True)
    shutil.copyfile(archive, output / (name + '.tar.xz'))
    with tempfile.TemporaryDirectory() as tmp:
        sources = Path(tmp) / 'sources'; sources.mkdir()
        shutil.copytree(candidate / 'source-inputs', sources / 'source-inputs', symlinks=True)
        shutil.copyfile(candidate / 'receipt.json', sources / 'receipt.json')
        (sources / 'RELEASE-MAPPING.json').write_text(json.dumps(dict(
            release=name, qualifiedVersion=receipt['version'], sha256=expected), indent=2) + '\n')
        build.archive(sources, output / (name + '-sources.tar.xz'))
    for path in sorted(output.glob('*.tar.xz')):
        (output / (path.name + '.sha256')).write_text(build.sha(path) + '  ' + path.name + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--release', choices=QUALIFIED_RELEASES, default=NAME)
    args = parser.parse_args()
    prepare(args.candidate, args.output, QUALIFIED_RELEASES[args.release], name=args.release)


if __name__ == '__main__': main()
