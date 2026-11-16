# Repository Guidelines

## Git workflow

This is a solo hobby project. Commit and push directly to main unless the user
requests a branch or review. Explicit release-preparation boundaries take
precedence: a local implementation branch must not be pushed or published.

## Release and installation

Read `docs/releases.md`. Generate the Xcode project, run Swift package tests and
an unsigned app build, then use `scripts/release.py` on the trusted publisher Mac.
The script requires a clean main commit for real releases; `--test` permits a
clean review branch and produces local test assets only. It signs with Developer
ID, enables hardened runtime, notarizes and staples the app and DMG, verifies the
exact Sparkle archive, and signs the appcast enclosure. It never publishes,
installs, launches, or changes user privacy/Focus/login settings. Keep Team ID
supplied at build time and all private keys out of source and CI.

Publish only after owner review/approval. Install or replace the live app only
when explicitly authorized, following the switchover in `docs/releases.md`.
Never launch a second guard in the user's session for release verification.
GUI/input/Focus tests require an agreed safe window and physical recovery path.
