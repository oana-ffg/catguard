# Local signed releases

CatGuard 0.2.0 (build 2) uses `com.firefungames.catguard`, Developer ID, hardened
runtime, notarization and Sparkle 2.8.1. It runs on macOS 14+ on Apple Silicon and
Intel. Support: catguard@firefungames.com. Inspect/build source if preferred: a
publisher signature does not prove safety.

## Prepare without publishing

Requirements: full Xcode, XcodeGen, Python 3, OpenSSL with Ed25519 support,
gopass and access to the existing Apple credentials on a trusted publisher Mac.
Get [Sparkle 2.8.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.8.1),
extract `Sparkle-2.8.1.tar.xz` outside the repo, and verify its SHA256:
`5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be`.
The script independently pins the `sign_update` binary hash too.

Generate `xcodegen generate`, run `swift test`, and build the app unsigned as CI
does. Commit all changes, including the generated project and Package.resolved.
`python3 -B scripts/release.py --help` describes the publisher inputs. Supply
`--team`, `--sparkle-tools`, and a new `--output` directory outside the repo.
Use `--test` on a clean review branch; add `--dry-run` for credential-free checks.
Real mode refuses dirty trees, non-main branches, or a commit differing from the
current public origin/main. Test mode also requires a clean tree and records
`test_only: true` in `verification.json`; never publish those artifacts.

The Apple certificate/key and notary JSON are read from the gopass entries named
by the script. The certificate public key must match the private key. An encrypted
PKCS#12 imports into an owned temporary encrypted Keychain; password-bearing
commands use stdin. The notary private key exists only in memory and an
owner-only mounted AES-256 credential image because notarytool requires a regular
file. It is removed before detaching. Cleanup retries detach, surfaces failures,
and moves owned temporary containers to Trash. SIGTERM/SIGHUP trigger cleanup;
SIGKILL or power loss cannot. Inspect only the interrupted run's owned containers
before retrying. Temporary work lives under `/Volumes/Kingston/bottemp/workspaces`.
No release step reads or changes the user's rescue phrase, login settings or
privacy grants, and no CatGuard build is launched.

The update key is `catguard/release/sparkle-eddsa-private-key`. Run
`python3 -B scripts/sparkle_key.py` only for the explicitly authorized one-time
bootstrap. It checks the entry list, never forces replacement, inserts the
base64 32-byte Sparkle seed via stdin, and prints only the derived public key.
Back up the encrypted gopass store; losing the update key breaks the trust root
for installed clients. The public key is `SUPublicEDKey` in Info.plist. Release
signing uses Sparkle's supported `sign_update --ed-key-file -` and verifies the
signature before emitting the feed. Keep all Apple and Sparkle keys out of CI.

The script builds universal binaries, removes unused Sparkle XPC services,
signs Autoupdate, Updater.app, Sparkle.framework, then CatGuard.app, without
`--deep`. All components use secure timestamps and hardened runtime with empty
entitlements. The app and DMG receive separate accepted notarization submissions
and stapled tickets. The exact extracted updater ZIP is independently checked
with codesign, Gatekeeper and stapler.

Outputs: stapled `CatGuard.app`, `CatGuard-0.2.0.dmg`, `CatGuard-0.2.0.zip`,
`appcast.xml`, detached `appcast.xml.ed25519`, notarization receipts and
`verification.json`. Sparkle 2.8.1 consumes the signed ZIP enclosure in the
appcast; the detached signature additionally authenticates the feed bytes for
publisher verification. Do not claim Sparkle 2.8.1 verifies the detached feed.
Nothing is uploaded, pushed, installed or launched.

After review and owner approval, the parent publishes a new GitHub release
`v0.2.0` from the exact reviewed main commit and attaches the DMG, ZIP and appcast
assets (including the optional detached feed signature). The feed URL is
`https://github.com/oana-ffg/catguard/releases/latest/download/appcast.xml`.
Do not replace assets of a published version. Increment both version and build
for each later release, preserving a strictly increasing build number.
The initial feed does not exist until this publication; updater checks before
then report a visible error. Test end-to-end update/relaunch using two published
or privately hosted test versions in an isolated session before relying on it.

## Existing installation switchover

This requires an owner-agreed window with a working physical rescue path.
Release preparation must leave `/Applications/CatGuard.app` and its running
process untouched.

1. Deactivate the old CatGuard Focus and clear manual arm with a bypass. Quit
   the old app before replacing it. Never run both copies together.
2. Install the new stapled app from the DMG in `/Applications` and open it.
   The new app copies app preferences once from `com.oanaffg.CatGuard`.
3. Approve access to the original rescue-phrase Keychain item when macOS asks.
   Its old service/account intentionally stay unchanged to avoid moving or
   losing the phrase. If denied, Settings opens and protection remains orange
   until **Retry Keychain access** succeeds or an explicit replacement is saved.
   Verify the saved rescue phrase before arming.
4. Re-grant **Input Monitoring** and **Accessibility** to the new installed app.
   Remove obsolete old privacy rows manually. Never reset TCC databases.
5. Remove the old Focus filter and add the new CatGuard filter. The bundle ID
   changed, so the old filter cannot deliver to the new app.
6. Re-enable **Start CatGuard at login** in the new app, registering its own
   `SMAppService.mainApp`. Remove the old login item/registration manually in
   System Settings. No migration code unregisters the old app automatically.
7. Confirm real physical keyboard/click suppression, synthetic input passthrough,
   circle and rescue bypass, Focus activation/deactivation, and orange status
   after temporary permission revocation. Re-grant, relaunch if macOS requires,
   and confirm recovery. These checks cannot be inferred from notarization.

Updates automatically download in the background but installation/relaunch waits
until both Focus protection and manual arm are off and Focus state is known.
Bypass and permission failure preserve protection intent and keep updates waiting.
A staged update also defers quitting while armed, with an explanation in Settings;
disable Focus and bypass manual arm first. Force-quit/process failure always
restores physical input. Changing bundle/signing identity later requires another
explicit migration; do not silently rotate the updater key.
