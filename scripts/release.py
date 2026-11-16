#!/usr/bin/env python3
"""Build and verify local release assets. Never publishes or installs anything."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
from pathlib import Path
import plistlib
import signal
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from macos_signing import (ROOT, TEMP_ROOT, gopass, run, signing_identity, sign,
                           notarize, verify_publisher, cleanup_preserving_error, trash)
from sparkle_key import ENTRY, public_key

SPARKLE_VERSION = "2.8.1"
SIGN_UPDATE_SHA256 = "d5f33cc116c978d7a50b8b0b34363842db3145ebc4f9ec99f6605b38c2effe1e"
IDENTIFIER = "com.firefungames.catguard"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def preflight(test):
    if run("git", "status", "--porcelain").strip():
        raise ValueError("Release requires a clean working tree (including test mode)")
    commit = run("git", "rev-parse", "HEAD").decode().strip()
    branch = run("git", "branch", "--show-current").decode().strip()
    if not test:
        if branch != "main" or commit != run("git", "rev-parse", "main").decode().strip():
            raise ValueError("Real releases require the main branch and commit; use --test locally")
        remote = run("git", "ls-remote", "origin", "refs/heads/main").decode().split()
        if not remote or remote[0] != commit:
            raise ValueError("Real releases require the reviewed public origin/main commit")
    return commit


def sign_update(tool, path, key):
    # The pinned tool supports '-' on stdin; malformed-key diagnostics can echo
    # private input, so ALL tool output is suppressed on failure.
    signature = run(tool, "--ed-key-file", "-", "-p", path,
                    data=key.strip() + b"\n", sensitive=True).decode().strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid update signature format")
    run(tool, "--verify", "--ed-key-file", "-", path, signature,
        data=key.strip() + b"\n", sensitive=True)
    return signature


def verify_app(app, team):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for path, identifier in signing_targets(app):
        verify_publisher(path, identifier, team)
        entitlements = run("codesign", "--display", "--entitlements", ":-", path)
        if entitlements and plistlib.loads(entitlements):
            raise ValueError(f"Unexpected release entitlements: {path.name}")
    if (framework / "Versions/B/XPCServices").exists():
        raise ValueError("Non-sandboxed release must not contain unused Sparkle XPC services")
    result = subprocess.run(["spctl", "-a", "-vv", "-t", "exec", str(app)], capture_output=True)
    print(result.stderr.decode().strip(), flush=True)
    if result.returncode:
        raise ValueError("Gatekeeper rejected the app")
    print(run("xcrun", "stapler", "validate", app).decode().strip(), flush=True)
    for binary in [app / "Contents/MacOS/CatGuard", framework / "Versions/B/Sparkle"]:
        architectures = set(run("lipo", "-archs", binary).decode().split())
        if architectures != {"arm64", "x86_64"}:
            raise ValueError(f"Expected universal Apple Silicon/Intel binary: {binary.name}")


def signing_targets(app):
    framework = app / "Contents/Frameworks/Sparkle.framework"
    return [
        (framework / "Versions/B/Autoupdate", "org.sparkle-project.Autoupdate"),
        (framework / "Versions/B/Updater.app", "org.sparkle-project.Sparkle.Updater"),
        (framework, "org.sparkle-project.Sparkle"),
        (app, IDENTIFIER),
    ]


def zip_app(app, destination):
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, destination)


def write_appcast(path, archive, signature, version, build):
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "CatGuard Updates"
    ET.SubElement(channel, "link").text = "https://github.com/oana-ffg/catguard"
    ET.SubElement(channel, "description").text = "Signed CatGuard updates for macOS"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"CatGuard {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/oana-ffg/catguard/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": signature,
    })
    ET.indent(rss)
    ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true", help="Allow a clean non-main branch; never upload test assets")
    parser.add_argument("--dry-run", action="store_true", help="Validate source and tools only; no signing credentials or build")
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository")
    parser.add_argument("--sparkle-tools", type=Path, required=True, help="Extracted official Sparkle 2.8.1 distribution")
    parser.add_argument("--team", required=True, help="Public Apple Developer Team ID")
    parser.add_argument("--certificate-entry", default="apple/developer-id-application/certificate")
    parser.add_argument("--private-key-entry", default="apple/developer-id-application/private-key")
    parser.add_argument("--notary-entry", default="apple/app-store-connect/ratatoskr-notarization/private-key")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        raise ValueError("Invalid public Apple Team ID")
    commit = preflight(args.test)
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents or output.exists():
        raise ValueError("Output must be a new directory outside the repository")
    tool = args.sparkle_tools.resolve() / "bin/sign_update"
    if sha256(tool) != SIGN_UPDATE_SHA256:
        raise ValueError("Unexpected sign_update binary; use the official Sparkle 2.8.1 distribution")
    info = plistlib.loads((ROOT / "Config/CatGuard-Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not build.isdecimal() or int(build) < 2:
        raise ValueError("CFBundleVersion must be monotonic (at least 2 for the first public release)")
    if args.dry_run:
        print(f"Preflight passed: {commit}, version {version} ({build}), test={args.test}; no credentials accessed")
        return
    output.mkdir(parents=True)
    work = Path(tempfile.mkdtemp(prefix="catguard-release-", dir=TEMP_ROOT))
    try:
        print(f"Building {commit}: {version} ({build}); test={args.test}", flush=True)
        run("xcodegen", "generate")
        if run("git", "status", "--porcelain").strip():
            raise ValueError("Generated project differs from the reviewed commit")
        # Test only the package, which cannot create event taps or register intents.
        run("swift", "test", "--disable-sandbox", "--scratch-path", work / "swiftpm")
        run("xcodebuild", "-quiet", "-project", ROOT / "CatGuard.xcodeproj", "-scheme", "CatGuard",
            "-configuration", "Release", "-derivedDataPath", work / "xcode",
            "-packageAuthorizationProvider", "netrc", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
            "CODE_SIGNING_ALLOWED=NO", "build")
        app = work / "xcode/Build/Products/Release/CatGuard.app"
        built = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if (built["CFBundleIdentifier"], built["CFBundleVersion"], built["SUPublicEDKey"]) != (IDENTIFIER, build, info["SUPublicEDKey"]):
            raise ValueError("Built app identity/version/trust root mismatch")
        xpcs = app / "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
        if xpcs.exists():
            trash(xpcs)
        certificate = work / "developer-id.cer"
        run("gopass", "fscopy", args.certificate_entry, certificate, sensitive=True)
        with signing_identity(certificate, args.private_key_entry) as identity:
            for path, identifier in signing_targets(app):
                sign(path, identifier, args.team, identity)
        certificate.unlink()
        submission = work / "notary-app.zip"
        zip_app(app, submission)
        notarize(submission, args.notary_entry, output / "app-notary-log.json")
        print(run("xcrun", "stapler", "staple", app).decode().strip(), flush=True)
        verify_app(app, args.team)
        archive = output / f"CatGuard-{version}.zip"
        zip_app(app, archive)
        # Verify the exact updater archive after unpacking, including its staple.
        extracted = work / "extracted"
        run("ditto", "-x", "-k", archive, extracted)
        verify_app(extracted / "CatGuard.app", args.team)
        dmg_root = work / "dmg"
        dmg_root.mkdir()
        run("ditto", app, dmg_root / "CatGuard.app")
        (dmg_root / "Applications").symlink_to("/Applications")
        dmg = output / f"CatGuard-{version}.dmg"
        run("hdiutil", "create", "-volname", "CatGuard", "-srcfolder", dmg_root, "-format", "UDZO", dmg)
        with signing_identity(work_certificate(work, args.certificate_entry), args.private_key_entry) as identity:
            sign(dmg, IDENTIFIER + ".installer", args.team, identity, runtime=False)
        notarize(dmg, args.notary_entry, output / "dmg-notary-log.json")
        print(run("xcrun", "stapler", "staple", dmg).decode().strip(), flush=True)
        print(run("xcrun", "stapler", "validate", dmg).decode().strip(), flush=True)
        run("codesign", "--verify", "--strict", dmg)
        key = gopass(ENTRY)
        if public_key(key) != info["SUPublicEDKey"]:
            raise ValueError("gopass updater key differs from the compiled trust root")
        signature = sign_update(tool, archive, key)
        appcast = output / "appcast.xml"
        write_appcast(appcast, archive, signature, version, build)
        # Sparkle 2.8 validates the enclosure signature. Also sign the feed bytes
        # for independent publisher verification (not consumed by this Sparkle).
        (output / "appcast.xml.ed25519").write_text(sign_update(tool, appcast, key) + "\n")
        run("ditto", app, output / "CatGuard.app")
        receipt = {"commit": commit, "version": version, "build": build, "test_only": args.test,
                   "sparkle": SPARKLE_VERSION, "public_key": info["SUPublicEDKey"],
                   "sha256": {p.name: sha256(p) for p in [archive, dmg, appcast, output / "appcast.xml.ed25519"]}}
        (output / "verification.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"Verified local assets: {output}. Nothing uploaded or installed.", flush=True)
    finally:
        cleanup_preserving_error(lambda: trash(work))


def work_certificate(work, entry):
    path = work / "developer-id.cer"
    run("gopass", "fscopy", entry, path, sensitive=True)
    return path


def interrupted(signum, frame):
    raise ValueError(f"Interrupted by signal {signum}; cleaning owned credential containers")


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
