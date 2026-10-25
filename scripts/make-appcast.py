#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Generate a single-release Sparkle feed from a signed DMG (no network access)."""
import argparse
import base64
import datetime
import email.utils
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASES = "https://github.com/deruta74/MacGacha/releases"


def decoded_base64(value: str, size: int) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, UnicodeError) as error:
        raise ValueError("Invalid base64 signing metadata") from error
    if len(decoded) != size:
        raise ValueError("Signing metadata has the wrong length")
    return decoded


def validate_public_key(key: str) -> None:
    try:
        decoded_base64(key, 32)
    except ValueError as error:
        raise ValueError("Replace SPARKLE_PUBLIC_ED_KEY with the owner's Ed25519 public key before releasing") from error


def make_appcast(release: str, build: str, length: int, signature: str, published: datetime.datetime) -> bytes:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", release):
        raise ValueError("Invalid release name")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Build number must be a positive integer")
    if length <= 0:
        raise ValueError("The DMG must not be empty")
    decoded_base64(signature, 64)
    if published.tzinfo is None:
        raise ValueError("Publication date must have a time zone")
    ET.register_namespace("sparkle", SPARKLE)
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "MacGacha Updates"
    ET.SubElement(channel, "link").text = RELEASES
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"MacGacha {release}"
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = release.split("-", 1)[0]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "27.0"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published.astimezone(datetime.timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink").text = f"{RELEASES}/tag/v{release}"
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES}/download/v{release}/MacGacha-{release}.dmg",
        "length": str(length), "type": "application/octet-stream", f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--check-public-key")
    parser.add_argument("--release")
    parser.add_argument("--build-number")
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--signature")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.self_check:
        subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("test-appcast.py"))], check=True)
        return
    if args.check_public_key is not None:
        validate_public_key(args.check_public_key)
        return
    if any(value is None for value in [args.release, args.build_number, args.dmg, args.signature, args.output]):
        parser.error("--release, --build-number, --dmg, --signature and --output are required")
    result = make_appcast(args.release, args.build_number, args.dmg.stat().st_size,
                          args.signature, datetime.datetime.now(datetime.timezone.utc))
    ET.fromstring(result)
    args.output.write_bytes(result)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: {error}")
