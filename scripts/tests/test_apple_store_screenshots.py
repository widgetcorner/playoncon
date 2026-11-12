import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlparse
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import apple_store_screenshots as subject


def screen(name, width, height):
    raw = (name + "-screenshot-bytes").encode()
    return {"path": name + ".png", "file": Path(name + ".png"), "width": width, "height": height,
            "bytes": raw, "sha256": hashlib.sha256(raw).hexdigest()}


def manifest():
    return {"schema_version": 1, "app_id": "123", "bundle_id": "com.fuller.playoncon", "version": "2026.10.6+28", "locale": "en-US",
            "sets": [{"placement_group": "PHONE_FROM_CATALOG", "screenshots": [screen("phone", 1206, 2622)]},
                     {"placement_group": "IPAD_FROM_CATALOG", "screenshots": [screen("ipad", 2064, 2752)]},
                     {"placement_group": "IPHONE_DUO_PROFILE", "screenshots": [screen("outer", 1398, 2034), screen("inner", 2007, 2853)]}]}


class FakeApple:
    bundle_id = "com.fuller.playoncon"

    def __init__(self, source=None):
        self.source = source or manifest()
        self.version_state = "PREPARE_FOR_SUBMISSION"
        self.linked_build = "build28"
        self.events, self.images, self.placements, self.bytes = [], {}, {}, {}
        self.lost_commit_ack = False
        self.bad_spec = False
        self.fail_placement_at = None
        self.placement_state = "PARENT_PREPARE_FOR_SUBMISSION"
        self.stale_library_operations = False
        self.specs = {}
        self.by_filename = {item["file"].name: item for family in self.source["sets"] for item in family["screenshots"]}
        profiles, mappings, specs, limits = [], [], [], []
        for family in self.source["sets"]:
            group = family["placement_group"]
            profiles.append({"placementProfileGroupId": group, "platform": "IPAD_APP_STORE" if "IPAD" in group else "IPHONE_APP_STORE"})
            ids = []
            for item in family["screenshots"]:
                spec_id = f"spec-{item['width']}-{item['height']}"
                ids.append(spec_id)
                self.specs[item["file"].name] = spec_id
                specs.append({"specId": spec_id, "dimensions": {"minWidth": item["width"], "maxWidth": item["width"], "minHeight": item["height"], "maxHeight": item["height"]},
                              "compatiblePlacementTypes": ["APP_SCREENSHOT"], "fileExtensions": [".png"], "mimeTypes": ["image/png"], "maxFileSize": 999999})
            mappings.append({"placementGroupId": group, "specs": ids})
            limits.append({"groupIds": [group], "maxCount": 10})
        self.catalog = {"data": [{"type": "appAssetLibraryRefData", "id": "1", "attributes": {
            "placementProfileGroups": profiles, "imageSpecs": specs,
            "features": [{"featureId": "APP_STORE_VERSIONS", "placementPolicies": [{"placementType": "APP_SCREENSHOT", "groupLimits": limits}]}],
            "placementTypes": [{"placementTypeId": "APP_SCREENSHOT", "acceptsAssetCategories": ["APP_SCREENSHOTS_AND_PREVIEWS"], "specMappings": mappings}]}}]}

    def find_build(self, marketing, build):
        assert (marketing, build) == ("2026.10.6", "28")
        return {"id": "build28"}

    def collection(self, path):
        self.events.append(("GET", path, None))
        parsed, query = urlparse(path), parse_qs(urlparse(path).query)
        if parsed.path == "/apps":
            return [{"id": "123", "attributes": {"bundleId": self.bundle_id}}]
        if parsed.path == "/apps/123/appStoreVersions":
            return [{"id": "draft", "attributes": {"platform": "IOS", "versionString": "2026.10.6"}},
                    {"id": "published", "attributes": {"platform": "IOS", "versionString": "2026.7.4"}}]
        if parsed.path == "/appStoreVersions/draft/appStoreVersionLocalizations":
            return [{"id": "en", "attributes": {"locale": "en-US"}}, {"id": "fr", "attributes": {"locale": "fr-FR"}}]
        if parsed.path == "/appAssetLibraries/library/images":
            images = copy.deepcopy(list(self.images.values()))
            if self.stale_library_operations:
                for image in images: image["attributes"]["uploadOperations"] = []
            return images
        if parsed.path == "/appStoreVersionLocalizations/en/placements":
            assert query["filter[placementType]"] == ["APP_SCREENSHOT"]
            assert query["sort"] == ["placementGroupPosition"]
            assert query["include"] == ["image"]
            return copy.deepcopy(self.placements.get(query["filter[placementGroup]"][0], []))
        raise AssertionError(path)

    def request(self, method, path, payload=None):
        self.events.append((method, path, copy.deepcopy(payload)))
        if (method, path) == ("GET", "/appAssetLibraryRefData"):
            return copy.deepcopy(self.catalog)
        if (method, path) == ("GET", "/appStoreVersions/draft"):
            return {"data": {"id": "draft", "attributes": {"platform": "IOS", "versionString": "2026.10.6", "appStoreState": self.version_state}}}
        if (method, path) == ("GET", "/appStoreVersions/draft/relationships/build"):
            return {"data": {"id": self.linked_build, "type": "builds"}}
        if (method, path) == ("GET", "/apps/123/assetLibrary"):
            return {"data": {"id": "library", "type": "appAssetLibraries"}}
        if path.startswith("/appAssetLibraryImages/"):
            image_id = path.rsplit("/", 1)[1]
            if method == "PATCH":
                assert payload["data"]["attributes"] == {"uploaded": True}
                item = self.images[image_id]
                screen = self.by_filename[item["attributes"]["fileName"]]
                assert self.bytes[image_id] == screen["bytes"]
                item["attributes"].update({"state": "PREPARE_FOR_SUBMISSION", "specId": "wrong" if self.bad_spec else self.specs[screen["file"].name],
                    "imageAsset": {"width": screen["width"], "height": screen["height"]}})
                if self.lost_commit_ack:
                    self.lost_commit_ack = False
                    raise ValueError("Simulated lost acknowledgement")
            return {"data": copy.deepcopy(self.images[image_id])}
        if (method, path) == ("POST", "/appAssetLibraryImages"):
            data = payload["data"]
            assert data["relationships"]["assetLibrary"]["data"] == {"type": "appAssetLibraries", "id": "library"}
            image_id = "image" + str(len(self.images) + 1)
            attrs = copy.deepcopy(data["attributes"])
            attrs["state"] = "AWAITING_UPLOAD"
            length = attrs["fileSize"]
            midpoint = length // 2
            attrs["uploadOperations"] = [{"method": "PUT", "url": f"https://store.blobstore.apple.com/{image_id}/{offset}",
                "offset": offset, "length": count, "requestHeaders": [{"name": "Content-Type", "value": "image/png"}, {"name": "X-Part", "value": str(offset)}]}
                for offset, count in ((0, midpoint), (midpoint, length - midpoint))]
            self.images[image_id] = {"type": "appAssetLibraryImages", "id": image_id, "attributes": attrs}
            self.bytes[image_id] = b""
            return {"data": copy.deepcopy(self.images[image_id])}
        if (method, path) == ("POST", "/appAssetLibraryPlacements"):
            if self.fail_placement_at == sum(len(items) for items in self.placements.values()):
                raise ValueError("Simulated placement failure")
            data = copy.deepcopy(payload["data"])
            assert data["relationships"]["appStoreVersionLocalization"]["data"] == {"type": "appStoreVersionLocalizations", "id": "en"}
            group = data["attributes"]["placementGroup"]
            data["id"] = "placement" + str(sum(len(items) for items in self.placements.values()) + 1)
            data["attributes"]["state"] = self.placement_state
            self.placements.setdefault(group, []).insert(0, data)  # Require explicit ordering, not creation-order assumptions.
            return {"data": copy.deepcopy(data)}
        if (method, path) == ("POST", "/appAssetLibraryPlacementOrderingRequests"):
            data = payload["data"]
            group = data["attributes"]["placementGroup"]
            assert data["relationships"]["appStoreVersionLocalization"]["data"]["id"] == "en"
            by_id = {item["id"]: item for item in self.placements[group]}
            ids = [item["id"] for item in data["relationships"]["orderedPlacements"]["data"]]
            assert set(ids) == set(by_id)
            self.placements[group] = [by_id[item_id] for item_id in ids]
            return {"data": {"type": "appAssetLibraryPlacementOrderingRequests", "id": "order"}}
        if method == "DELETE" and path.startswith("/appAssetLibraryPlacements/"):
            placement_id = path.rsplit("/", 1)[1]
            for group, items in self.placements.items():
                self.placements[group] = [item for item in items if item["id"] != placement_id]
            return {}
        raise AssertionError((method, path, payload))

    def transport(self, method, url, body, headers):
        assert method == "PUT"
        assert headers["Content-Type"] == "image/png"
        assert "Authorization" not in headers
        image_id, offset = urlparse(url).path.strip("/").split("/")
        assert headers["X-Part"] == offset
        offset = int(offset)
        existing = self.bytes[image_id]
        assert offset <= len(existing)
        self.bytes[image_id] = existing[:offset] + body + existing[offset + len(body):]

    def writes(self):
        return [event for event in self.events if event[0] != "GET"]


class AppleScreenshotTests(unittest.TestCase):
    def test_dynamic_catalog_duo_two_displays_and_explicit_order(self):
        source, client = manifest(), FakeApple()
        result = subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(result["status"], "uploaded_verified")
        duo = result["sets"][2]["screenshots"]
        self.assertEqual([item["path"] for item in duo], ["outer.png", "inner.png"])
        self.assertEqual([item["relationships"]["image"]["data"]["id"] for item in client.placements["IPHONE_DUO_PROFILE"]],
                         [item["image_id"] for item in duo])
        self.assertTrue(all("sourceFileChecksum" not in json.dumps(event) for event in client.writes()))
        self.assertFalse(any("appScreenshots" in event[1] or "review" in event[1].lower() for event in client.writes()))

    def test_identical_sources_and_order_repeat_without_store_writes(self):
        source, client = manifest(), FakeApple()
        subject.publish_screenshots(client, source, "upload", transport=client.transport)
        client.events.clear()
        self.assertEqual(subject.publish_screenshots(client, source, "upload", transport=client.transport)["status"], "unchanged")
        self.assertEqual(client.writes(), [])

    def test_check_uses_reads_only(self):
        client = FakeApple()
        self.assertEqual(subject.publish_screenshots(client, manifest(), "check")["status"], "different")
        self.assertEqual(client.writes(), [])

    def test_rejects_published_submitted_and_wrong_build_before_any_write(self):
        for state in ("READY_FOR_DISTRIBUTION", "WAITING_FOR_REVIEW", "IN_REVIEW"):
            client = FakeApple(); client.version_state = state
            with self.assertRaisesRegex(subject.ScreenshotError, "PREPARE_FOR_SUBMISSION"):
                subject.publish_screenshots(client, manifest(), "upload")
            self.assertEqual(client.writes(), [])
        client = FakeApple(); client.linked_build = "build27"
        with self.assertRaisesRegex(subject.ScreenshotError, "exact manifest build"):
            subject.publish_screenshots(client, manifest(), "upload")
        self.assertEqual(client.writes(), [])

    def test_nonempty_later_group_preflight_blocks_earlier_uploads(self):
        source, client = manifest(), FakeApple()
        subject.publish_screenshots(client, source, "upload", transport=client.transport)
        client.placements["PHONE_FROM_CATALOG"] = []
        client.images["image4"]["attributes"]["referenceName"] = "someone else's asset"
        client.events.clear()
        with self.assertRaisesRegex(subject.ScreenshotError, "matching ordered prefix"):
            subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(client.writes(), [])

    def test_transfer_failure_keeps_placements_and_receipt_no_urls(self):
        client = FakeApple()
        def failed_transfer(*args):
            raise subject.ScreenshotError("Interrupted byte transfer")
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            with self.assertRaisesRegex(subject.ScreenshotError, "Interrupted"):
                subject.publish_screenshots(client, manifest(), "upload", receipt=receipt, transport=failed_transfer)
            record = json.loads(receipt.read_text())
            self.assertEqual(record["status"], "incomplete_check_before_retry")
            self.assertEqual(record["sets"][0]["screenshots"][0]["status"], "reserved")
            self.assertNotIn("blobstore", receipt.read_text())
            self.assertEqual(client.placements, {})
            self.assertEqual([event[0] for event in client.writes()], ["POST"])

    def test_lost_commit_ack_reads_back_without_repeating_patch(self):
        source = manifest(); source["sets"] = source["sets"][:1]
        client = FakeApple(source); client.lost_commit_ack = True
        self.assertEqual(subject.publish_screenshots(client, source, "upload", transport=client.transport)["status"], "uploaded_verified")
        self.assertEqual(len([event for event in client.writes() if event[0] == "PATCH"]), 1)

    def test_retry_recovers_partial_reservation_with_fresh_operations(self):
        source = manifest(); source["sets"] = source["sets"][:1]
        client = FakeApple(source)
        def interrupted_after_first_part(*args):
            client.transport(*args)
            raise subject.ScreenshotError("Interrupted after receiving one part")
        with self.assertRaisesRegex(subject.ScreenshotError, "Interrupted"):
            subject.publish_screenshots(client, source, "upload", transport=interrupted_after_first_part)
        self.assertEqual(len(client.images), 1)
        self.assertEqual(client.images["image1"]["attributes"]["state"], "AWAITING_UPLOAD")
        client.events.clear()
        client.stale_library_operations = True  # Recovery must use a fresh individual GET, not this stale list.
        result = subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(result["status"], "uploaded_verified")
        self.assertEqual(len(client.images), 1)
        self.assertEqual(client.bytes["image1"], source["sets"][0]["screenshots"][0]["bytes"])
        self.assertFalse(any(event[0] == "POST" and event[1] == "/appAssetLibraryImages" for event in client.writes()))
        self.assertEqual(len([event for event in client.writes() if event[0] == "PATCH"]), 1)

    def test_failed_source_marker_reports_asset_id_without_duplicate_or_delete(self):
        source = manifest(); source["sets"] = source["sets"][:1]
        client = FakeApple(source)
        def interrupted(*args): raise subject.ScreenshotError("Interrupted")
        with self.assertRaises(subject.ScreenshotError):
            subject.publish_screenshots(client, source, "upload", transport=interrupted)
        client.images["image1"]["attributes"]["state"] = "FAILED"
        client.events.clear()
        with self.assertRaisesRegex(subject.ScreenshotError, "image1 is FAILED.*no duplicate"):
            subject.publish_screenshots(client, source, "upload", replace=True, transport=client.transport)
        self.assertEqual(client.writes(), [])
        self.assertEqual(len(client.images), 1)

    def test_uncommitted_reservation_binding_is_checked_before_recovery_transfer(self):
        for key, value in (("fileName", "other-file.png"), ("fileSize", 0), ("category", "CREATIVE_ASSETS")):
            source = manifest(); source["sets"] = source["sets"][:1]
            client = FakeApple(source)
            def interrupted(*args): raise subject.ScreenshotError("Interrupted")
            with self.assertRaises(subject.ScreenshotError):
                subject.publish_screenshots(client, source, "upload", transport=interrupted)
            client.images["image1"]["attributes"][key] = value
            client.events.clear()
            transfers = []
            with self.assertRaisesRegex(subject.ScreenshotError, "different filename|source identity"):
                subject.publish_screenshots(client, source, "upload", transport=lambda *args: transfers.append(args))
            self.assertEqual(transfers, [])
            self.assertEqual(client.writes(), [])

    def test_wrong_processed_spec_prevents_any_placement(self):
        client = FakeApple(); client.bad_spec = True
        with self.assertRaisesRegex(subject.ScreenshotError, "catalog specification"):
            subject.publish_screenshots(client, manifest(), "upload", transport=client.transport)
        self.assertEqual(client.placements, {})

    def test_draft_submission_during_transfer_stops_commit_and_placement(self):
        client = FakeApple()
        def submission_during_transfer(*args):
            client.transport(*args)
            client.version_state = "WAITING_FOR_REVIEW"
        with self.assertRaisesRegex(subject.ScreenshotError, "PREPARE_FOR_SUBMISSION"):
            subject.publish_screenshots(client, manifest(), "upload", transport=submission_during_transfer)
        self.assertFalse(any(event[0] == "PATCH" for event in client.writes()))
        self.assertEqual(client.placements, {})

    def test_manifest_app_identity_must_match_before_any_write(self):
        source, client = manifest(), FakeApple()
        source["app_id"] = "999"
        with self.assertRaisesRegex(subject.ScreenshotError, "same app"):
            subject.publish_screenshots(client, source, "upload")
        self.assertEqual(client.writes(), [])

    def test_partial_placement_failure_is_recorded_without_blind_retry(self):
        source = manifest(); source["sets"] = source["sets"][2:]
        client = FakeApple(source); client.fail_placement_at = 1
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            with self.assertRaisesRegex(ValueError, "placement failure"):
                subject.publish_screenshots(client, source, "upload", receipt=receipt, transport=client.transport)
            record = json.loads(receipt.read_text())
            self.assertEqual(record["status"], "incomplete_check_before_retry")
            self.assertIn("placement_id", record["sets"][0]["screenshots"][0])
            self.assertNotIn("placement_id", record["sets"][0]["screenshots"][1])
            self.assertEqual(len([event for event in client.writes() if event[1] == "/appAssetLibraryPlacements"]), 2)
            self.assertFalse(any(event[0] == "DELETE" for event in client.writes()))

    def test_observed_active_placements_are_verified_under_exact_draft(self):
        source, client = manifest(), FakeApple()
        client.placement_state = "ACTIVE"
        result = subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(result["status"], "uploaded_verified")
        self.assertTrue(all(item["attributes"]["state"] == "ACTIVE" for items in client.placements.values() for item in items))
        client.events.clear()
        self.assertEqual(subject.publish_screenshots(client, source, "check")["status"], "unchanged")
        self.assertEqual(client.writes(), [])
        client.version_state = "READY_FOR_DISTRIBUTION"
        with self.assertRaisesRegex(subject.ScreenshotError, "PREPARE_FOR_SUBMISSION"):
            subject.publish_screenshots(client, source, "upload")
        self.assertEqual(client.writes(), [])

    def test_matching_active_prefix_resume_keeps_ids_creates_only_missing_suffix(self):
        source = manifest(); source["sets"] = source["sets"][2:]
        client = FakeApple(source); client.placement_state = "ACTIVE"; client.fail_placement_at = 1
        with self.assertRaisesRegex(ValueError, "placement failure"):
            subject.publish_screenshots(client, source, "upload", transport=client.transport)
        kept_id = client.placements["IPHONE_DUO_PROFILE"][0]["id"]
        self.assertEqual(len(client.images), 2)
        client.events.clear(); client.fail_placement_at = None
        self.assertEqual(subject.publish_screenshots(client, source, "check")["sets"][0]["status"], "matching_prefix")
        self.assertEqual(client.writes(), [])
        result = subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(result["status"], "uploaded_verified")
        self.assertEqual(result["sets"][0]["screenshots"][0]["placement_id"], kept_id)
        self.assertEqual(client.placements["IPHONE_DUO_PROFILE"][0]["id"], kept_id)
        self.assertEqual(len(client.images), 2)
        self.assertEqual(len([event for event in client.writes() if event[1] == "/appAssetLibraryPlacements"]), 1)
        self.assertFalse(any(event[0] == "DELETE" or event[1] == "/appAssetLibraryImages" for event in client.writes()))
        self.assertTrue(any(event[1] == "/appAssetLibraryPlacementOrderingRequests" for event in client.writes()))
        client.events.clear()
        self.assertEqual(subject.publish_screenshots(client, source, "upload", transport=client.transport)["status"], "unchanged")
        self.assertEqual(client.writes(), [])

    def test_nonprefix_order_refused_without_explicit_replace(self):
        source, client = manifest(), FakeApple()
        subject.publish_screenshots(client, source, "upload", transport=client.transport)
        client.placements["IPHONE_DUO_PROFILE"].reverse()
        client.events.clear()
        with self.assertRaisesRegex(subject.ScreenshotError, "matching ordered prefix"):
            subject.publish_screenshots(client, source, "upload", transport=client.transport)
        self.assertEqual(client.writes(), [])

    def test_placement_id_saved_before_response_state_validation(self):
        source = manifest(); source["sets"] = source["sets"][:1]
        client = FakeApple(source); client.placement_state = "ASSET_PROCESSING"
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            with self.assertRaisesRegex(subject.ScreenshotError, "ID was saved"):
                subject.publish_screenshots(client, source, "upload", receipt=receipt, transport=client.transport)
            record = json.loads(receipt.read_text())
            self.assertEqual(record["status"], "incomplete_check_before_retry")
            entry = record["sets"][0]["screenshots"][0]
            self.assertEqual(entry["placement_id"], client.placements["PHONE_FROM_CATALOG"][0]["id"])
            self.assertEqual(entry["status"], "placed_unverified")
            self.assertFalse(any(event[1] == "/appAssetLibraryPlacementOrderingRequests" for event in client.writes()))

    def test_reference_data_controls_limit_and_dimensions(self):
        for change in ("limit", "dimensions", "platform"):
            client = FakeApple()
            attrs = client.catalog["data"][0]["attributes"]
            if change == "limit": attrs["features"][0]["placementPolicies"][0]["groupLimits"][2]["maxCount"] = 1
            if change == "dimensions": attrs["imageSpecs"][0]["dimensions"]["maxWidth"] = 1207
            if change == "platform": attrs["placementProfileGroups"][0]["platform"] = "MAC_APP_STORE"
            with self.assertRaises(subject.ScreenshotError):
                subject.publish_screenshots(client, manifest(), "upload")
            self.assertEqual(client.writes(), [])

    def test_replacement_removes_only_target_placements_after_processing(self):
        source, client = manifest(), FakeApple()
        subject.publish_screenshots(client, source, "upload", transport=client.transport)
        client.placements["OTHER_FAMILY"] = [{"id": "keep-other"}]
        # Change order so replacement is needed, while underlying source images remain reusable.
        client.placements["IPHONE_DUO_PROFILE"].reverse()
        client.events.clear()
        result = subject.publish_screenshots(client, source, "upload", replace=True, transport=client.transport)
        self.assertEqual(result["status"], "uploaded_verified")
        self.assertEqual(client.placements["OTHER_FAMILY"], [{"id": "keep-other"}])
        self.assertEqual(len(client.images), 4)
        self.assertTrue(all(event[1].startswith("/appAssetLibraryPlacements/") for event in client.writes() if event[0] == "DELETE"))

    def test_operation_ranges_are_checked_before_any_transfer(self):
        sent = []
        base = {"method": "PUT", "url": "https://store.blobstore.apple.com/part", "requestHeaders": []}
        for operations in ([{**base, "offset": 0, "length": 2}],
                           [{**base, "offset": 0, "length": 3}, {**base, "offset": 2, "length": 2}],
                           [{**base, "offset": True, "length": 4}],
                           [{**base, "url": "http://store.blobstore.apple.com/part", "offset": 0, "length": 4}]):
            with self.assertRaises(subject.ScreenshotError):
                subject.transfer_operations(b"data", operations, lambda *args: sent.append(args))
        self.assertEqual(sent, [])


def png(width, height, color=2, transparency=False):
    def chunk(kind, raw):
        return struct.pack(">I", len(raw)) + kind + raw + struct.pack(">I", zlib.crc32(kind + raw) & 0xffffffff)
    result = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
    if transparency: result += chunk(b"tRNS", b"\x00" * 6)
    return result + chunk(b"IDAT", zlib.compress((b"\x00" + b"\x00" * (width * 3)) * height)) + chunk(b"IEND", b"")


class ManifestTests(unittest.TestCase):
    def test_png_transparency_and_corruption_rejected(self):
        self.assertEqual(subject.png_dimensions(png(12, 20)), (12, 20))
        for raw in (png(12, 20, color=6), png(12, 20, transparency=True), png(12, 20)[:-1], png(12, 20) + b"trailing"):
            with self.assertRaises(subject.ScreenshotError): subject.png_dimensions(raw)

    def test_local_manifest_validates_actual_bytes_and_containment(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            (path.parent / "image.png").write_bytes(png(12, 20))
            source = manifest(); source["sets"] = [{"placement_group": "RUNTIME_GROUP", "screenshots": [{"path": "image.png", "width": 12, "height": 20}]}]
            path.write_text(json.dumps(source))
            loaded = subject.load_manifest(path)
            self.assertEqual(loaded["sets"][0]["screenshots"][0]["sha256"], hashlib.sha256(png(12, 20)).hexdigest())
            source["sets"][0]["screenshots"][0]["path"] = "../image.png"
            path.write_text(json.dumps(source))
            with self.assertRaisesRegex(subject.ScreenshotError, "relative PNG paths"):
                subject.load_manifest(path)


if __name__ == "__main__":
    unittest.main()
