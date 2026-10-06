#!/usr/bin/env python3
"""Plan, validate, publish, and verify only Play's en-US phone screenshots.

No command uploads a binary or edits notes, listing text, or another image type.
`plan` is entirely local. `check` and `validate` discard their temporary API edits.
"""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
from urllib.parse import quote


class ScreenshotError(ValueError):
    pass


def load_manifest(path):
    path = Path(path).resolve()
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("locale") != "en-US" or data.get("image_type") != "phoneScreenshots":
        raise ScreenshotError("Manifest must target en-US phoneScreenshots only")
    entries = data.get("screenshots", [])
    if not isinstance(entries, list) or not 2 <= len(entries) <= 8:
        raise ScreenshotError("Manifest needs 2–8 ordered phone screenshots")
    screenshots = []
    seen = set()
    for entry in entries:
        image_path = (path.parent / entry["path"]).resolve()
        if not image_path.is_relative_to(path.parent) or image_path.suffix != ".png":
            raise ScreenshotError("Screenshot paths must be PNG files inside the manifest directory")
        if image_path in seen:
            raise ScreenshotError("Duplicate screenshot path")
        seen.add(image_path)
        raw = image_path.read_bytes()
        if len(raw) < 33 or raw[:8] != b"\x89PNG\r\n\x1a\n" or raw[12:16] != b"IHDR":
            raise ScreenshotError(f"Invalid PNG: {image_path.name}")
        width, height, depth, color_type = struct.unpack(">IIBB", raw[16:26])
        if depth != 8 or color_type != 2:
            raise ScreenshotError(f"Use opaque 24-bit RGB PNG: {image_path.name}")
        if (width, height) != (entry.get("width"), entry.get("height")):
            raise ScreenshotError(f"Manifest dimensions differ from PNG: {image_path.name}")
        if min(width, height) < 320 or max(width, height) > 3840 or max(width, height) > 2 * min(width, height):
            raise ScreenshotError(f"Unsupported Play screenshot dimensions: {image_path.name}")
        screenshots.append({
            "path": image_path, "bytes": raw, "width": width, "height": height,
            "sha256": hashlib.sha256(raw).hexdigest(),
        })
    return screenshots


def hash_matches(remote_hash, local_hex):
    if not isinstance(remote_hash, str):
        return False
    if remote_hash.lower() == local_hex:
        return True
    digest = bytes.fromhex(local_hex)
    return remote_hash.rstrip("=") in (
        base64.b64encode(digest).decode().rstrip("="),
        base64.urlsafe_b64encode(digest).decode().rstrip("="),
    )


def same_images(images, screenshots):
    return len(images) == len(screenshots) and all(
        hash_matches(image.get("sha256"), screen["sha256"])
        for image, screen in zip(images, screenshots)
    )


def image_path(edit):
    return f"/edits/{quote(str(edit), safe='')}/listings/en-US/phoneScreenshots"


def read_images(client):
    edit = client.new_edit()
    try:
        return client.request("GET", image_path(edit)).get("images", [])
    finally:
        client.discard_edit(edit)


def publish_screenshots(client, screenshots, mode):
    """Use an isolated edit; validate before commit and verify committed hashes."""
    if mode not in ("check", "validate", "upload"):
        raise ScreenshotError("Choose check, validate, or upload")
    edit = client.new_edit()
    commit_attempted = False
    try:
        path = image_path(edit)
        before = client.request("GET", path).get("images", [])
        if same_images(before, screenshots):
            return {"status": "unchanged", "count": len(screenshots)}
        if mode == "check":
            return {"status": "different", "count": len(screenshots)}

        # Replacing this one set is contained in the uncommitted edit. Nothing
        # live changes unless every upload and validation succeeds.
        client.request("DELETE", path)
        for screen in screenshots:
            url = (
                "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
                + quote(client.package, safe="") + path + "?uploadType=media"
            )
            result = client.request_url("POST", url, body=screen["bytes"], content_type="image/png")
            if not hash_matches(result.get("image", {}).get("sha256"), screen["sha256"]):
                raise ScreenshotError("Uploaded screenshot hash was not verified")
        if not same_images(client.request("GET", path).get("images", []), screenshots):
            raise ScreenshotError("Staged screenshot hashes/order were not verified")
        client.validate_edit(edit)
        if mode == "validate":
            return {"status": "validated_only", "count": len(screenshots)}

        try:
            # The edit may be consumed even if its acknowledgement is lost.
            # Do not let a cleanup DELETE mask an uncertain commit result.
            commit_attempted = True
            client.commit_edit(edit)
        except Exception as error:
            # A lost commit acknowledgement may still mean Play saved the edit.
            # Check first, rather than repeating replacements on uncertainty.
            try:
                saved = same_images(read_images(client), screenshots)
            except Exception:
                raise ScreenshotError(f"Commit could not be verified ({error}); run check before retrying") from error
            if saved:
                return {"status": "published_verified", "count": len(screenshots)}
            raise ScreenshotError(f"Commit was not verified ({error}); run check before retrying") from error
        if not same_images(read_images(client), screenshots):
            raise ScreenshotError("Edit committed, but saved hashes/order did not match; run check before retrying")
        return {"status": "published_verified", "count": len(screenshots)}
    finally:
        if not commit_attempted:
            client.discard_edit(edit)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "check", "validate", "upload"))
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parent.parent / "design/google-play/manifest.json")
    args = parser.parse_args(argv)
    screenshots = load_manifest(args.manifest)
    if args.action == "plan":
        print(json.dumps({"locale": "en-US", "image_type": "phoneScreenshots", "screenshots": [
            {key: str(value) if isinstance(value, Path) else value for key, value in screen.items() if key != "bytes"}
            for screen in screenshots
        ]}, indent=2))
        return 0
    from store_metadata import PlayClient, load_release_environment
    load_release_environment()
    result = publish_screenshots(PlayClient(), screenshots, args.action)
    print(json.dumps(result))
    # A mismatch is an actionable result, not a success verification.
    return 2 if result["status"] == "different" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, RuntimeError) as error:
        print(f"Screenshot operation failed: {error}", file=sys.stderr)
        sys.exit(1)
