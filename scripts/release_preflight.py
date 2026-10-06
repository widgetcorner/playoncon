#!/usr/bin/env python3
"""Fail before release builds when tools or production signing are missing."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid


def require_tool(name):
    if not shutil.which(name):
        raise ValueError(f"Required tool is missing: {name}")


def java_properties(path):
    """Read the conventional key.properties file without printing credentials."""
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        match = re.match(r"([^\s=:]+)\s*[=:]\s*(.*)", line)
        if not match:
            raise ValueError("key.properties must use one key=value per line.")
        # Java property escapes are common for Windows paths and punctuation.
        value = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m[1], 16)), match[2])
        value = re.sub(r"\\(.)", lambda m: {"n": "\n", "r": "\r", "t": "\t", "f": "\f"}.get(m[1], m[1]), value)
        values[match[1]] = value
    return values


def android_signing(project):
    path = project / "android/key.properties"
    if not path.is_file():
        raise ValueError("android/key.properties is missing; refusing a debug-signed release.")
    props = java_properties(path)
    for key in ("storeFile", "storePassword", "keyAlias", "keyPassword"):
        if not props.get(key):
            raise ValueError(f"android/key.properties is missing {key}.")
    # android/app/build.gradle.kts uses file(storeFile), relative to android/app.
    keystore = Path(props["storeFile"])
    if not keystore.is_absolute():
        keystore = project / "android/app" / keystore
    if not keystore.is_file():
        raise ValueError("The upload keystore configured in android/key.properties is missing.")
    if props["keyAlias"].lower() == "androiddebugkey":
        raise ValueError("The release alias points to Android's debug key.")
    env = os.environ.copy()
    env["POC_RELEASE_STORE_PASSWORD"] = props["storePassword"]
    result = subprocess.run([
        "keytool", "-J-Duser.language=en", "-list", "-v", "-keystore", str(keystore),
        "-alias", props["keyAlias"], "-storepass:env", "POC_RELEASE_STORE_PASSWORD",
    ], env=env, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Cannot open the configured upload key/alias; check signing credentials.")
    if "PrivateKeyEntry" not in result.stdout or "CN=Android Debug" in result.stdout:
        raise ValueError("The configured alias is not a production private signing key.")


def preflight(platform, project):
    require_tool("flutter")
    require_tool("python3")
    if platform == "android":
        require_tool("java")
        require_tool("keytool")
        require_tool("jarsigner")
        android_signing(project)
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        local = project / "android/local.properties"
        if not sdk and local.is_file():
            sdk = java_properties(local).get("sdk.dir")
        if not sdk or not (Path(sdk) / "platform-tools").is_dir():
            raise ValueError("Android SDK is missing; configure android/local.properties or ANDROID_HOME.")
    else:
        for tool in ("xcodebuild", "xcrun", "security"):
            require_tool(tool)
        result = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
        if result.returncode or "Xcode" not in result.stdout:
            raise ValueError("A full, selected Xcode installation is required.")
        identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True)
        if identities.returncode or not re.search(r'\d+\) [A-F0-9]+ "(?:Apple|iPhone) (?:Distribution|Development)', identities.stdout):
            raise ValueError("No usable Apple development/distribution signing identity is available.")
    print(f"{platform} release tools and signing preflight passed.")


def upload_preflight(platform):
    """Validate local upload prerequisites without contacting either store."""
    from store_metadata import load_release_environment
    needed = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH") if platform == "ios" else ("POC_PLAY_JSON_KEY",)
    if any(not os.environ.get(key) for key in needed):
        load_release_environment()
    require_tool("openssl")
    if platform == "ios":
        key_id = os.environ.get("ASC_KEY_ID", "")
        if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
            raise ValueError("ASC_KEY_ID is missing or invalid; set it in scripts/.env.local.")
        try:
            uuid.UUID(os.environ.get("ASC_ISSUER_ID", ""))
        except ValueError as error:
            raise ValueError("ASC_ISSUER_ID is missing or invalid; set it in scripts/.env.local.") from error
        path = Path(os.environ.get("ASC_PRIVATE_KEY_PATH", "")).expanduser()
        if not path.is_file():
            raise ValueError("ASC_PRIVATE_KEY_PATH does not point to a local private key.")
        result = subprocess.run(["openssl", "pkey", "-in", str(path), "-noout"], capture_output=True)
        if result.returncode:
            raise ValueError("ASC_PRIVATE_KEY_PATH is not a usable signing key.")
        result = subprocess.run(["xcrun", "--find", "altool"], capture_output=True)
        if result.returncode:
            raise ValueError("Xcode's altool upload tool is unavailable.")
    else:
        require_tool("fastlane")
        require_tool("ruby")
        guard = subprocess.run(["ruby", str(Path(__file__).resolve().parent / "upload_play.rb"), "--check-guard"], capture_output=True, text=True)
        if guard.returncode:
            raise ValueError("The installed fastlane/Google Play client cannot enforce the existing-review guard; no upload was attempted.")
        path = Path(os.environ.get("POC_PLAY_JSON_KEY", "")).expanduser()
        if not path.is_file():
            raise ValueError("POC_PLAY_JSON_KEY does not point to local publisher credentials.")
        try:
            credentials = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, OSError) as error:
            raise ValueError("POC_PLAY_JSON_KEY is not a readable JSON credentials file.") from error
        if not isinstance(credentials, dict) or credentials.get("type") != "service_account" or not credentials.get("client_email") or not credentials.get("private_key"):
            raise ValueError("POC_PLAY_JSON_KEY must contain service_account, client_email, and private_key credentials.")
    print(f"{platform} local upload prerequisites passed (store access has not been contacted).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("ios", "android"))
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--upload", action="store_true", help="Also validate existing local upload tools and credentials; no store API calls.")
    args = parser.parse_args()
    try:
        preflight(args.platform, args.project)
        if args.upload:
            upload_preflight(args.platform)
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
