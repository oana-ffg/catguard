#!/usr/bin/env python3
"""Bootstrap CatGuard's update trust root once; private seed stays in memory/gopass."""
import base64
import subprocess
from macos_signing import gopass, run

ENTRY = "catguard/release/sparkle-eddsa-private-key"
# RFC 8410 PKCS#8 prefix for a 32-byte Ed25519 seed.
PREFIX = bytes.fromhex("302e020100300506032b657004220420")


def public_key(encoded):
    seed = base64.b64decode(encoded.strip(), validate=True)
    if len(seed) != 32:
        raise ValueError("Expected Sparkle 2.8's 32-byte seed format")
    der = run("openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER",
              data=PREFIX + seed, sensitive=True)
    if len(der) != 44 or der[:12] != bytes.fromhex("302a300506032b6570032100"):
        raise ValueError("Unexpected Ed25519 public key encoding")
    return base64.b64encode(der[12:]).decode()


def initialize():
    # Listing must succeed. A failed lookup/decryption is never proof of absence.
    entries = run("gopass", "ls", "--flat").decode().splitlines()
    if ENTRY in entries:
        print("Existing update key retained; SUPublicEDKey=" + public_key(gopass(ENTRY)))
        return
    der = run("openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER", sensitive=True)
    if len(der) != 48 or not der.startswith(PREFIX):
        raise ValueError("Unexpected Ed25519 private key encoding")
    encoded = base64.b64encode(der[16:])
    public = public_key(encoded)
    # No --force. Noninteractive EOF refuses replacement if another writer raced us.
    run("gopass", "insert", "--multiline", ENTRY, data=encoded + b"\n", sensitive=True)
    if public_key(gopass(ENTRY)) != public:
        raise ValueError("Stored update key did not verify")
    print("Created " + ENTRY + "; SUPublicEDKey=" + public)


if __name__ == "__main__":
    try:
        initialize()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
