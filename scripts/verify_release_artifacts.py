#!/usr/bin/env python3
"""Verify the exact release artifact's embedded identity and version, no SDK needed.

AAB protobuf fields follow AOSP tools/aapt2/Resources.proto (XmlNode,
XmlElement, XmlAttribute, Item, and Primitive). An xcarchive alone is never an IPA.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError("Truncated protobuf varint in AAB manifest.")
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, offset
    raise ValueError("Invalid protobuf varint in AAB manifest.")


def fields(data):
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError("Invalid protobuf field in AAB manifest.")
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire == 2:
            size, offset = varint(data, offset)
            value = data[offset:offset + size]
            if len(value) != size:
                raise ValueError("Truncated protobuf field in AAB manifest.")
            offset += size
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = data[offset:offset + size]
            if len(value) != size:
                raise ValueError("Truncated protobuf field in AAB manifest.")
            offset += size
        else:
            raise ValueError("Unsupported protobuf field in AAB manifest.")
        result.setdefault(number, []).append(value)
    return result


def first(message, field, default=b""):
    return message.get(field, [default])[0]


def android_manifest(data):
    element = fields(first(fields(data), 1))
    if first(element, 3).decode() != "manifest":
        raise ValueError("AAB does not contain a root manifest element.")
    attrs = {}
    for value in element.get(4, []):
        attr = fields(value)
        namespace = first(attr, 1).decode()
        name = first(attr, 2).decode()
        raw = first(attr, 3).decode()
        if not raw and 6 in attr:
            item = fields(first(attr, 6))
            if 2 in item or 3 in item:
                raw = first(fields(first(item, 2, first(item, 3))), 1).decode()
            elif 7 in item:
                primitive = fields(first(item, 7))
                raw = str(first(primitive, 6, first(primitive, 7, 0)))
        attrs[(namespace, name)] = raw
    ns = "http://schemas.android.com/apk/res/android"
    return {"id": attrs.get(("", "package")), "marketing": attrs.get((ns, "versionName")), "build": attrs.get((ns, "versionCode"))}


def inspect_artifact(path, platform):
    with zipfile.ZipFile(path) as archive:
        if platform == "ios":
            matches = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            if len(matches) != 1:
                raise ValueError("IPA must contain exactly one top-level application Info.plist.")
            info = plistlib.loads(archive.read(matches[0]))
            return {"id": info.get("CFBundleIdentifier"), "marketing": str(info.get("CFBundleShortVersionString")), "build": str(info.get("CFBundleVersion"))}
        if "base/manifest/AndroidManifest.xml" not in archive.namelist():
            raise ValueError("AAB is missing its base manifest.")
        signatures = [name for name in archive.namelist() if re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC)", name, re.IGNORECASE)]
        if not signatures:
            raise ValueError("AAB contains no release signing block.")
        return android_manifest(archive.read("base/manifest/AndroidManifest.xml"))


def verify(path, platform, version, identifier, since=None):
    if not path.is_file() or path.suffix != (".ipa" if platform == "ios" else ".aab"):
        raise ValueError(f"A real {platform} artifact file is required.")
    if since is not None and path.stat().st_mtime < since:
        raise ValueError("Artifact predates this build attempt; refusing stale output.")
    marketing, build = version.split("+", 1)
    actual = inspect_artifact(path, platform)
    expected = {"id": identifier, "marketing": marketing, "build": build}
    if actual != expected:
        raise ValueError(f"Embedded identity/version mismatch: expected {expected}, found {actual}.")
    return {"platform": platform, "artifact": str(path.resolve()), "version": version,
            "id": identifier, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "mtime": path.stat().st_mtime, "size": path.stat().st_size}


def select_fresh_ipa(directory, since):
    paths = [path for path in directory.glob("*.ipa") if path.is_file() and path.stat().st_mtime >= since]
    if len(paths) != 1:
        raise ValueError(f"Expected exactly one IPA exported during this attempt; found {len(paths)}. Check archive export before uploading.")
    return paths[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("ios", "android"))
    paths = parser.add_mutually_exclusive_group(required=True)
    paths.add_argument("--artifact", type=Path)
    paths.add_argument("--ipa-dir", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--since", type=float)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"\d+\.\d+\.\d+\+\d+", args.version):
            raise ValueError("Expected marketing.version.date+build version.")
        if args.ipa_dir and (args.platform != "ios" or args.since is None):
            raise ValueError("--ipa-dir requires ios and --since.")
        path = args.artifact or select_fresh_ipa(args.ipa_dir, args.since)
        receipt = verify(path, args.platform, args.version, args.id, args.since)
        if args.platform == "android":
            result = subprocess.run(["jarsigner", "-J-Duser.language=en", "-verify", str(path)], capture_output=True, text=True)
            if result.returncode or "jar verified." not in result.stdout:
                raise ValueError("AAB signing verification failed.")
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(receipt, indent=2))
    except (ValueError, OSError, zipfile.BadZipFile, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
