#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Inventory exact candidate dependencies; never certify source completeness."""
import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('wine_build', ROOT / 'scripts/build-wine.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
FRAMEWORK = 'lib/GStreamer.framework/'
VERSIONS = FRAMEWORK + 'Versions/1.0/share/versions.txt'
LICENSES = FRAMEWORK + 'Versions/1.0/share/licenses/'


def safe_input(item):
    name = item['name']
    if not name or Path(name).name != name or name in ('.', '..') or '\\' in name:
        raise ValueError('unsafe recipe archive name')
    return item


def recipe_input(lock):
    if lock['schemaVersion'] != 1: raise ValueError('unsupported source lock schema')
    return safe_input(lock['recipeArchive'])


def audit(runtime, receipt, lock, cache):
    item = recipe_input(lock)
    build.verify(cache / item['name'], item['sha256'])
    sources = [safe_input(s) for s in lock.get('sourceArchives', [])]
    for source in sources: build.verify(cache / source['name'], source['sha256'])
    if receipt['schemaVersion'] != 1: raise ValueError('unsupported receipt schema')
    entries = build.inventory(runtime)
    if entries != receipt['entries']: raise ValueError('runtime differs from receipt')
    if VERSIONS not in entries: raise ValueError('missing framework versions metadata')
    versions = {}
    for line in (runtime / VERSIONS).read_text().splitlines():
        fields = line.split()
        if len(fields) != 2 or fields[0] in versions: raise ValueError('ambiguous framework versions')
        versions[fields[0]] = fields[1]
    if versions.get('cerbero') != lock['cerberoVersion']:
        raise ValueError('framework Cerbero version differs from source recipe lock')
    donors = [i for i in receipt['inputs']['inputs'] if i.get('kind') == 'donor']
    if len(donors) != 1: raise ValueError('expected one pinned dependency donor')
    root = {p: e for p, e in entries.items() if p.startswith('lib/') and p.count('/') == 1}
    framework = {p: e for p, e in entries.items() if p.startswith(FRAMEWORK)}
    licenses = sorted({p[len(LICENSES):].split('/')[0] for p in framework if p.startswith(LICENSES)})
    return {
        'schemaVersion': 1, 'candidateVersion': receipt['version'],
        'sourceDeliveryComplete': False,
        'scope': 'Dependency source preparation only; not a release authorization',
        'donor': donors[0], 'recipeArchive': item,
        'verifiedSourceArchives': sources,
        'unresolvedRootLibraries': root,
        'framework': {
            'reportedVersions': versions, 'licenseDirectories': licenses, 'entries': framework,
            'evidenceLimit': 'versions.txt includes build tools and packages absent from this runtime. '
                             'License directories do not establish binary membership or build configuration.'},
        'blockers': [
            'Root donor libraries need exact source, patches, build recipes and license attribution; '
            'development header versions are not evidence of binary versions.',
            'Only the listed source archives are retained. Remaining Cerbero sources and exact build '
            'configuration are not delivered or proven to correspond to the donor framework.',
            'Replace unproven donor dependencies with source-built inputs, then rebuild and requalify Wine.'],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--fetch', action='store_true', help='Fetch pinned recipe archive before offline audit')
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink(): raise ValueError('output must be absent')
    lock = json.loads((ROOT / 'compat/wine/dependency-sources.lock.json').read_text())
    item = recipe_input(lock)
    sources = [safe_input(s) for s in lock.get('sourceArchives', [])]
    build.fetch({'inputs': [item, *sources]}, args.cache, offline=not args.fetch)
    receipt = json.loads((args.candidate / 'receipt.json').read_text())
    report = audit(args.candidate / 'wine', receipt, lock, args.cache)
    with args.output.open('x') as f: f.write(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(f"Audited {len(report['unresolvedRootLibraries'])} root library entries and "
          f"{len(report['framework']['entries'])} framework entries; source delivery remains incomplete.")


if __name__ == '__main__': main()
