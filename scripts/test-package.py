#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Run package tests with live Swift Testing events and an external hang guard."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events", required=True, type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=600)
    options, test_args = parser.parse_known_args()
    options.events.parent.mkdir(parents=True, exist_ok=True)
    options.events.unlink(missing_ok=True)
    offsets = {}
    pending = {}
    active = set()

    with tempfile.TemporaryDirectory(prefix="macgacha-tests-") as temp:
        # SwiftPM rewrites output paths for multi-product packages, then merges
        # only after tests exit. Read those per-product streams while they run.
        environment = dict(os.environ, TMPDIR=temp + "/", NSUnbufferedIO="YES")
        command = ["swift", "test", "--package-path", "Packages/LauncherKit", *test_args,
                   "--event-stream-output-path", str(options.events.resolve())]
        print("Running: " + " ".join(command), flush=True)
        process = subprocess.Popen(command, env=environment, start_new_session=True)
        deadline = time.monotonic() + options.timeout_seconds

        def events():
            paths = list(Path(temp).glob("swiftpm-test-output-*/event-stream-*.jsonl"))
            if options.events.exists():
                paths.append(options.events)
            for path in paths:
                try:
                    with path.open("rb") as stream:
                        stream.seek(offsets.get(path, 0))
                        chunk = stream.read()
                        offsets[path] = stream.tell()
                except FileNotFoundError:
                    continue  # SwiftPM may have just merged/removed the file.
                lines = (pending.get(path, b"") + chunk).split(b"\n")
                pending[path] = lines.pop()
                for line in lines:
                    record = json.loads(line)
                    if record.get("kind") != "event":
                        continue
                    event = record["payload"]
                    kind, name = event.get("kind"), event.get("testID", "")
                    if kind == "testStarted":
                        active.add(name)
                    elif kind == "testEnded":
                        active.discard(name)
                    if kind in ("testStarted", "testEnded", "issueRecorded"):
                        print(f"[live] {kind}: {name}", flush=True)
                        for message in event.get("messages", []):
                            print("[live] " + message["text"], flush=True)

        owned = {process.pid}

        def descendants():
            listing = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
            rows = [line.split(None, 2) for line in listing.splitlines()]
            children = {process.pid}
            for _ in range(8):
                children.update(int(pid) for pid, parent, _ in rows if int(parent) in children)
            return children, rows

        def terminate(pid, sig):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass

        try:
            while process.poll() is None:
                events()
                if time.monotonic() >= deadline:
                    print("Test process exceeded its deadline; active tests:", flush=True)
                    print("\n".join(sorted(active)), flush=True)
                    if sys.platform == "darwin":
                        # Preserve the exact blocked stack before killing helpers.
                        children, rows = descendants()
                        owned.update(children)
                        for pid, _, command in rows:
                            if int(pid) in children and "swiftpm-testing-helper" in command:
                                sample = options.events.with_suffix(f".sample-{pid}.txt")
                                subprocess.run(["sample", pid, "2", "-file", str(sample)],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=10)
                                print(f"Captured {sample}", flush=True)
                    raise TimeoutError("Package tests hung")
                time.sleep(0.1)
            events()
            return process.returncode
        except BaseException:
            # SwiftPM helpers can create independent process groups. Signal
            # the owned descendants directly so none retain install/store locks.
            children, _ = descendants()
            owned.update(children)
            for pid in owned - {process.pid}:
                terminate(pid, signal.SIGTERM)
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            for pid in owned - {process.pid}:
                terminate(pid, signal.SIGKILL)
            raise


if __name__ == "__main__":
    sys.exit(main())
