#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Install only digest-locked bottles into a new standalone prefix; never run brew."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run(args, check=True)


def sha256(path):
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


# GHCR currently redirects Homebrew blobs to this GitHub-owned CDN. No wildcard
# hosts: a new CDN requires an explicit reviewed policy update.
BOTTLE_HOSTS = frozenset(("ghcr.io", "pkg-containers.githubusercontent.com"))


def bottle_host(url):
    parsed = urlsplit(url)
    if (any(ord(c) <= 32 or ord(c) == 127 for c in url) or parsed.scheme != "https"
            or parsed.hostname not in BOTTLE_HOSTS or parsed.port not in (None, 443)
            or parsed.username is not None or parsed.password is not None or parsed.fragment):
        raise ValueError("Disallowed bottle download URL")
    return parsed.hostname


def download_bottle(url, destination):
    # Deliberately do not use --location: reject every Location before issuing
    # another request, not just after an arbitrary destination has been visited.
    for _ in range(6):
        host = bottle_host(url)
        args = ["/usr/bin/curl", "-q", "--proto", "=https", "--proto-redir", "=https",
                "--fail", "--retry", "3", "--silent", "--show-error", "--connect-timeout", "30",
                "--max-time", "300", "--output", str(destination),
                "--write-out", "%{http_code}\n%{url_effective}\n%{redirect_url}\n"]
        if host == "ghcr.io":
            args.extend(["-H", "Authorization: Bearer QQ=="])
        result = subprocess.run(args + [url], check=True, capture_output=True, text=True)
        fields = result.stdout.splitlines()
        if len(fields) != 3:
            raise ValueError("Invalid bottle download response")
        status, effective, redirect = fields
        bottle_host(effective)  # Validate the final effective host too.
        if status == "200":
            return
        if status not in ("301", "302", "303", "307", "308") or not redirect:
            raise ValueError("Unexpected bottle download response")
        bottle_host(redirect)
        url = redirect
    raise ValueError("Too many bottle download redirects")


def filesystem_component(component):
    # Canonical caseless comparison for case-insensitive APFS. Decompose again
    # after casefold because folding itself can introduce decomposable characters.
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", component).casefold())


def validate_bottle(archive, name, version):
    original_root = (name, version)
    root = tuple(map(filesystem_component, original_root))
    members, originals, spellings = {}, {}, {}
    for member in archive:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or path.parts[:2] != original_root:
            raise ValueError(f"{name}: unexpected bottle member")
        key = tuple(map(filesystem_component, path.parts))
        if key in members:
            raise ValueError(f"{name}: duplicate or filesystem-equivalent bottle member")
        # Include implicit directories: Folder/one and folder/two must not
        # create two spellings of one filesystem node during extraction.
        for count in range(1, len(key) + 1):
            spelling = spellings.setdefault(key[:count], path.parts[:count])
            if spelling != path.parts[:count]:
                raise ValueError(f"{name}: ambiguous filesystem-equivalent member names")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError(f"{name}: unsupported bottle member")
        if key == root and not member.isdir():
            raise ValueError(f"{name}: keg root must be a directory")
        members[key] = member
        originals[key] = path.parts
    # No extraction operation may walk through a link, including an internal
    # one. Validate the complete namespace, regardless of archive entry order.
    for path in members:
        for count in range(1, len(path)):
            ancestor = members.get(path[:count])
            if ancestor is not None and not ancestor.isdir():
                raise ValueError(f"{name}: member has a non-directory ancestor")

    def resolve(parts, active=()):
        current = []
        for index, part in enumerate(parts):
            if part in ("", "."):
                continue
            if part == "..":
                if len(current) <= len(root):
                    raise ValueError(f"{name}: link leaves its keg")
                current.pop()
            else:
                current.append(filesystem_component(part))
                if tuple(current[:len(root)]) != root[:len(current)]:
                    raise ValueError(f"{name}: link leaves its keg")
                key = tuple(current)
                entry = members.get(key)
                if entry is not None and (entry.issym() or entry.islnk()):
                    if key in active or len(active) >= 40:
                        raise ValueError(f"{name}: cyclic or excessive link chain")
                    target = PurePosixPath(entry.linkname)
                    if target.is_absolute():
                        raise ValueError(f"{name}: absolute link target")
                    base = key[:-1] if entry.issym() else ()
                    current = list(resolve(base + target.parts, active + (key,)))
                elif entry is not None and not entry.isdir() and index < len(parts) - 1:
                    raise ValueError(f"{name}: link traverses a non-directory")
        if tuple(current[:len(root)]) != root:
            raise ValueError(f"{name}: link leaves its keg")
        return tuple(current)

    links = {}
    for path, entry in members.items():
        if entry.issym() or entry.islnk():
            target = resolve(path)
            if entry.islnk() and (target not in members or not members[target].isfile()):
                raise ValueError(f"{name}: hardlink does not resolve to a regular member")
            links[path] = target
    # Validation uses only equivalent keys. Extraction keeps the one accepted
    # original spelling, including resolved hardlink targets on case-sensitive hosts.
    return ({originals[path]: entry for path, entry in members.items()},
            {originals[path]: originals.get(target, target) for path, target in links.items()})


def extract_bottle(archive, destination, name, version):
    members, links = validate_bottle(archive, name, version)
    package = destination / name
    if destination.is_symlink() or not destination.is_dir() or package.exists() or package.is_symlink():
        raise ValueError("Bottle extraction requires a fresh package directory")
    # Regular files/directories first, hardlinks to resolved regular files next,
    # symlinks last. Never delegate traversal to tar or extract through a link.
    for path, entry in members.items():
        output = destination.joinpath(*path)
        output.parent.mkdir(parents=True, exist_ok=True)
        if entry.isdir():
            output.mkdir(exist_ok=True)
        elif entry.isfile():
            with archive.extractfile(entry) as source, output.open("xb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
            output.chmod(entry.mode & 0o777)
    for path, entry in members.items():
        if entry.islnk():
            os.link(destination.joinpath(*links[path]), destination.joinpath(*path))
    for path, entry in members.items():
        if entry.issym():
            destination.joinpath(*path).symlink_to(entry.linkname)
    for path, entry in sorted(members.items(), key=lambda item: len(item[0]), reverse=True):
        if entry.isdir():
            destination.joinpath(*path).chmod(entry.mode & 0o777)


def install(prefix, cache):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("The locked bottles require arm64 macOS 27")
    if not platform.mac_ver()[0].startswith("27."):
        raise ValueError("The locked bottles require macOS 27")
    # Refuse existing content, including the owner's Homebrew installation.
    if prefix.is_symlink() or (prefix.exists() and (not prefix.is_dir() or any(prefix.iterdir()))):
        raise ValueError("Destination must be absent or an empty directory")
    prefix = prefix.resolve()
    prefix.parent.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    entries = checker().read_lock()
    with tempfile.TemporaryDirectory(prefix=prefix.name + ".install-", dir=prefix.parent) as temporary:
        stage = Path(temporary)
        (stage / "Cellar").mkdir()
        (stage / "opt").mkdir()
        (stage / "bin").mkdir()
        (stage / "libexec").mkdir()
        for name, (version, digest) in entries.items():
            bottle = cache / (digest + ".tar.gz")
            if not bottle.exists():
                partial = bottle.with_suffix(".download")
                try:
                    download_bottle(f"https://ghcr.io/v2/homebrew/core/{name}/blobs/sha256:{digest}", partial)
                    if sha256(partial) != digest:
                        raise ValueError(f"{name}: bottle digest mismatch")
                    partial.replace(bottle)
                finally:
                    partial.unlink(missing_ok=True)
            if sha256(bottle) != digest:
                raise ValueError(f"{name}: cached bottle digest mismatch")
            print(f"{name} {version}: SHA-256 verified", flush=True)
            with tarfile.open(bottle) as archive:
                extract_bottle(archive, stage / "Cellar", name, version)
            (stage / "opt" / name).symlink_to(f"../Cellar/{name}/{version}")

        dependencies = {name: set() for name in entries}
        for name, (version, _) in entries.items():
            for path in (stage / "Cellar" / name / version).rglob("*"):
                if path.is_symlink() or not path.is_file():
                    continue
                with path.open("rb") as stream:
                    header = stream.read(16)
                # Only host Mach-O executables/dylibs/bundles, never Windows PE or CRT objects.
                if len(header) == 16 and header[:4] == b"\xcf\xfa\xed\xfe":
                    if struct.unpack("<I", header[12:16])[0] in (2, 6, 8):
                        relocate(path, stage, name, dependencies)
                else:
                    data = path.read_bytes()
                    if b"@@HOMEBREW_" in data:
                        # Homebrew substitutes tokens in COFF/archive debug strings
                        # without adjusting their offsets. Restore the original
                        # build-prefix bytes there, as a normal bottle pour does.
                        # These are target data, not host executable/search paths.
                        root = Path("/opt/homebrew") if b"\0" in data else prefix
                        data = data.replace(b"@@HOMEBREW_CELLAR@@", os.fsencode(root / "Cellar"))
                        data = data.replace(b"@@HOMEBREW_PREFIX@@", os.fsencode(root))
                        path.chmod(path.stat().st_mode | 0o200)
                        path.write_bytes(data)
        for tool in (stage / "opt/mingw-w64/bin").iterdir():
            (stage / "bin" / tool.name).symlink_to("../opt/mingw-w64/bin/" + tool.name)
        # These wrappers are for the pinned C shim build, not a general GCC
        # installation. Explicit specs select the same pinned assembler and BFD
        # linker, bypassing absolute --with-as/--with-ld defaults (and collect2's
        # hard-coded linker). The resulting PE bytes must still match SHA256SUMS.
        for target in ("i686", "x86_64"):
            compiler = stage / "opt/mingw-w64" / f"toolchain-{target}/bin/{target}-w64-mingw32-gcc"
            specs = subprocess.check_output([str(compiler), "-dumpspecs"], text=True)
            match = re.search(r"\*invoke_as:\n(.*?)(?=\n\n)", specs, re.S)
            if match is None or match.group(1).count(" as ") != 1:
                raise ValueError("Unexpected GCC assembler spec")
            invoke = match.group(1).replace(" as ", f" shim-{target}-as ")
            (stage / "libexec" / f"{target}.specs").write_text(
                f"*invoke_as:\n{invoke}\n\n*linker:\nshim-{target}-ld\n\n")
            for tool in ("as", "ld"):
                (stage / "libexec" / f"shim-{target}-{tool}").symlink_to(
                    f"../opt/mingw-w64/toolchain-{target}/bin/{target}-w64-mingw32-{tool}")
            wrapper = stage / "bin" / f"{target}-w64-mingw32-gcc"
            wrapper.unlink()
            wrapper.write_text(
                '#!/bin/bash\n'
                '# SPDX-License-Identifier: GPL-3.0-only\n'
                '# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).\n'
                'set -euo pipefail\n'
                'prefix=$(cd "$(dirname "$0")/.." && pwd -P)\n'
                f'exec "$prefix/opt/mingw-w64/toolchain-{target}/bin/{target}-w64-mingw32-gcc" '
                f'"-B$prefix/libexec/" "-specs=$prefix/libexec/{target}.specs" "$@"\n')
            wrapper.chmod(0o755)
        metadata = {name: {"version": version, "sha256": digest,
                           "runtime_dependencies": sorted(dependencies[name])}
                    for name, (version, digest) in entries.items()}
        (stage / ".steam-shim-toolchain.json").write_text(json.dumps(metadata, indent=2) + "\n")
        checker().verify_isolated(stage, entries, check_path=False)
        # Relative Mach-O references and symlinks survive publication. No shared prefix is touched.
        if prefix.exists():
            prefix.rmdir()
        stage.rename(prefix)
    print(f"Installed locked toolchain in {prefix}\nAdd {prefix}/bin to PATH and set STEAM_SHIM_TOOLCHAIN_PREFIX={prefix}")


def relocate(path, stage, owner, dependencies):
    output = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True)
    changes = []
    for line in output.splitlines()[1:]:
        reference = line.strip().split(" (", 1)[0]
        target = None
        for root, directory in [("@@HOMEBREW_PREFIX@@/", stage), ("@@HOMEBREW_CELLAR@@/", stage / "Cellar")]:
            if reference.startswith(root):
                target = directory / reference[len(root):]
                break
        if target is None:
            if not reference.startswith(("/usr/lib/", "/System/Library/", "@loader_path/", "@rpath/")):
                raise ValueError(f"{owner}: unexpected host library reference: {reference}")
            continue
        target = target.resolve(strict=True)
        relative = target.relative_to(stage / "Cellar")
        dependency = relative.parts[0]
        if dependency not in dependencies:
            raise ValueError(f"{owner}: unpinned dependency: {dependency}")
        if dependency != owner:
            dependencies[owner].add(dependency)
        replacement = "@loader_path/" + os.path.relpath(target, path.parent)
        # A dylib's first reference is its own LC_ID_DYLIB.
        if target == path:
            changes.extend(["-id", replacement])
        else:
            changes.extend(["-change", reference, replacement])
    if changes:
        path.chmod(path.stat().st_mode | 0o200)
        run("/usr/bin/codesign", "--remove-signature", str(path))
        run("/usr/bin/install_name_tool", *changes, str(path))
        run("/usr/bin/codesign", "--force", "--sign", "-", str(path))


def checker():
    spec = importlib.util.spec_from_file_location("shim_toolchain", REPO / "scripts/check-steam-shim-toolchain.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path)
    parser.add_argument("--cache", type=Path, help="Verified download cache (defaults to PREFIX-bottles)")
    args = parser.parse_args()
    install(args.prefix, args.cache or Path(str(args.prefix) + "-bottles"))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SystemExit(f"steam-shim install: {error}")
