#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Verify the active Homebrew runtime closure without consulting formula APIs."""
import json
import re
import os
from pathlib import Path
import subprocess
import sys


def main():
    lock = Path(__file__).resolve().parent.parent / "compat/steam-shim/toolchain.lock"
    expected = {}
    for line in lock.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, version, digest = line.split()
        if name in expected or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid toolchain lock entry")
        expected[name] = version
    if "mingw-w64" not in expected:
        raise ValueError("Toolchain lock omits mingw-w64")

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
    pending = ["mingw-w64"]
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
