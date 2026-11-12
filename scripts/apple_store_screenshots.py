#!/usr/bin/env python3
"""Upload and verify iPhone, iPad and Duo screenshots on one editable iOS draft.

`plan` is local; `check` makes GET requests only. `upload` never submits a version
for review. Apple does not make screenshot uploads atomic: after a failure, run
check and inspect the receipt before explicitly replacing a partial set.

Official workflow and schemas:
https://developer.apple.com/documentation/appstoreconnectapi/uploading-assets-to-app-store-connect
https://developer.apple.com/documentation/appstoreconnectapi/app-asset-library
https://developer.apple.com/documentation/appstoreconnectapi/placing-assets-on-your-app-store-surfaces
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

from store_metadata import AppleClient, load_release_environment, split_version


class ScreenshotError(ValueError):
    pass


# ACTIVE was returned by the live API on this draft on October 6, 2026. It is
# accepted only alongside the independent parent-version/build checks below.
PLACEMENT_STATES = {"PARENT_PREPARE_FOR_SUBMISSION", "ACTIVE"}


def png_dimensions(raw):
    """Check the complete opaque RGB PNG structure, CRCs and raster length."""
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise ScreenshotError("Screenshots must be opaque 24-bit RGB PNG files.")
    offset, dimensions, compressed, ended = 8, None, bytearray(), False
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise ScreenshotError("Truncated PNG chunk.")
        length = struct.unpack(">I", raw[offset:offset + 4])[0]
        kind = raw[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(raw):
            raise ScreenshotError("Truncated PNG data.")
        value = raw[offset + 8:end - 4]
        if zlib.crc32(kind + value) & 0xFFFFFFFF != struct.unpack(">I", raw[end - 4:end])[0]:
            raise ScreenshotError("Invalid PNG checksum.")
        if dimensions is None and kind != b"IHDR":
            raise ScreenshotError("PNG must begin with its image header.")
        if kind == b"IHDR":
            if dimensions is not None or length != 13:
                raise ScreenshotError("Invalid PNG header.")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", value)
            if not (1 <= width <= 3840 and 1 <= height <= 3840) or (depth, color, compression, filtering, interlace) != (8, 2, 0, 0, 0):
                raise ScreenshotError("Use opaque, non-interlaced 24-bit RGB PNG screenshots.")
            dimensions = width, height
        elif kind == b"tRNS":
            raise ScreenshotError("Apple screenshots cannot have transparency.")
        elif kind == b"IDAT":
            compressed.extend(value)
        elif kind == b"IEND":
            if length or end != len(raw):
                raise ScreenshotError("Invalid PNG end marker.")
            ended = True
            break
        offset = end
    if not dimensions or not compressed or not ended:
        raise ScreenshotError("PNG is missing required image data.")
    width, height = dimensions
    expected = (width * 3 + 1) * height
    try:
        decoder = zlib.decompressobj()
        raster = decoder.decompress(compressed, expected + 1)
    except zlib.error as error:
        raise ScreenshotError("Invalid compressed PNG image data.") from error
    if len(raster) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ScreenshotError("PNG raster dimensions do not match its header.")
    if any(raster[row * (width * 3 + 1)] > 4 for row in range(height)):
        raise ScreenshotError("Invalid PNG row filter.")
    return dimensions


def load_manifest(path):
    path = Path(path).resolve()
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ScreenshotError("Expected screenshot manifest schema_version 1.")
    split_version(manifest.get("version", ""))
    if not re.fullmatch(r"[0-9]+", str(manifest.get("app_id", ""))):
        raise ScreenshotError("Manifest must name the exact App Store app_id.")
    if not isinstance(manifest.get("bundle_id"), str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", manifest["bundle_id"]):
        raise ScreenshotError("Manifest must name the exact bundle_id.")
    if not isinstance(manifest.get("locale"), str) or not re.fullmatch(r"[a-z]{2}(?:-[A-Za-z0-9]+)*", manifest["locale"]):
        raise ScreenshotError("Manifest must name one App Store localization.")
    sets = manifest.get("sets")
    if not isinstance(sets, list) or not sets:
        raise ScreenshotError("Manifest needs at least one ordered screenshot set.")
    seen_types, seen_files = set(), set()
    for family in sets:
        group = family.get("placement_group")
        if not isinstance(group, str) or not re.fullmatch(r"[A-Z0-9_]+", group) or group in seen_types:
            raise ScreenshotError("Use unique placement_group identifiers from Apple's current reference data.")
        seen_types.add(group)
        entries = family.get("screenshots")
        if not isinstance(entries, list) or not 1 <= len(entries) <= 10:
            raise ScreenshotError("Each Apple display type needs 1–10 ordered screenshots.")
        for entry in entries:
            relative = Path(entry["path"])
            image_path = (path.parent / relative).resolve()
            if relative.is_absolute() or not image_path.is_relative_to(path.parent) or image_path.suffix.lower() != ".png":
                raise ScreenshotError("Use relative PNG paths inside the manifest directory.")
            if image_path in seen_files:
                raise ScreenshotError("Duplicate screenshot path.")
            seen_files.add(image_path)
            raw = image_path.read_bytes()
            width, height = png_dimensions(raw)
            if (width, height) != (entry.get("width"), entry.get("height")):
                raise ScreenshotError(f"Screenshot dimensions do not match the manifest: {image_path.name}")
            entry.update({"file": image_path, "bytes": raw, "sha256": hashlib.sha256(raw).hexdigest()})
    return manifest


def resource_id(value):
    return urllib.parse.quote(str(value), safe="")


def resolve_target(client, manifest):
    marketing, build_number = split_version(manifest["version"])
    apps = client.collection("/apps?" + urllib.parse.urlencode({"filter[bundleId]": manifest["bundle_id"], "limit": 200}))
    if len(apps) != 1 or apps[0]["id"] != str(manifest["app_id"]) or apps[0].get("attributes", {}).get("bundleId") != manifest["bundle_id"]:
        raise ScreenshotError("Manifest app_id and bundle_id do not resolve to the same app.")
    versions = client.collection(f"/apps/{resource_id(manifest['app_id'])}/appStoreVersions?filter[platform]=IOS&limit=200")
    versions = [item for item in versions if item.get("attributes", {}).get("versionString") == marketing and
                item.get("attributes", {}).get("platform") == "IOS"]
    if len(versions) != 1:
        raise ScreenshotError("Expected exactly one iOS App Store version matching the manifest.")
    build = client.find_build(marketing, build_number)
    if not build:
        raise ScreenshotError("The exact manifest build must be uploaded and VALID before screenshots are placed.")
    target = {"app_id": str(manifest["app_id"]), "bundle_id": manifest["bundle_id"],
              "version": manifest["version"], "version_id": versions[0]["id"],
              "build_id": build["id"], "locale": manifest["locale"]}
    assert_editable_target(client, target)
    localizations = client.collection(f"/appStoreVersions/{resource_id(target['version_id'])}/appStoreVersionLocalizations?limit=200")
    localizations = [item for item in localizations if item.get("attributes", {}).get("locale") == manifest["locale"]]
    if len(localizations) != 1:
        raise ScreenshotError("Expected exactly one existing localization on the targeted draft.")
    target["localization_id"] = localizations[0]["id"]
    library = client.request("GET", f"/apps/{resource_id(target['app_id'])}/assetLibrary")["data"]
    if library.get("type") != "appAssetLibraries" or not library.get("id"):
        raise ScreenshotError("The exact app's Asset Library could not be resolved.")
    target["library_id"] = library["id"]
    return target


def assert_editable_target(client, target):
    version_id = resource_id(target["version_id"])
    item = client.request("GET", f"/appStoreVersions/{version_id}")["data"]
    attrs = item.get("attributes", {})
    if item.get("id") != target["version_id"] or attrs.get("versionString") != target["version"].split("+")[0] or attrs.get("platform") != "IOS":
        raise ScreenshotError("The targeted App Store version changed; no further writes are permitted.")
    if attrs.get("appStoreState") != "PREPARE_FOR_SUBMISSION":
        raise ScreenshotError("Screenshots can only target PREPARE_FOR_SUBMISSION; published or submitted versions are refused.")
    linked = client.request("GET", f"/appStoreVersions/{version_id}/relationships/build").get("data")
    if not isinstance(linked, dict) or linked.get("id") != target["build_id"]:
        raise ScreenshotError("The targeted App Store version is not linked to the exact manifest build.")


def validate_catalog(client, manifest):
    """Resolve dimensions, permitted groups and limits at runtime, including Duo."""
    data = client.request("GET", "/appAssetLibraryRefData")["data"]
    if isinstance(data, list):
        if len(data) != 1:
            raise ScreenshotError("Expected one current Apple asset reference catalog.")
        data = data[0]
    attrs = data["attributes"]
    groups = {item["placementProfileGroupId"]: item for item in attrs["placementProfileGroups"]}
    specs = {item["specId"]: item for item in attrs["imageSpecs"]}
    types = [item for item in attrs["placementTypes"] if item["placementTypeId"] == "APP_SCREENSHOT"]
    features = [item for item in attrs["features"] if item["featureId"] == "APP_STORE_VERSIONS"]
    if len(types) != 1 or len(features) != 1 or "APP_SCREENSHOTS_AND_PREVIEWS" not in types[0]["acceptsAssetCategories"]:
        raise ScreenshotError("Apple's catalog does not permit App Store screenshot placements.")
    mappings = {item["placementGroupId"]: item["specs"] for item in types[0]["specMappings"]}
    policies = [item for item in features[0]["placementPolicies"] if item["placementType"] == "APP_SCREENSHOT"]
    limits = {group: item["maxCount"] for policy in policies for item in policy["groupLimits"] for group in item["groupIds"]}
    for family in manifest["sets"]:
        group = family["placement_group"]
        if group not in groups or groups[group]["platform"] not in ("IPHONE_APP_STORE", "IPAD_APP_STORE") or group not in mappings or group not in limits:
            raise ScreenshotError("Manifest placement group is not supported for iOS screenshots in the current Apple catalog.")
        if len(family["screenshots"]) > limits[group]:
            raise ScreenshotError("Manifest exceeds Apple's current screenshot count for its placement group.")
        for screen in family["screenshots"]:
            matching = []
            for spec_id in mappings[group]:
                spec = specs.get(spec_id, {})
                dim = spec.get("dimensions", {})
                if (dim.get("minWidth") == dim.get("maxWidth") == screen["width"] and
                    dim.get("minHeight") == dim.get("maxHeight") == screen["height"] and
                    "APP_SCREENSHOT" in spec.get("compatiblePlacementTypes", []) and
                    ".png" in spec.get("fileExtensions", []) and "image/png" in spec.get("mimeTypes", []) and
                    len(screen["bytes"]) <= spec.get("maxFileSize", 0)):
                    matching.append(spec_id)
            if not matching:
                raise ScreenshotError(f"Screenshot dimensions/file type are not accepted in {group}: {screen['file'].name}")
            screen["spec_ids"] = matching


def reference_name(screen):
    # The new API has no source checksum field. This marker identifies our
    # immutable uploaded source; it is not a server-generated byte checksum.
    return "playoncon-screenshot-sha256:" + screen["sha256"]


def image_matches(image, screen):
    attrs = image.get("attributes", {})
    return (attrs.get("state") in ("PREPARE_FOR_SUBMISSION", "APPROVED") and
            attrs.get("category") == "APP_SCREENSHOTS_AND_PREVIEWS" and
            attrs.get("referenceName") == reference_name(screen) and attrs.get("fileSize") == len(screen["bytes"]) and
            attrs.get("specId") in screen["spec_ids"] and
            (attrs.get("imageAsset", {}).get("width"), attrs.get("imageAsset", {}).get("height")) == (screen["width"], screen["height"]))


def read_placements(client, target, group):
    query = urllib.parse.urlencode({"filter[placementType]": "APP_SCREENSHOT", "filter[placementGroup]": group,
                                   "sort": "placementGroupPosition", "include": "image", "limit": 200})
    placements = client.collection(f"/appStoreVersionLocalizations/{resource_id(target['localization_id'])}/placements?{query}")
    if len({item["id"] for item in placements}) != len(placements):
        raise ScreenshotError("Duplicate screenshot placement IDs returned by Apple.")
    result = []
    for placement in placements:
        attrs = placement.get("attributes", {})
        if attrs.get("placementType") != "APP_SCREENSHOT" or attrs.get("placementGroup") != group or attrs.get("state") not in PLACEMENT_STATES:
            raise ScreenshotError("Screenshot placement has an unexpected group, type or draft state.")
        image_id = placement["relationships"]["image"]["data"]["id"]
        image = client.request("GET", f"/appAssetLibraryImages/{resource_id(image_id)}")["data"]
        result.append((placement, image))
    return result


def same_placements(placements, screenshots):
    return len(placements) == len(screenshots) and matching_prefix(placements, screenshots)


def matching_prefix(placements, screenshots):
    return len(placements) <= len(screenshots) and all(image_matches(image, screen)
           for (_, image), screen in zip(placements, screenshots))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def upload_bytes(method, url, body, headers):
    """Send only Apple-provided upload headers, never an App Store JWT."""
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
            if not 200 <= response.status < 300:
                raise ScreenshotError("Screenshot byte transfer returned an unexpected status.")
            response.read(65536)
    except urllib.error.HTTPError as error:
        code = error.code
        error.close()
        raise ScreenshotError(f"Screenshot byte transfer failed (HTTP {code}); read back before retrying.") from error
    except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
        raise ScreenshotError("Screenshot byte transfer was interrupted; read back before retrying.") from error


def transfer_operations(raw, operations, transport=upload_bytes):
    if not isinstance(operations, list) or not operations:
        raise ScreenshotError("Apple reservation did not return uploadOperations.")
    parts = []
    for operation in operations:
        offset, length = operation.get("offset"), operation.get("length")
        if type(offset) is not int or type(length) is not int or offset < 0 or length <= 0 or offset + length > len(raw):
            raise ScreenshotError("Apple upload operation has an invalid byte range.")
        url, method = operation.get("url", ""), operation.get("method")
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or method not in ("PUT", "POST"):
            raise ScreenshotError("Apple upload operation must specify an HTTPS PUT or POST destination.")
        headers = {}
        for header in operation.get("requestHeaders", []):
            name, value = header.get("name"), header.get("value")
            if not isinstance(name, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or not isinstance(value, str) or "\r" in value or "\n" in value or name.lower() in {key.lower() for key in headers}:
                raise ScreenshotError("Apple upload operation contains an invalid header.")
            if name.lower() == "content-length" and value != str(length):
                raise ScreenshotError("Apple upload operation Content-Length differs from its byte range.")
            headers[name] = value
        parts.append((offset, length, method, url, headers))
    cursor = 0
    for offset, length, *_ in sorted(parts):
        if offset != cursor:
            raise ScreenshotError("Apple upload operations must cover the file once without gaps or overlaps.")
        cursor += length
    if cursor != len(raw):
        raise ScreenshotError("Apple upload operations do not cover the complete file.")
    # Keep Apple's operation sequence, even if byte ranges arrive out of order.
    for offset, length, method, url, headers in parts:
        transport(method, url, raw[offset:offset + length], headers)


def wait_complete(client, image_id, screen, timeout, sleep=time.sleep):
    deadline = time.monotonic() + timeout
    while True:
        image = client.request("GET", f"/appAssetLibraryImages/{resource_id(image_id)}")["data"]
        state = image.get("attributes", {}).get("state")
        if state in ("PREPARE_FOR_SUBMISSION", "APPROVED"):
            if not image_matches(image, screen):
                raise ScreenshotError("Processed image source marker, size, dimensions or catalog specification differs from the manifest.")
            return image
        if state == "FAILED":
            raise ScreenshotError(f"Asset Library image {image_id} is FAILED. Inspect or manually remove that failed asset before retrying; no duplicate reservation was created.")
        if time.monotonic() >= deadline:
            raise ScreenshotError("Image processing is incomplete; run check before retrying.")
        sleep(min(2, max(0, deadline - time.monotonic())))


def commit_uploaded_image(client, target, image_id, screen, timeout, sleep):
    assert_editable_target(client, target)
    try:
        client.request("PATCH", f"/appAssetLibraryImages/{resource_id(image_id)}", {"data": {
            "type": "appAssetLibraryImages", "id": image_id, "attributes": {"uploaded": True}}})
    except ValueError:
        # A lost acknowledgement can still mean success. Poll the exact asset;
        # never repeat its commit automatically.
        return wait_complete(client, image_id, screen, timeout, sleep)
    return wait_complete(client, image_id, screen, timeout, sleep)


def recover_reserved_image(client, target, candidate, screen, transport, timeout, sleep):
    """Read the existing reservation before deciding whether any write is safe."""
    image_id = candidate["id"]
    image = client.request("GET", f"/appAssetLibraryImages/{resource_id(image_id)}")["data"]
    attrs = image.get("attributes", {})
    if image.get("id") != image_id or attrs.get("referenceName") != reference_name(screen) or attrs.get("category") != "APP_SCREENSHOTS_AND_PREVIEWS" or attrs.get("fileSize") != len(screen["bytes"]):
        raise ScreenshotError(f"Existing Asset Library image {image_id} does not match the source identity; inspect it before retrying.")
    state = attrs.get("state")
    if state == "AWAITING_UPLOAD":
        if attrs.get("fileName") != screen["file"].name:
            raise ScreenshotError(f"Uncommitted Asset Library image {image_id} has a different filename; inspect it before retrying.")
        assert_editable_target(client, target)
        # Use fresh operations from the authenticated GET, never saved signed
        # URLs. Re-send precisely this bound source to this uncommitted asset.
        transfer_operations(screen["bytes"], attrs.get("uploadOperations"), transport)
        return commit_uploaded_image(client, target, image_id, screen, timeout, sleep)
    if state == "FAILED":
        raise ScreenshotError(f"Asset Library image {image_id} is FAILED. Inspect or manually remove that failed asset before retrying; no duplicate reservation was created.")
    if state not in ("UPLOAD_COMPLETE", "PREPARE_FOR_SUBMISSION", "APPROVED"):
        raise ScreenshotError(f"Asset Library image {image_id} is not ready for reuse; inspect its current state before retrying.")
    return wait_complete(client, image_id, screen, timeout, sleep)


def write_receipt(path, record):
    if path is None:
        return
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def publish_screenshots(client, manifest, mode, replace=False, receipt=None,
                        transport=upload_bytes, timeout=120, sleep=time.sleep):
    if mode not in ("check", "upload"):
        raise ScreenshotError("Choose check or upload.")
    if client.bundle_id != manifest["bundle_id"]:
        raise ScreenshotError("Configured Apple bundle ID differs from the manifest.")
    validate_catalog(client, manifest)
    target = resolve_target(client, manifest)
    planned = []
    for family in manifest["sets"]:
        placements = read_placements(client, target, family["placement_group"])
        same = same_placements(placements, family["screenshots"])
        prefix = matching_prefix(placements, family["screenshots"])
        if mode == "upload" and placements and not prefix and not replace:
            raise ScreenshotError("Targeted placements are not empty, identical or a matching ordered prefix. Run check; use --replace only with explicit replacement authorization.")
        planned.append((family, placements, same, prefix))
    record = {**target, "status": "unchanged" if all(item[2] for item in planned) else "different",
              "verification": "ordered placement/image IDs, source SHA256 reference markers, file sizes, processed dimensions and catalog specs; Apple exposes no source checksum",
              "sets": []}
    if mode == "check":
        record["sets"] = [{"placement_group": family["placement_group"], "status": "unchanged" if same else "matching_prefix" if prefix else "different",
                           "existing_count": len(placements), "expected_count": len(family["screenshots"]),
                           "placement_ids": [placement["id"] for placement, _ in placements],
                           "image_ids": [image["id"] for _, image in placements]} for family, placements, same, prefix in planned]
        write_receipt(receipt, record)
        return record
    record["status"] = "uploading"
    write_receipt(receipt, record)
    try:
        # Upload every new image before removing any explicitly replaced placement.
        # Underlying library assets are never deleted or archived by this helper.
        library_images = None
        for family, placements, same, prefix in planned:
            set_record = {"placement_group": family["placement_group"], "screenshots": []}
            record["sets"].append(set_record)
            for index, screen in enumerate(family["screenshots"]):
                assert_editable_target(client, target)
                if prefix and index < len(placements):
                    image = placements[index][1]
                else:
                    if library_images is None:
                        library_images = client.collection(f"/appAssetLibraries/{resource_id(target['library_id'])}/images?limit=200")
                    candidates = [item for item in library_images if item.get("attributes", {}).get("referenceName") == reference_name(screen)]
                    if len(candidates) > 1:
                        raise ScreenshotError("Multiple library images claim the same source marker; inspect assets before retrying.")
                    if candidates:
                        set_record["screenshots"].append({"image_id": candidates[0]["id"], "path": screen["path"],
                            "width": screen["width"], "height": screen["height"], "sha256": screen["sha256"], "status": "recovering"})
                        write_receipt(receipt, record)
                        image = recover_reserved_image(client, target, candidates[0], screen, transport, timeout, sleep)
                    else:
                        image = client.request("POST", "/appAssetLibraryImages", {"data": {
                            "type": "appAssetLibraryImages", "attributes": {
                                "fileName": screen["file"].name, "fileSize": len(screen["bytes"]),
                                "category": "APP_SCREENSHOTS_AND_PREVIEWS", "referenceName": reference_name(screen)},
                            "relationships": {"assetLibrary": {"data": {
                                "type": "appAssetLibraries", "id": target["library_id"]}}}}})["data"]
                        set_record["screenshots"].append({"image_id": image["id"], "path": screen["path"],
                            "width": screen["width"], "height": screen["height"], "sha256": screen["sha256"], "status": "reserved"})
                        write_receipt(receipt, record)
                        transfer_operations(screen["bytes"], image.get("attributes", {}).get("uploadOperations"), transport)
                        image = commit_uploaded_image(client, target, image["id"], screen, timeout, sleep)
                        library_images.append(image)
                entry = {"image_id": image["id"], "path": screen["path"], "width": screen["width"], "height": screen["height"],
                         "sha256": screen["sha256"], "spec_id": image["attributes"]["specId"], "status": "processed"}
                if prefix and index < len(placements):
                    entry["placement_id"] = placements[index][0]["id"]
                    entry["status"] = "already_placed"
                if len(set_record["screenshots"]) > index:
                    set_record["screenshots"][index] = entry
                else:
                    set_record["screenshots"].append(entry)
                write_receipt(receipt, record)
        for (family, before, same, prefix), set_record in zip(planned, record["sets"]):
            assert_editable_target(client, target)
            group = family["placement_group"]
            current = read_placements(client, target, group)
            if [item["id"] for item, _ in current] != [item["id"] for item, _ in before]:
                raise ScreenshotError("Draft placements changed during upload; no replacement was attempted. Run check.")
            if prefix and not matching_prefix(current, family["screenshots"]):
                raise ScreenshotError("The existing screenshot prefix changed during upload; no placement changes were attempted. Run check.")
            if same:
                ordered_ids = [item["id"] for item, _ in current]
            else:
                if prefix:
                    ordered_ids = [placement["id"] for placement, _ in current]
                    missing = set_record["screenshots"][len(current):]
                else:
                    for placement, _ in current:
                        assert_editable_target(client, target)
                        client.request("DELETE", f"/appAssetLibraryPlacements/{resource_id(placement['id'])}")
                    ordered_ids = []
                    missing = set_record["screenshots"]
                for entry in missing:
                    assert_editable_target(client, target)
                    placement = client.request("POST", "/appAssetLibraryPlacements", {"data": {
                        "type": "appAssetLibraryPlacements", "attributes": {"placementType": "APP_SCREENSHOT", "placementGroup": group},
                        "relationships": {"image": {"data": {"type": "appAssetLibraryImages", "id": entry["image_id"]}},
                            "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": target["localization_id"]}}}}})["data"]
                    ordered_ids.append(placement["id"])
                    entry["placement_id"] = placement["id"]
                    entry["status"] = "placed_unverified"
                    write_receipt(receipt, record)
                    attrs = placement.get("attributes", {})
                    if attrs.get("state") not in PLACEMENT_STATES or attrs.get("placementType") != "APP_SCREENSHOT" or attrs.get("placementGroup") != group:
                        raise ScreenshotError("New screenshot placement has an unexpected state, type or group; its ID was saved for readback.")
                    entry["status"] = "placed"
                    write_receipt(receipt, record)
                assert_editable_target(client, target)
                client.request("POST", "/appAssetLibraryPlacementOrderingRequests", {"data": {
                    "type": "appAssetLibraryPlacementOrderingRequests", "attributes": {"placementGroup": group},
                    "relationships": {"orderedPlacements": {"data": [{"type": "appAssetLibraryPlacements", "id": item} for item in ordered_ids]},
                        "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": target["localization_id"]}}}}})
            after = read_placements(client, target, group)
            if [item["id"] for item, _ in after] != ordered_ids or not same_placements(after, family["screenshots"]):
                raise ScreenshotError("Saved placement IDs, order, image processing or source markers do not match.")
            for entry, placement_id in zip(set_record["screenshots"], ordered_ids):
                entry["placement_id"] = placement_id
                entry["status"] = "verified"
            write_receipt(receipt, record)
        assert_editable_target(client, target)
        for family, set_record in zip(manifest["sets"], record["sets"]):
            after = read_placements(client, target, family["placement_group"])
            if [item["id"] for item, _ in after] != [entry["placement_id"] for entry in set_record["screenshots"]] or not same_placements(after, family["screenshots"]):
                raise ScreenshotError("Final draft placement readback differs from the manifest.")
        record["status"] = "uploaded_verified" if not all(item[2] for item in planned) else "unchanged"
        write_receipt(receipt, record)
        return record
    except Exception:
        record["status"] = "incomplete_check_before_retry"
        write_receipt(receipt, record)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "check", "upload"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--replace", action="store_true", help="Explicitly authorize replacement of nonempty targeted placement groups")
    parser.add_argument("--receipt", type=Path, help="Save IDs, hashes and progress without credentials or upload URLs")
    parser.add_argument("--processing-timeout", type=int, default=120)
    args = parser.parse_args(argv)
    if args.processing_timeout < 1 or args.processing_timeout > 600:
        parser.error("processing timeout must be 1–600 seconds")
    if args.replace and args.action != "upload":
        parser.error("--replace only applies to upload")
    manifest = load_manifest(args.manifest)
    if args.action == "plan":
        result = {key: value for key, value in manifest.items() if key != "sets"}
        result["sets"] = [{"placement_group": family["placement_group"], "screenshots": [
            {key: value for key, value in screen.items() if key not in ("file", "bytes")}
            for screen in family["screenshots"]]} for family in manifest["sets"]]
    else:
        load_release_environment()
        result = publish_screenshots(AppleClient(), manifest, args.action, args.replace,
                                     args.receipt, timeout=args.processing_timeout)
    print(json.dumps(result, indent=2))
    return 2 if result.get("status") == "different" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, RuntimeError) as error:
        print(f"Apple screenshot operation failed: {error}", file=sys.stderr)
        sys.exit(1)
