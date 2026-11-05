#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Validate a dependency-only catalog promotion and verify new archive assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request

LIMIT = 1 << 20
HELPERS = {"jadeite", "steamShim", "crypt32Fix", "surroundAudio", "genshinFps"}
PREFIX = {"steamShim": "steam-shim", "crypt32Fix": "crypt32-fix", "surroundAudio": "surround-audio", "genshinFps": "genshin-fps-unlock"}

def require(condition, message):
    if not condition: raise ValueError(message)

def read(path):
    data = Path(path).read_bytes()
    require(len(data) <= LIMIT, "Catalog exceeds 1 MiB")
    return json.loads(data)

def indexed(items, key):
    result = {item[key]: item for item in items}
    require(len(result) == len(items), "Duplicate identity")
    return result

def https(value):
    url = urllib.parse.urlsplit(value)
    return url.scheme == "https" and bool(url.hostname) and not url.username and not url.password

def publication_state(releases):
    published = [r for r in releases if not r.get("draft", False)]
    has_asset = lambda r: any(a.get("name") == "runtime-catalog.json" for a in r.get("assets", []))
    snapshots = [(int(m[1]), r) for r in published
                 if (m := re.fullmatch(r"runtime-catalog-v1-r([0-9]+)", r.get("tag_name", "")))]
    complete = [(revision, r) for revision, r in snapshots if has_asset(r)]
    return {
        "channelHasAsset": any(r.get("tag_name") == "runtime-catalog-v1" and has_asset(r) for r in published),
        "latestCompleteSnapshot": max(complete, key=lambda pair: pair[0])[1]["tag_name"] if complete else None,
        "highestRevision": max((revision for revision, _ in snapshots), default=0),
    }

def latest_previous(candidates):
    if not candidates: return None
    greatest = max(c["revision"] for c in candidates)
    current = [c for c in candidates if c["revision"] == greatest]
    require(all(c == current[0] for c in current), "Conflicting published catalog revision")
    return current[0]

def compatible_layout(component, compiled):
    return (component["kind"] == compiled["kind"]
            and component["sourceMode"] == compiled["sourceMode"]
            and component.get("consent") == compiled.get("consent")
            and component["license"]["redistributable"] == compiled["license"]["redistributable"]
            and (component.get("rootPath") is None) == (compiled.get("rootPath") is None)
            and component.get("wineBinary") == compiled.get("wineBinary")
            and component.get("overlay", []) == compiled.get("overlay", []))

def validate(catalog, baseline, previous=None, resume_identical=False):
    require(catalog["schemaVersion"] == 1 and catalog["clientContract"] == "macgacha-runtime-v1", "Unsupported catalog contract")
    require(type(catalog["revision"]) is int and 0 < catalog["revision"] < 2**64, "Invalid revision")
    require(len(json.dumps(catalog).encode()) <= LIMIT, "Catalog exceeds 1 MiB")
    manifest = catalog["manifest"]
    require(manifest["schemaVersion"] == 3, "Unsupported manifest schema")
    components = indexed(manifest["components"], "id")
    bundles = indexed(manifest["bundles"], "id")
    require(len(components) <= 256 and len(bundles) <= 64, "Catalog count exceeds limit")
    bindings = indexed(catalog["bundleBindings"], "bundleID")
    helpers = indexed(catalog["helperBindings"], "componentID")
    baseline_bundles = indexed(baseline["bundles"], "id")
    require(set(catalog["recommendedBundles"]) == {b["backend"] for b in baseline["bundles"]}, "Incomplete bundle recommendations")
    require(set(catalog["recommendedHelpers"]) == {c["kind"] for c in baseline["components"] if c["kind"] in HELPERS}, "Incomplete helper recommendations")
    require(set(bindings) == set(bundles), "Missing bundle compatibility binding")
    require(set(helpers) == {c["id"] for c in components.values() if c["kind"] in HELPERS}, "Missing helper compatibility binding")
    for component in components.values():
        kind, version = component["kind"], component["version"]
        require(any(compatible_layout(component, c) for c in baseline["components"]), "Unsupported component layout")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version) is not None, "Unsafe version")
        require(component["id"] == PREFIX.get(kind, kind) + "-" + version, "Invalid component identity")
        require(https(component["license"]["url"]), "License URL must be HTTPS")
        if component["sourceMode"] == "download":
            digest = component["sha256"]
            require(https(component["url"]) and digest["algorithm"] == "sha256"
                    and re.fullmatch(r"[0-9a-f]{64}", digest["hex"]) is not None, "Download must have HTTPS and SHA256")
            require(component["archive"] in {"zip", "tar.gz", "tar.xz"}, "Unsupported archive format")
            require(type(component["size"]) is int and 0 < component["size"] <= 16 << 30, "Invalid archive size")
            require(type(component["installedSize"]) is int and component["installedSize"] >= 0, "Invalid installed size")
    for identity, bundle in bundles.items():
        profile = bindings[identity]["profileID"]
        require(profile in baseline_bundles, "Unknown compiled compatibility profile")
        original = baseline_bundles[profile]
        require(bundle["backend"] == original["backend"] and bundle.get("environment", {}) == original.get("environment", {}), "Profile behavior changed")
        require(all(c in components for c in bundle["components"]), "Missing bundle component")
        selected = [components[c] for c in bundle["components"]]
        expected = [next(c for c in baseline["components"] if c["id"] == i) for i in original["components"]]
        require([c["kind"] for c in selected] == [c["kind"] for c in expected], "Bundle component kinds changed")
        for component in selected:
            require(any(compatible_layout(component, c) for c in expected), "Unsupported bundle component layout")
    for identity, binding in helpers.items():
        require(binding["profileIDs"] and len(binding["profileIDs"]) <= 64
                and len(set(binding["profileIDs"])) == len(binding["profileIDs"])
                and all(p in baseline_bundles for p in binding["profileIDs"]), "Unknown helper profile")
        if components[identity]["kind"] in {"surroundAudio", "crypt32Fix"}:
            require(binding["profileIDs"] == ["d3dmetal-wine11.20-gptk4.0b3"], "ABI-specific helper profile changed")
    for backend, identity in catalog["recommendedBundles"].items():
        require(identity in bundles and bundles[identity]["backend"] == backend, "Invalid bundle recommendation")
    for kind, identity in catalog["recommendedHelpers"].items():
        require(identity in helpers and components[identity]["kind"] == kind, "Invalid helper recommendation")
    for bundle_id in catalog["recommendedBundles"].values():
        profile = bindings[bundle_id]["profileID"]
        for kind, helper_id in catalog["recommendedHelpers"].items():
            applicable = kind not in {"surroundAudio", "crypt32Fix"} or profile == "d3dmetal-wine11.20-gptk4.0b3"
            require(not applicable or profile in helpers[helper_id]["profileIDs"], "Incompatible recommended helper")
    for old in [baseline] + ([previous["manifest"]] if previous else []):
        for field, values in [("components", components), ("bundles", bundles)]:
            for item in old[field]: require(values.get(item["id"]) == item, "Historical identity removed or changed")
    if previous:
        identical_retry = resume_identical and catalog == previous
        require(catalog["revision"] > previous["revision"] or identical_retry, "Revision must increase or exactly match a published retry")
        for field, key in [("bundleBindings", "bundleID"), ("helperBindings", "componentID")]:
            current = indexed(catalog[field], key)
            for item in previous[field]: require(current.get(item[key]) == item, "Historical compatibility binding changed")

class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        require(https(newurl), "Unsafe asset redirect")
        return super().redirect_request(request, fp, code, message, headers, newurl)

def verify_assets(catalog, baseline, previous):
    known = {c["id"]: c for c in (previous["manifest"] if previous else baseline)["components"]}
    opener = urllib.request.build_opener(HTTPSRedirect())
    for component in catalog["manifest"]["components"]:
        if component["sourceMode"] != "download" or known.get(component["id"]) == component: continue
        digest, count, deadline = hashlib.sha256(), 0, time.monotonic() + 1200
        request = urllib.request.Request(component["url"], headers={"User-Agent": "MacGacha-Catalog-Validator", "Accept-Encoding": "identity"})
        with opener.open(request, timeout=30) as response:
            require(response.status == 200, "Asset request failed")
            while data := response.read(1 << 20):
                require(time.monotonic() < deadline, "Asset verification timed out")
                count += len(data)
                require(count <= component["size"], "Asset exceeds pinned size")
                digest.update(data)
        require(count == component["size"] and digest.hexdigest() == component["sha256"]["hex"], "Asset digest or size mismatch")
        print("Verified", component["id"])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--baseline", type=Path, default=Path("App/Resources/runtime-manifest.json"))
    parser.add_argument("--previous", type=Path, action="append", default=[])
    parser.add_argument("--resume-identical", action="store_true")
    parser.add_argument("--verify-assets", action="store_true")
    parser.add_argument("--publication-index", type=Path)
    args = parser.parse_args()
    catalog, baseline = read(args.catalog), read(args.baseline)
    previous = latest_previous([read(path) for path in args.previous])
    validate(catalog, baseline, previous, resume_identical=args.resume_identical)
    if args.publication_index:
        pages = json.loads(args.publication_index.read_text())
        state = publication_state([release for page in pages for release in page])
        require(catalog["revision"] >= state["highestRevision"], "A newer catalog snapshot already exists")
        print(json.dumps(state))
        return
    if args.verify_assets: verify_assets(catalog, baseline, previous)
    print("Runtime catalog validated, revision", catalog["revision"])

if __name__ == "__main__": main()
