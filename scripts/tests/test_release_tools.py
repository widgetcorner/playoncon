"""Offline regression checks for release identity, signing gates, and notes retries."""
import copy
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


artifacts = load("verify_release_artifacts")
metadata = load("store_metadata")
preflight = load("release_preflight")


def vint(value):
    result = b""
    while value >= 128:
        result += bytes([(value & 127) | 128])
        value >>= 7
    return result + bytes([value])


def encoded(field, value):
    if isinstance(value, int):
        return vint(field << 3) + vint(value)
    if isinstance(value, str):
        value = value.encode()
    return vint((field << 3) | 2) + vint(len(value)) + value


def aab_manifest(build=28):
    ns = "http://schemas.android.com/apk/res/android"
    package = encoded(2, "package") + encoded(3, "com.fuller.playoncon")
    marketing = encoded(1, ns) + encoded(2, "versionName") + encoded(3, "2026.10.6")
    # AAPT may remove the raw value and leave only the compiled integer.
    code = encoded(1, ns) + encoded(2, "versionCode") + encoded(6, encoded(7, encoded(6, build)))
    return encoded(1, encoded(3, "manifest") + encoded(4, package) + encoded(4, marketing) + encoded(4, code))


class ArtifactTests(unittest.TestCase):
    def test_embedded_ipa_version_and_id_reject_stale_or_other_app(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Runner.app/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": "com.fuller.playoncon", "CFBundleShortVersionString": "2026.10.6", "CFBundleVersion": "28"}))
            receipt = artifacts.verify(path, "ios", "2026.10.6+28", "com.fuller.playoncon")
            self.assertEqual(receipt["artifact"], str(path.resolve()))
            with self.assertRaisesRegex(ValueError, "mismatch"):
                artifacts.verify(path, "ios", "2026.10.6+29", "com.fuller.playoncon")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                artifacts.verify(path, "ios", "2026.10.6+28", "com.other.app")
            with self.assertRaisesRegex(ValueError, "predates"):
                artifacts.verify(path, "ios", "2026.10.6+28", "com.fuller.playoncon", path.stat().st_mtime + 1)

    def test_archive_only_or_multiple_fresh_ipas_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Runner.xcarchive").mkdir()
            with self.assertRaisesRegex(ValueError, "found 0"):
                artifacts.select_fresh_ipa(root, 0)
            for name in ("one.ipa", "two.ipa"):
                (root / name).write_bytes(b"fixture")
            with self.assertRaisesRegex(ValueError, "found 2"):
                artifacts.select_fresh_ipa(root, 0)

    def test_aab_compiled_version_is_read_and_unsigned_bundle_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.aab"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("base/manifest/AndroidManifest.xml", aab_manifest())
            with self.assertRaisesRegex(ValueError, "no release signing block"):
                artifacts.verify(path, "android", "2026.10.6+28", "com.fuller.playoncon")
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("META-INF/UPLOAD.RSA", b"synthetic test signing block")
            self.assertEqual(artifacts.verify(path, "android", "2026.10.6+28", "com.fuller.playoncon")["version"], "2026.10.6+28")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                artifacts.verify(path, "android", "2026.10.6+29", "com.fuller.playoncon")

    def test_malformed_proto_fails_instead_of_hanging(self):
        for value in (b"\x80", b"\x0a\x7fabc", b"\x00"):
            with self.assertRaises(ValueError):
                artifacts.fields(value)


class SigningTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ruby"), "Ruby is required for the fastlane commit guard")
    def test_fastlane_commit_guard_stubbed_transport_without_gems_or_credentials(self):
        result = subprocess.run(["ruby", str(SCRIPTS / "tests/test_play_commit_guard.rb")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Play commit guard offline checks passed", result.stdout)

    def test_upload_preflight_fails_closed_if_installed_client_cannot_guard_reviews(self):
        with mock.patch.dict(sys.modules, {"store_metadata": metadata}), mock.patch.dict(os.environ, {"POC_PLAY_JSON_KEY": "/fixture/publisher.json"}), mock.patch.object(preflight, "require_tool"), mock.patch.object(preflight.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "")):
            with self.assertRaisesRegex(ValueError, "cannot enforce the existing-review guard"):
                preflight.upload_preflight("android")

    def test_upload_preflight_only_loads_missing_local_config_and_checks_shape(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "publisher.json"
            key.write_text(json.dumps({"type": "service_account", "client_email": "fixture@example.com", "private_key": "fixture"}))
            with mock.patch.dict(sys.modules, {"store_metadata": metadata}), mock.patch.dict(os.environ, {"POC_PLAY_JSON_KEY": str(key)}), mock.patch.object(metadata, "load_release_environment") as load_env, mock.patch.object(preflight, "require_tool") as tool, mock.patch.object(preflight.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "guard ready")):
                preflight.upload_preflight("android")
                load_env.assert_not_called()
                self.assertEqual([call.args[0] for call in tool.call_args_list], ["openssl", "fastlane", "ruby"])
                key.write_text("{}")
                with self.assertRaisesRegex(ValueError, "must contain service_account"):
                    preflight.upload_preflight("android")

    def test_invalid_ios_upload_metadata_fails_without_printing_values(self):
        with mock.patch.dict(sys.modules, {"store_metadata": metadata}), mock.patch.dict(os.environ, {"ASC_KEY_ID": "invalid-fixture", "ASC_ISSUER_ID": "invalid-fixture", "ASC_PRIVATE_KEY_PATH": "/fixture/key"}), mock.patch.object(preflight, "require_tool"):
            with self.assertRaisesRegex(ValueError, "ASC_KEY_ID is missing or invalid") as error:
                preflight.upload_preflight("ios")
            self.assertNotIn("invalid-fixture", str(error.exception))

    def test_missing_upload_credentials_never_falls_back_to_debug(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "refusing a debug-signed"):
                preflight.android_signing(Path(directory))

    def test_keystore_resolves_like_gradle_and_password_does_not_enter_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "android/app").mkdir(parents=True)
            keystore = project / "android/app/upload-keystore.jks"
            keystore.touch()
            props = project / "android/key.properties"
            props.write_text("storeFile=upload-keystore.jks\nstorePassword=fixture-secret\nkeyPassword=fixture-key\nkeyAlias=upload\n")
            with mock.patch.object(preflight.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "Entry type: PrivateKeyEntry\nOwner: CN=Play On Con\n")) as run:
                preflight.android_signing(project)
                argv = run.call_args[0][0]
                self.assertIn(str(keystore), argv)
                self.assertNotIn("fixture-secret", argv)
                self.assertEqual(run.call_args.kwargs["env"]["POC_RELEASE_STORE_PASSWORD"], "fixture-secret")
            props.write_text(props.read_text().replace("keyAlias=upload", "keyAlias=androiddebugkey"))
            with self.assertRaisesRegex(ValueError, "debug key"):
                preflight.android_signing(project)


class FakePlay:
    def __init__(self, remote):
        self.remote = copy.deepcopy(remote)
        self.edits = {}
        self.puts = []
        self.commits = []
        self.discarded = []
        self.counter = 0

    def new_edit(self):
        self.counter += 1
        edit = str(self.counter)
        self.edits[edit] = copy.deepcopy(self.remote)
        return edit

    def request(self, method, path, payload=None):
        edit = path.split("/")[2]
        if method == "PUT":
            self.puts.append(copy.deepcopy(payload))
            self.edits[edit] = copy.deepcopy(payload)
        return copy.deepcopy(self.edits[edit])

    def validate_edit(self, edit):
        pass

    def commit_edit(self, edit):
        self.commits.append(edit)
        self.remote = self.edits.pop(edit)

    def discard_edit(self, edit):
        self.discarded.append(edit)
        self.edits.pop(edit)


class FakeApple:
    def __init__(self):
        self.localizations = [{"id": "fr", "attributes": {"locale": "fr-FR", "whatsNew": "Bonjour"}}]
        self.writes = []

    def find_build(self, marketing, build):
        if (marketing, build) != ("2026.10.6", "28"):
            raise AssertionError("wrong build selected")
        return {"id": "exact-build"}

    def collection(self, path):
        return copy.deepcopy(self.localizations)

    def request(self, method, path, payload=None):
        self.writes.append((method, path, payload))
        if method == "POST":
            self.localizations.append({"id": "en", "attributes": copy.deepcopy(payload["data"]["attributes"])})
        return {}


class MetadataTests(unittest.TestCase):
    def test_play_commit_explicitly_preserves_existing_reviews(self):
        client = object.__new__(metadata.PlayClient)
        with mock.patch.object(client, "request", return_value={"id": "fixture-edit"}) as request:
            client.commit_edit("fixture-edit")
            request.assert_called_once_with("POST", "/edits/fixture-edit:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW")

    def test_known_play_review_blocker_has_concrete_message_without_body_output(self):
        url = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.fuller.playoncon/edits/fixture:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW"
        failure = {"error": {"message": "fixture-secret-must-not-be-printed", "details": [{
            "@type": "type.googleapis.com/google.rpc.ErrorInfo", "domain": "googleapis.com", "reason": "CHANGES_ALREADY_IN_REVIEW"}]}}
        error = metadata.urllib.error.HTTPError(url, 400, "Bad Request", {}, io.BytesIO(json.dumps(failure).encode()))
        with mock.patch.object(metadata.urllib.request, "urlopen", side_effect=error) as request:
            with self.assertRaisesRegex(metadata.ChangesAlreadyInReviewError, "existing review was preserved") as caught:
                metadata.http_json("POST", url)
            self.assertNotIn("fixture-secret", str(caught.exception))
            self.assertEqual(request.call_count, 1)

    def test_review_failure_preserves_local_staging_and_remote_notes_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "notes.txt"
            notes.write_text("New notes")
            output = root / "staged"
            metadata.prepare(notes, "2026.10.6+28", output)
            snapshot = {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}
            remote = {"track": "internal", "releases": [{"versionCodes": ["28"], "status": "completed", "releaseNotes": [{"language": "en-US", "text": "Old notes"}]}]}
            client = FakePlay(remote)
            with mock.patch.object(client, "commit_edit", side_effect=metadata.ChangesAlreadyInReviewError("Existing review was preserved")) as commit:
                with self.assertRaises(metadata.ChangesAlreadyInReviewError):
                    metadata.publish_play(client, "28", "en-US", "New notes")
                self.assertEqual(commit.call_count, 1)
            self.assertEqual(client.remote, remote)
            self.assertEqual(client.counter, 1, "Failure must not trigger a new edit or blind retry")
            self.assertFalse(client.commits)
            self.assertFalse(client.discarded)
            self.assertEqual({path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}, snapshot)

    def test_http_timeout_requires_readback_and_does_not_retry_a_write(self):
        with mock.patch.object(metadata.urllib.request, "urlopen", side_effect=TimeoutError("fixture timeout")) as request:
            with self.assertRaisesRegex(ValueError, "Read back before retrying"):
                metadata.http_json("POST", "https://example.invalid/fixture", b"{}")
            self.assertEqual(request.call_count, 1)

    def test_canonical_utf8_notes_match_both_store_files_and_reject_truncation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "notes.txt"
            notes.write_bytes("  Map is easier to read 🌲.  \r\nReminders are clearer.\r\n".encode())
            result = metadata.prepare(notes, "2026.10.6+28", root / "staged")
            canonical = metadata.canonical_notes(notes)
            self.assertEqual(result["characters"], len(canonical))
            self.assertEqual(Path(result["testflightNotes"]).read_bytes(), canonical.encode())
            self.assertEqual((Path(result["playMetadata"]) / "en-US/changelogs/28.txt").read_bytes(), canonical.encode())
            self.assertEqual(json.loads((root / "staged/manifest.json").read_text()), {
                "version": "2026.10.6+28", "locale": "en-US", "notes": canonical})
            notes.write_text("x" * 501)
            with self.assertRaisesRegex(ValueError, "1–500"):
                metadata.prepare(notes, "2026.10.6+28", root / "staged")

    def test_platform_notes_normalize_independently_and_replace_shared_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ios = root / "ios.txt"
            android = root / "android.txt"
            ios.write_bytes("  iPhone Duo layouts.  \r\nAccessibility improvements 🌲.\r\n".encode())
            android.write_bytes("  Accessibility improvements 🌲.  \r\nClearer venue controls.\r\n".encode())
            output = root / "staged"
            metadata.prepare(ios, "2026.10.6+28", output)
            result = metadata.prepare(None, "2026.10.6+28", output, ios_notes_path=ios, android_notes_path=android)
            canonical_ios = metadata.canonical_notes(ios)
            canonical_android = metadata.canonical_notes(android)
            self.assertEqual(Path(result["testflightNotes"]).read_bytes(), canonical_ios.encode())
            self.assertEqual((Path(result["playMetadata"]) / "en-US/changelogs/28.txt").read_bytes(), canonical_android.encode())
            self.assertNotIn("Duo", canonical_android)
            self.assertEqual(result["iosCharacters"], len(canonical_ios))
            self.assertEqual(result["androidCharacters"], len(canonical_android))
            self.assertEqual(json.loads((output / "manifest.json").read_text()), {
                "version": "2026.10.6+28", "locale": "en-US", "iosNotes": canonical_ios, "androidNotes": canonical_android})
            snapshot = {path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}
            metadata.prepare(None, "2026.10.6+28", output, ios_notes_path=ios, android_notes_path=android)
            self.assertEqual({path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}, snapshot)

    def test_each_platform_notes_limit_validates_before_staging_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ios = root / "ios.txt"
            android = root / "android.txt"
            # Each platform may use the entire character budget independently.
            ios.write_text("🌲" * 500, encoding="utf-8")
            android.write_text("x" * 500, encoding="utf-8")
            output = root / "staged"
            metadata.prepare(None, "2026.10.6+28", output, ios_notes_path=ios, android_notes_path=android)
            snapshot = {path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}
            for source in (ios, android):
                original = source.read_bytes()
                for invalid in ("", " \r\n\t ", "x" * 501, "Invalid\x01control"):
                    with self.subTest(platform=source.stem, notes=repr(invalid[:20])):
                        source.write_text(invalid, encoding="utf-8")
                        with self.assertRaises(ValueError):
                            metadata.prepare(None, "2026.10.6+28", output, ios_notes_path=ios, android_notes_path=android)
                        fresh = root / "fresh"
                        with self.assertRaises(ValueError):
                            metadata.prepare(None, "2026.10.6+28", fresh, ios_notes_path=ios, android_notes_path=android)
                        self.assertFalse(fresh.exists())
                        self.assertEqual({path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}, snapshot)
                source.write_bytes(original)

    def test_prepare_cli_accepts_shared_or_complete_platform_pair_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "shared.txt"
            ios = root / "ios.txt"
            android = root / "android.txt"
            for source, value in ((shared, "Shared changes"), (ios, "iPhone Duo and accessibility"), (android, "Accessibility improvements")):
                source.write_text(value, encoding="utf-8")
            command = [sys.executable, str(SCRIPTS / "store_metadata.py"), "prepare", "--version", "2026.10.6+28"]
            for mode, options, expected_ios, expected_android in (
                ("shared", ["--notes", str(shared)], shared.read_text(), shared.read_text()),
                ("split", ["--ios-notes", str(ios), "--android-notes", str(android)], ios.read_text(), android.read_text()),
            ):
                result = subprocess.run([*command, *options, "--output", str(root / mode)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads(result.stdout)
                self.assertEqual(Path(receipt["testflightNotes"]).read_text(), expected_ios)
                self.assertEqual((Path(receipt["playMetadata"]) / "en-US/changelogs/28.txt").read_text(), expected_android)
            invalid_options = (
                [], ["--ios-notes", str(ios)], ["--android-notes", str(android)],
                ["--notes", str(shared), "--ios-notes", str(ios)],
                ["--notes", str(shared), "--android-notes", str(android)],
                ["--notes", str(shared), "--ios-notes", str(ios), "--android-notes", str(android)],
            )
            for index, options in enumerate(invalid_options):
                with self.subTest(options=options):
                    output = root / f"invalid-{index}"
                    result = subprocess.run([*command, *options, "--output", str(output)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ERROR:", result.stderr)
                    self.assertFalse(output.exists())

    def test_platform_notes_keep_version_locale_and_file_isolation_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ios = root / "ios.txt"
            android = root / "android.txt"
            ios.write_text("iOS changes")
            android.write_text("Android changes")
            output = root / "staged"
            options = {"ios_notes_path": ios, "android_notes_path": android}
            metadata.prepare(None, "2026.10.6+28", output, **options)
            snapshot = {path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}
            for version, locale in (("2026.10.6+29", "en-US"), ("2026.10.7+28", "en-US"), ("2026.10.6+28", "fr-FR")):
                with self.subTest(version=version, locale=locale):
                    with self.assertRaisesRegex(ValueError, "stale/unrelated|another version/locale"):
                        metadata.prepare(None, version, output, locale, **options)
                    self.assertEqual({path.relative_to(output): path.read_bytes() for path in output.rglob("*") if path.is_file()}, snapshot)
            (output / "play/en-US/changelogs/27.txt").write_text("Old notes")
            with self.assertRaisesRegex(ValueError, "stale/unrelated"):
                metadata.prepare(None, "2026.10.6+28", output, **options)

    def test_metadata_staging_refuses_other_version_and_unrelated_changelog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / "notes.txt"
            notes.write_text("New notes")
            output = root / "staged"
            metadata.prepare(notes, "2026.10.6+28", output)
            metadata.prepare(notes, "2026.10.6+28", output)  # Idempotent retry.
            with self.assertRaisesRegex(ValueError, "stale/unrelated"):
                metadata.prepare(notes, "2026.10.6+29", output)
            (output / "play/en-US/changelogs/27.txt").write_text("Old notes")
            with self.assertRaisesRegex(ValueError, "stale/unrelated"):
                metadata.prepare(notes, "2026.10.6+28", output)

    def test_play_notes_retry_preserves_locales_other_releases_and_rollout_fields(self):
        remote = {"track": "internal", "releases": [
            {"name": "28", "status": "inProgress", "userFraction": 0.2, "versionCodes": ["28"],
             "releaseNotes": [{"language": "fr-FR", "text": "Bonjour"}, {"language": "en-US", "text": "Old"}]},
            {"name": "previous", "status": "completed", "versionCodes": ["27"], "releaseNotes": []}]}
        client = FakePlay(remote)
        result = metadata.publish_play(client, "28", "en-US", "New")
        expected = copy.deepcopy(remote)
        expected["releases"][0]["releaseNotes"][1]["text"] = "New"
        self.assertEqual(client.remote, expected)
        self.assertTrue(result["notesVerified"])
        self.assertEqual(len(client.commits), 1)
        metadata.publish_play(client, "28", "en-US", "New")
        self.assertEqual(len(client.commits), 1, "Identical retry must not commit another change")
        self.assertFalse(client.edits)

    def test_play_absent_build_or_readback_mismatch_never_changes_release(self):
        remote = {"track": "internal", "releases": [{"versionCodes": ["27"], "status": "completed"}]}
        client = FakePlay(remote)
        with self.assertRaisesRegex(ValueError, "must already exist"):
            metadata.publish_play(client, "28", "en-US", "New")
        self.assertFalse(client.puts)
        self.assertFalse(client.commits)
        self.assertFalse(client.edits)
        with self.assertRaisesRegex(ValueError, "readback"):
            metadata.publish_play(client, "27", "en-US", "New", read_only=True)
        self.assertFalse(client.puts)
        self.assertFalse(client.edits)

    def test_uncertain_play_commit_reports_readback_without_deleting_unknown_edit(self):
        client = FakePlay({"track": "internal", "releases": [{"versionCodes": ["28"], "status": "completed"}]})
        with mock.patch.object(client, "commit_edit", side_effect=ValueError("Connection failed; read back before retrying")):
            with self.assertRaisesRegex(ValueError, "read back before retrying"):
                metadata.publish_play(client, "28", "en-US", "New")
        self.assertFalse(client.discarded)

    def test_testflight_notes_create_targets_exact_build_and_idempotent_retry(self):
        client = FakeApple()
        result = metadata.publish_testflight(client, "2026.10.6", "28", "en-US", "New")
        self.assertTrue(result["notesVerified"])
        self.assertEqual(client.writes[0][2]["data"]["relationships"]["build"]["data"]["id"], "exact-build")
        self.assertEqual(client.localizations[0]["attributes"]["whatsNew"], "Bonjour")
        metadata.publish_testflight(client, "2026.10.6", "28", "en-US", "New")
        self.assertEqual(len(client.writes), 1)

    def test_ecdsa_der_padding_converts_to_jwt_fixed_width_signature(self):
        r = b"\x00\x80" + b"\x01" * 31
        s = b"\x01"
        data = b"\x02" + bytes([len(r)]) + r + b"\x02\x01" + s
        raw = metadata.der_to_raw(b"\x30" + bytes([len(data)]) + data)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], r[1:])
        self.assertEqual(int.from_bytes(raw[32:], "big"), 1)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is needed for local crypto verification")
    def test_real_rsa_and_ecdsa_jwts_verify_with_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for algorithm, options in (("ES256", ["-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"]), ("RS256", ["-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"])):
                private = root / (algorithm + ".pem")
                public = root / (algorithm + ".pub")
                subprocess.run(["openssl", "genpkey", *options, "-out", str(private)], check=True, capture_output=True)
                subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True, capture_output=True)
                token = metadata.signed_jwt({"alg": algorithm, "typ": "JWT"}, {"aud": "fixture", "iat": 1, "exp": 2}, private, ecdsa=algorithm == "ES256")
                header, claims, raw = token.split(".")
                signature = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
                if algorithm == "ES256":
                    parts = []
                    for value in (signature[:32], signature[32:]):
                        value = value.lstrip(b"\0")
                        if value[0] & 128:
                            value = b"\0" + value
                        parts.append(b"\x02" + bytes([len(value)]) + value)
                    values = b"".join(parts)
                    signature = b"\x30" + bytes([len(values)]) + values
                signed = root / "signature.bin"
                signed.write_bytes(signature)
                result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signed)], input=(header + "." + claims).encode(), capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertIn(b"Verified OK", result.stdout)

    def test_shared_config_handles_any_gids_and_disabling_optional_cart_layer(self):
        env = os.environ.copy()
        env.update({"POC_RELEASE_ENV_FILE": "/nonexistent-test-env", "SHEETS_API_KEY": "fixture", "SHEET_GIDS": "1,2,3", "SUPABASE_URL": "", "SUPABASE_PUBLISHABLE_KEY": ""})
        result = subprocess.run(["bash", "-c", 'source "$1"; release_require_config; printf "%s" "$CSV_URLS"', "test", str(SCRIPTS / "release-config.sh")], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.split(",")), 3)
        self.assertTrue(result.stdout.endswith("gid=3"))


if __name__ == "__main__":
    unittest.main()
