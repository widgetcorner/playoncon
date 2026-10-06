import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


SPEC = importlib.util.spec_from_file_location("store_screenshots", Path(__file__).resolve().parents[1] / "store_screenshots.py")
screens = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(screens)


def png(width=1080, height=1920, color_type=2):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    channels = 4 if color_type == 6 else 3
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff" * width * channels) * height)) + chunk(b"IEND", b"")


class FakePlay:
    package = "com.fuller.playoncon"

    def __init__(self, images=None, fail_upload=False, fail_commit=False):
        self.live = images or []
        self.edits = {}
        self.calls = []
        self.next_id = 0
        self.fail_upload = fail_upload
        self.fail_commit = fail_commit

    def new_edit(self):
        self.next_id += 1
        edit = str(self.next_id)
        self.edits[edit] = list(self.live)
        self.calls.append(("new", edit))
        return edit

    def discard_edit(self, edit):
        self.calls.append(("discard", edit))
        self.edits.pop(edit, None)

    def request(self, method, path):
        self.calls.append((method, path))
        self.assert_scope(path)
        edit = path.split("/")[2]
        if method == "GET":
            return {"images": list(self.edits[edit])}
        if method == "DELETE":
            self.edits[edit] = []
            return {}
        raise AssertionError(method)

    def assert_scope(self, path):
        if not path.endswith("/listings/en-US/phoneScreenshots"):
            raise AssertionError("Touched non-phone listing content")

    def request_url(self, method, url, body=None, content_type=None):
        self.calls.append(("upload", url))
        if self.fail_upload:
            raise screens.ScreenshotError("Upload failed")
        path = url.split("/applications/" + self.package)[1].split("?")[0]
        self.assert_scope(path)
        edit = path.split("/")[2]
        image = {"sha256": hashlib.sha256(body).hexdigest()}
        self.edits[edit].append(image)
        return {"image": image}

    def validate_edit(self, edit):
        self.calls.append(("validate", edit))

    def commit_edit(self, edit):
        self.calls.append(("commit", edit))
        self.live = self.edits.pop(edit)
        if self.fail_commit:
            raise screens.ScreenshotError("Acknowledgement lost")


class ScreenshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        data = {"locale": "en-US", "image_type": "phoneScreenshots", "screenshots": []}
        for index in range(2):
            name = f"{index}.png"
            (self.root / name).write_bytes(png(width=1080 + index))
            data["screenshots"].append({"path": name, "width": 1080 + index, "height": 1920})
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps(data))
        self.shots = screens.load_manifest(self.manifest)

    def test_plan_rejects_alpha_and_wrong_dimensions_before_any_store_call(self):
        (self.root / "0.png").write_bytes(png(color_type=6))
        with self.assertRaisesRegex(screens.ScreenshotError, "24-bit"):
            screens.load_manifest(self.manifest)
        (self.root / "0.png").write_bytes(png(width=1200))
        with self.assertRaisesRegex(screens.ScreenshotError, "dimensions"):
            screens.load_manifest(self.manifest)

    def test_validation_stages_in_order_but_never_changes_live_listing(self):
        client = FakePlay([{"sha256": "old"}])
        result = screens.publish_screenshots(client, self.shots, "validate")
        self.assertEqual("validated_only", result["status"])
        self.assertEqual([{"sha256": "old"}], client.live)
        self.assertFalse(any(call[0] == "commit" for call in client.calls))
        self.assertFalse(client.edits)

    def test_failed_upload_discards_edit_preserving_live_screenshots(self):
        client = FakePlay([{"sha256": "old"}], fail_upload=True)
        with self.assertRaises(screens.ScreenshotError):
            screens.publish_screenshots(client, self.shots, "upload")
        self.assertEqual([{"sha256": "old"}], client.live)
        self.assertFalse(client.edits)

    def test_publish_validates_and_reads_committed_state_without_touching_other_fields(self):
        client = FakePlay()
        self.assertEqual("published_verified", screens.publish_screenshots(client, self.shots, "upload")["status"])
        self.assertTrue(screens.same_images(client.live, self.shots))
        actions = [call[0] for call in client.calls]
        self.assertLess(actions.index("validate"), actions.index("commit"))
        self.assertIn("new", actions[actions.index("commit") + 1:])
        self.assertFalse(client.edits)

    def test_lost_commit_acknowledgement_checks_remote_instead_of_reuploading(self):
        client = FakePlay(fail_commit=True)
        self.assertEqual("published_verified", screens.publish_screenshots(client, self.shots, "upload")["status"])
        self.assertEqual(2, sum(call[0] == "upload" for call in client.calls))
        self.assertFalse(client.edits)

    def test_matching_hashes_skip_all_writes_and_order_changes_are_detected(self):
        images = [{"sha256": shot["sha256"]} for shot in self.shots]
        client = FakePlay(images)
        self.assertEqual("unchanged", screens.publish_screenshots(client, self.shots, "upload")["status"])
        self.assertFalse(any(call[0] in ("DELETE", "upload", "commit") for call in client.calls))
        self.assertFalse(screens.same_images(list(reversed(images)), self.shots))

    def test_review_conflict_keeps_live_images_and_reports_blocker_without_retry(self):
        class ReviewConflictPlay(FakePlay):
            def commit_edit(self, edit):
                self.calls.append(("commit", edit))
                raise ValueError("Play has changes already in review; that review was preserved")

        client = ReviewConflictPlay([{"sha256": "old"}])
        with self.assertRaisesRegex(screens.ScreenshotError, "already in review"):
            screens.publish_screenshots(client, self.shots, "upload")
        self.assertEqual([{"sha256": "old"}], client.live)
        self.assertEqual(1, sum(call[0] == "commit" for call in client.calls))


if __name__ == "__main__":
    unittest.main()
