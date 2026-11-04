#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Run the native surround regression harness without Wine or audio devices."""
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    repository = Path(__file__).resolve().parent.parent
    inputs = repository / "compat/surround-audio"
    patch = (inputs / "winecoreaudio-surround.patch").read_text()
    with tempfile.TemporaryDirectory(prefix="macgacha-surround-tests-") as temporary:
        scratch = Path(temporary)
        for name in ("macgacha-surround.h", "macgacha-spatial.h"):
            pattern = (r"^--- /dev/null\n\+\+\+ b/dlls/winecoreaudio\.drv/"
                       + re.escape(name) + r"\n@@ -0,0 \+1,(\d+) @@\n")
            matches = list(re.finditer(pattern, patch, re.MULTILINE))
            if len(matches) != 1:
                raise ValueError(f"Expected one new-file hunk for {name}")
            match = matches[0]
            body = patch[match.end():].split("\n--- ", 1)[0].splitlines(keepends=True)
            if len(body) != int(match.group(1)) or any(not line.startswith("+") for line in body):
                raise ValueError(f"Invalid added-header hunk for {name}")
            (scratch / name).write_text("".join(line[1:] for line in body))
        binary = scratch / "test-spatial"
        subprocess.run([
            "/usr/bin/clang", "-arch", "arm64", "-Werror", "-Wall", "-Wextra",
            "-Wno-unused-parameter", "-Wno-multichar", f"-I{scratch}",
            str(inputs / "test-spatial.c"), "-o", str(binary),
        ], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == "__main__":
    main()
