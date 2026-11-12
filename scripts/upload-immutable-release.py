#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Attach draft assets without ever replacing an existing release asset."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def digest(handle):
    value = hashlib.sha256()
    for block in iter(lambda: handle.read(1 << 20), b""):
        value.update(block)
    return value.digest()


def upload(tag, paths):
    state = json.loads(gh("release", "view", tag, "--json", "isDraft,assets"))
    if not state["isDraft"]:
        raise ValueError("Refusing to change a published release")
    for path in map(Path, paths):
        def identical_existing():
            state = json.loads(gh("release", "view", tag, "--json", "assets"))
            if not any(asset["name"] == path.name for asset in state["assets"]):
                return False
            with tempfile.TemporaryDirectory() as directory:
                gh("release", "download", tag, "--pattern", path.name, "--dir", directory)
                existing = Path(directory) / path.name
                with path.open("rb") as local, existing.open("rb") as remote:
                    if digest(local) != digest(remote):
                        raise ValueError("Existing release asset differs: " + path.name)
            return True
        if identical_existing():
            continue
        try:
            # GitHub rejects duplicate names atomically, including publication races.
            gh("release", "upload", tag, str(path))
        except subprocess.CalledProcessError:
            if not identical_existing():
                raise


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("Usage: upload-immutable-release.py TAG FILE...")
    upload(sys.argv[1], sys.argv[2:])
