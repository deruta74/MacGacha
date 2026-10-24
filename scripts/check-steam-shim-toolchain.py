#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Verify the active Homebrew runtime closure without consulting formula APIs."""
import argparse
import json
import re
import shutil
import os
from pathlib import Path
import subprocess
import sys


def read_lock(lock=None):
    lock = lock or Path(__file__).resolve().parent.parent / "compat/steam-shim/toolchain.lock"
    expected = {}
    for line in lock.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, version, digest = line.split()
        if (name in expected or not re.fullmatch(r"[a-z0-9][a-z0-9+-]*", name)
                or not re.fullmatch(r"[0-9][a-zA-Z0-9._+-]*", version)
                or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("Invalid toolchain lock entry")
        expected[name] = (version, digest)
    if "mingw-w64" not in expected:
        raise ValueError("Toolchain lock omits mingw-w64")

    return expected


def verify_isolated(prefix, entries, check_path=True):
    """Check the extracted bottle inventory and actual host-library closure, without brew."""
    prefix = prefix.resolve(strict=True)
    metadata = json.loads((prefix / ".steam-shim-toolchain.json").read_text())
    if set(metadata) != set(entries):
        raise ValueError("Isolated bottle inventory differs from lock")
    print("Isolated bottle inventory (brew list --versions equivalent):", flush=True)
    for name, (version, digest) in sorted(entries.items()):
        print(f"{name} {version}", flush=True)
        keg = (prefix / "Cellar" / name / version).resolve(strict=True)
        if (prefix / "opt" / name).resolve(strict=True) != keg or not keg.is_relative_to(prefix):
            raise ValueError(f"{name}: active keg differs from lock")
        if metadata[name]["version"] != version or metadata[name]["sha256"] != digest:
            raise ValueError(f"{name}: installed bottle identity differs from lock")
    pending, visited = ["mingw-w64"] + (["bison"] if "bison" in entries else []), set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        if name not in entries:
            raise ValueError(f"Unpinned toolchain dependency: {name}")
        visited.add(name)
        pending.extend(metadata[name]["runtime_dependencies"])
    if visited != set(entries):
        raise ValueError("Isolated runtime closure differs from lock")
    # Prevent checking one prefix while accidentally compiling with the system keg.
    for target in ("i686", "x86_64"):
        tool = prefix / "bin" / f"{target}-w64-mingw32-gcc"
        if not tool.resolve(strict=True).is_relative_to(prefix):
            raise ValueError("Compiler leaves the isolated prefix")
        selected = shutil.which(tool.name)
        if check_path and (selected is None or Path(selected).resolve() != tool.resolve()):
            raise ValueError("PATH selects a compiler outside the isolated prefix")
    print("Active toolchain closure matches the exact bottle lock", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=os.environ.get("STEAM_SHIM_TOOLCHAIN_PREFIX"))
    parser.add_argument("--lock", type=Path, help="Alternate checked-in bottle lock (default: Steam shim)")
    args = parser.parse_args()
    entries = read_lock(args.lock)
    if args.prefix:
        verify_isolated(args.prefix, entries)
        return
    expected = {name: version for name, (version, _) in entries.items()}
    env = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_INSTALL_UPGRADE="1",
               HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK="1", HOMEBREW_NO_INSTALL_CLEANUP="1")
    prefix = Path(subprocess.check_output(["brew", "--prefix"], env=env, text=True).strip())
    names = sorted(expected)
    print("brew list --versions " + " ".join(names), flush=True)
    inventory = subprocess.check_output(["brew", "list", "--versions", *names], env=env, text=True)
    print(inventory, end="", flush=True)
    installed = {row.split()[0]: row.split()[1:] for row in inventory.splitlines()}

    # Receipts describe installed runtime dependencies, not today's mutable
    # formula definitions (which may also list unneeded source-build tools).
    pending = ["mingw-w64"] + (["bison"] if "bison" in entries else [])
    visited = set()
    active = {}
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        if name not in expected:
            raise ValueError(f"Unpinned toolchain dependency: {name}")
        visited.add(name)
        keg = (prefix / "opt" / name).resolve(strict=True)
        version = keg.name
        if keg != (prefix / "Cellar" / name / expected[name]).resolve():
            raise ValueError(f"{name}: active version {version}, expected {expected[name]}")
        if expected[name] not in installed.get(name, []):
            raise ValueError(f"{name}: pinned version missing from brew list --versions")
        receipt = json.loads((keg / "INSTALL_RECEIPT.json").read_text())
        pending.extend(d["full_name"] for d in receipt.get("runtime_dependencies", []))
        active[name] = version
    if visited != set(expected):
        raise ValueError("Toolchain closure differs from lock: " + ", ".join(sorted(set(expected) - visited)))
    print("Active toolchain closure (exact lock comparison):", flush=True)
    for name in sorted(active):
        print(f"{name} {active[name]}")
    # Unlinked historical kegs in the inventory cannot be loaded through opt/.
    # They are not part of this closure and are deliberately left untouched.


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f"steam-shim toolchain: {error}")
