#!/usr/bin/env python3
"""Stage canonical release notes; publish/read back only the exact uploaded build.

Uses stdlib HTTP and local OpenSSL, without installing dependencies. API references:
https://developer.apple.com/documentation/appstoreconnectapi/beta-build-localizations
https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks
https://developers.google.com/identity/protocols/oauth2/service-account
"""
import argparse
import base64
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ENV_KEYS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH", "POC_PLAY_JSON_KEY", "POC_BUNDLE_ID", "POC_PACKAGE_NAME")


class ChangesAlreadyInReviewError(ValueError):
    """Play refused an edit without cancelling the app's existing review."""


def load_release_environment():
    # A shell config is executable local configuration; never print its contents.
    code = "import json, os; print(json.dumps({k:os.environ.get(k,'') for k in " + repr(ENV_KEYS) + "}))"
    result = subprocess.run(["bash", "-c", 'source "$1"; "$2" -c "$3"', "release-config",
                             str(ROOT / "scripts/release-config.sh"), sys.executable, code], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Cannot load scripts/release-config.sh and scripts/.env.local.")
    try:
        values = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("Release configuration must not print output when sourced.") from error
    os.environ.update(values)


def canonical_notes(path):
    text = Path(path).read_text(encoding="utf-8")
    text = "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")).strip()
    if not text or len(text) > 500:
        raise ValueError("Store notes must contain 1–500 characters; shorten them before publishing.")
    if any(ord(char) < 32 and char not in "\n\t" for char in text):
        raise ValueError("Store notes contain unsupported control characters.")
    return text


def split_version(version):
    if not re.fullmatch(r"\d+\.\d+\.\d+\+[1-9]\d*", version):
        raise ValueError("Expected a marketing.version.date+positive-build version.")
    return version.split("+", 1)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(signature):
    """Convert OpenSSL's ASN.1 ECDSA signature to JWT's 64-byte R || S."""
    def read_length(offset):
        size = signature[offset]
        offset += 1
        if size & 128:
            count = size & 127
            if not count or count > 2:
                raise ValueError("Invalid ECDSA signature length.")
            size = int.from_bytes(signature[offset:offset + count], "big")
            offset += count
        return size, offset
    if not signature or signature[0] != 0x30:
        raise ValueError("OpenSSL did not produce an ECDSA signature.")
    length, offset = read_length(1)
    if offset + length != len(signature):
        raise ValueError("Invalid ECDSA signature.")
    parts = []
    for _ in range(2):
        if offset >= len(signature) or signature[offset] != 2:
            raise ValueError("Invalid ECDSA signature integer.")
        length, offset = read_length(offset + 1)
        value = signature[offset:offset + length]
        if len(value) != length:
            raise ValueError("Truncated ECDSA signature.")
        offset += length
        number = int.from_bytes(value, "big")
        if not number or number.bit_length() > 256:
            raise ValueError("ECDSA signature is not a P-256 signature.")
        parts.append(number.to_bytes(32, "big"))
    if offset != len(signature):
        raise ValueError("Invalid trailing ECDSA signature data.")
    return b"".join(parts)


def signed_jwt(header, claims, key_path, ecdsa=False):
    data = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
            b64url(json.dumps(claims, separators=(",", ":")).encode())).encode("ascii")
    result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)], input=data, capture_output=True)
    if result.returncode:
        raise ValueError("OpenSSL could not sign with the configured store private key.")
    signature = der_to_raw(result.stdout) if ecdsa else result.stdout
    return data.decode("ascii") + "." + b64url(signature)


def http_json(method, url, body=None, headers=None):
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        # Recognize only Google's documented, allowlisted blocker; never log bodies.
        parsed = urllib.parse.urlparse(url)
        if error.code == 400 and parsed.hostname == "androidpublisher.googleapis.com" and parsed.path.endswith(":commit"):
            try:
                failure = json.loads(error.read(65536))
                details = failure.get("error", {}).get("details", []) if isinstance(failure, dict) else []
                blocked = any(isinstance(detail, dict) and detail.get("@type") == "type.googleapis.com/google.rpc.ErrorInfo" and
                              detail.get("domain") == "googleapis.com" and detail.get("reason") == "CHANGES_ALREADY_IN_REVIEW"
                              for detail in details)
            except (ValueError, OSError, AttributeError, TypeError):
                blocked = False
            finally:
                error.close()
            if blocked:
                raise ChangesAlreadyInReviewError("Google Play already has changes in review. The existing review was preserved; wait for it to finish before retrying this metadata step.") from error
        error.close()
        raise ValueError(f"Store API {method} failed (HTTP {error.code}); inspect store access/state before retrying.") from error
    except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
        raise ValueError("Store API connection failed; a write may have succeeded. Read back before retrying.") from error
    except json.JSONDecodeError as error:
        raise ValueError("Store API returned an invalid response; a write may have succeeded. Read back before retrying.") from error


class AppleClient:
    def __init__(self, bundle_id=None):
        self.bundle_id = bundle_id or os.environ.get("POC_BUNDLE_ID", "com.fuller.playoncon")
        self.key_id = os.environ.get("ASC_KEY_ID", "")
        self.issuer = os.environ.get("ASC_ISSUER_ID", "")
        self.key_path = Path(os.environ.get("ASC_PRIVATE_KEY_PATH", "")).expanduser()
        if not self.key_id or not self.issuer or not self.key_path.is_file():
            raise ValueError("Set ASC_KEY_ID, ASC_ISSUER_ID, and a usable ASC_PRIVATE_KEY_PATH in scripts/.env.local.")

    def request(self, method, path, payload=None):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("Apple API paths must be relative to /v1.")
        now = int(time.time())
        token = signed_jwt({"alg": "ES256", "kid": self.key_id, "typ": "JWT"},
                           {"iss": self.issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, self.key_path, ecdsa=True)
        body = json.dumps(payload).encode() if payload is not None else None
        return http_json(method, "https://api.appstoreconnect.apple.com/v1" + path, body,
                         {"Authorization": "Bearer " + token, "Content-Type": "application/json"})

    def collection(self, path):
        items = []
        while path:
            result = self.request("GET", path)
            items.extend(result.get("data", []))
            next_url = result.get("links", {}).get("next")
            if next_url:
                parsed = urllib.parse.urlparse(next_url)
                if parsed.netloc != "api.appstoreconnect.apple.com" or not parsed.path.startswith("/v1/"):
                    raise ValueError("Unexpected Apple API pagination destination.")
                path = parsed.path[3:] + ("?" + parsed.query if parsed.query else "")
            else:
                path = None
        return items

    def find_build(self, marketing, build):
        apps = self.collection("/apps?" + urllib.parse.urlencode({"filter[bundleId]": self.bundle_id, "limit": 200}))
        if len(apps) != 1:
            raise ValueError("The configured bundle ID does not resolve to exactly one App Store app.")
        # Resolve the marketing train explicitly so equal build numbers cannot match another train.
        trains = self.collection("/preReleaseVersions?" + urllib.parse.urlencode({
            "filter[app]": apps[0]["id"], "filter[version]": marketing, "filter[platform]": "IOS", "limit": 200}))
        if not trains:
            return None
        if len(trains) != 1:
            raise ValueError("Marketing version resolves to multiple iOS prerelease trains.")
        builds = self.collection("/builds?" + urllib.parse.urlencode({
            "filter[app]": apps[0]["id"], "filter[preReleaseVersion]": trains[0]["id"], "filter[version]": build, "limit": 200}))
        if not builds:
            return None
        if len(builds) != 1:
            raise ValueError("Uploaded version resolves to multiple TestFlight builds.")
        item = builds[0]
        state = item["attributes"].get("processingState")
        if state in ("FAILED", "INVALID") or item["attributes"].get("expired"):
            raise ValueError(f"The exact TestFlight build is unusable (processingState={state}).")
        return item if state == "VALID" else None


class PlayClient:
    def __init__(self, package=None, json_key=None):
        self.package = package or os.environ.get("POC_PACKAGE_NAME", "com.fuller.playoncon")
        if not re.fullmatch(r"[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+", self.package):
            raise ValueError("Invalid Android package name.")
        key_path = Path(json_key or os.environ.get("POC_PLAY_JSON_KEY", "~/.playconsole/playoncon-publisher.json")).expanduser()
        self.credentials = json.loads(key_path.read_text(encoding="utf-8"))
        if not isinstance(self.credentials, dict) or self.credentials.get("type") != "service_account" or not self.credentials.get("client_email") or not self.credentials.get("private_key"):
            raise ValueError("Play publisher credentials must contain a service account private key.")
        self.base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" + self.package
        self.token = None
        self.token_expires = 0

    def access_token(self):
        now = int(time.time())
        if self.token and now < self.token_expires:
            return self.token
        # NamedTemporaryFile defaults to mode 0600; private material never enters argv.
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as key:
            key.write(self.credentials["private_key"])
            key.flush()
            assertion = signed_jwt({"alg": "RS256", "typ": "JWT", "kid": self.credentials.get("private_key_id", "")},
                                   {"iss": self.credentials["client_email"], "scope": "https://www.googleapis.com/auth/androidpublisher",
                                    "aud": "https://oauth2.googleapis.com/token", "iat": now, "exp": now + 3600}, key.name)
        body = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}).encode()
        result = http_json("POST", "https://oauth2.googleapis.com/token", body, {"Content-Type": "application/x-www-form-urlencoded"})
        self.token = result["access_token"]
        self.token_expires = now + min(int(result.get("expires_in", 3600)), 3600) - 60
        return self.token

    def request(self, method, path, payload=None):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("Play API paths must be relative to this package.")
        body = json.dumps(payload).encode() if payload is not None else None
        return self.request_url(method, self.base + path, body)

    def request_url(self, method, url, body=None, content_type="application/json"):
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.netloc != "androidpublisher.googleapis.com":
            raise ValueError("Unexpected Play API destination.")
        return http_json(method, url, body, {"Authorization": "Bearer " + self.access_token(), "Content-Type": content_type})

    def new_edit(self):
        return self.request("POST", "/edits", {})["id"]

    def discard_edit(self, edit):
        return self.request("DELETE", f"/edits/{edit}")

    def validate_edit(self, edit):
        return self.request("POST", f"/edits/{edit}:validate")

    def commit_edit(self, edit):
        # Google's unspecified default cancels any existing review and resubmits.
        # Both notes and screenshot helpers must fail while that review is pending.
        return self.request("POST", f"/edits/{edit}:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW")


def updated_track(track, build, locale, notes):
    result = copy.deepcopy(track)
    targets = [release for release in result.get("releases", []) if str(build) in release.get("versionCodes", [])]
    if len(targets) != 1:
        raise ValueError("Exact Play build must already exist in exactly one internal release; upload/read back the binary first.")
    release = targets[0]
    localized = release.setdefault("releaseNotes", [])
    matches = [item for item in localized if item.get("language") == locale]
    if len(matches) > 1:
        raise ValueError("Play release has duplicate notes for the selected locale.")
    if matches:
        matches[0]["text"] = notes
    else:
        localized.append({"language": locale, "text": notes})
    return result


def matching_release(track, build, locale, notes):
    matches = [item for item in track.get("releases", []) if str(build) in item.get("versionCodes", [])]
    if len(matches) != 1:
        raise ValueError("The exact uploaded Play version code is absent or ambiguous on the requested track.")
    release = matches[0]
    if notes is not None and not any(item.get("language") == locale and item.get("text") == notes for item in release.get("releaseNotes", [])):
        raise ValueError("Play release notes readback did not exactly match the canonical notes.")
    return release


def publish_play(client, build, locale, notes, track="internal", read_only=False):
    if track != "internal":
        raise ValueError("This release helper is restricted to the internal track.")
    edit = client.new_edit()
    try:
        remote = client.request("GET", f"/edits/{edit}/tracks/{track}")
        if not read_only:
            updated = updated_track(remote, build, locale, notes)
            if updated != remote:
                client.request("PUT", f"/edits/{edit}/tracks/{track}", updated)
                client.validate_edit(edit)
                committing = edit
                # A timeout can mean commit succeeded; don't mask it with a 404 delete.
                edit = None
                client.commit_edit(committing)
        if edit:
            matching_release(remote, build, locale, notes)
    finally:
        if edit:
            client.discard_edit(edit)
    # Verify committed state through a fresh edit; never trust the PUT response alone.
    edit = client.new_edit()
    try:
        remote = client.request("GET", f"/edits/{edit}/tracks/{track}")
        release = matching_release(remote, build, locale, notes)
        return {"track": track, "versionCodes": release["versionCodes"], "status": release.get("status"), "locale": locale, "notesVerified": True}
    finally:
        client.discard_edit(edit)


def publish_testflight(client, marketing, build, locale, notes, read_only=False, wait_seconds=0):
    deadline = time.monotonic() + wait_seconds
    while True:
        item = client.find_build(marketing, build)
        if item:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("The exact TestFlight build is not processed yet; retry notes later without another bump/upload.")
        print("Waiting for the exact TestFlight build to finish processing...", flush=True)
        time.sleep(min(30, remaining))
    path = f'/builds/{item["id"]}/betaBuildLocalizations'
    localizations = client.collection(path + "?limit=200")
    matches = [entry for entry in localizations if entry.get("attributes", {}).get("locale") == locale]
    if len(matches) > 1:
        raise ValueError("TestFlight has duplicate localizations for the selected locale.")
    if not read_only:
        if matches:
            entry = matches[0]
            if entry["attributes"].get("whatsNew") != notes:
                client.request("PATCH", f'/betaBuildLocalizations/{entry["id"]}', {"data": {
                    "type": "betaBuildLocalizations", "id": entry["id"], "attributes": {"whatsNew": notes}}})
        else:
            client.request("POST", "/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": notes},
                "relationships": {"build": {"data": {"type": "builds", "id": item["id"]}}}}})
    verified = client.collection(path + "?limit=200")
    if not any(entry.get("attributes", {}).get("locale") == locale and entry["attributes"].get("whatsNew") == notes for entry in verified):
        raise ValueError("TestFlight what'sNew readback did not exactly match the canonical notes.")
    return {"marketingVersion": marketing, "build": build, "buildId": item["id"], "locale": locale, "notesVerified": True}


def prepare(notes_path, version, output, locale="en-US"):
    marketing, build = split_version(version)
    notes = canonical_notes(notes_path)
    manifest = {"version": version, "locale": locale, "notes": notes}
    allowed = {"manifest.json", "testflight.txt", f"play/{locale}/changelogs/{build}.txt"}
    if output.exists():
        existing = {str(path.relative_to(output)) for path in output.rglob("*") if path.is_file()}
        if existing - allowed:
            raise ValueError("Metadata staging contains stale/unrelated files; choose a fresh version-specific output directory.")
        if existing:
            manifest_path = output / "manifest.json"
            if not manifest_path.is_file():
                raise ValueError("Nonempty metadata staging has no version manifest; choose a fresh directory.")
            previous = json.loads(manifest_path.read_text(encoding="utf-8"))
            if previous.get("version") != version or previous.get("locale") != locale:
                raise ValueError("Metadata staging belongs to another version/locale; choose a fresh directory.")
    output.mkdir(parents=True, exist_ok=True)
    # Write the manifest first so an interrupted staging operation can be retried.
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (output / "testflight.txt").write_text(notes, encoding="utf-8")
    changelog = output / "play" / locale / "changelogs" / f"{build}.txt"
    changelog.parent.mkdir(parents=True, exist_ok=True)
    changelog.write_text(notes, encoding="utf-8")
    return {"version": version, "characters": len(notes), "testflightNotes": str((output / "testflight.txt").resolve()), "playMetadata": str((output / "play").resolve())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "testflight", "play"):
        command = subparsers.add_parser(name)
        command.add_argument("--version", required=True)
        command.add_argument("--notes", type=Path, required=True)
        command.add_argument("--locale", default="en-US")
        if name == "prepare":
            command.add_argument("--output", type=Path, required=True)
        else:
            command.add_argument("--read-only", action="store_true", help="Verify existing notes without changing store metadata.")
            if name == "testflight":
                command.add_argument("--wait-seconds", type=int, default=0)
    args = parser.parse_args()
    try:
        marketing, build = split_version(args.version)
        if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", args.locale):
            raise ValueError("Invalid store locale.")
        if args.command == "prepare":
            result = prepare(args.notes, args.version, args.output, args.locale)
        else:
            notes = canonical_notes(args.notes)
            load_release_environment()
            if args.command == "play":
                result = publish_play(PlayClient(), build, args.locale, notes, read_only=args.read_only)
            else:
                if args.wait_seconds < 0:
                    raise ValueError("--wait-seconds cannot be negative.")
                result = publish_testflight(AppleClient(), marketing, build, args.locale, notes, args.read_only, args.wait_seconds)
        print(json.dumps(result, indent=2))
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
