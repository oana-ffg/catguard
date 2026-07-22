# CatGuard

<p align="center">
  <img src="Resources/Brand/CatGuard-AppIcon-1024.png" width="160" alt="CatGuard app icon">
</p>

CatGuard is a native macOS menu-bar app that prevents cats from pressing keys,
clicking, dragging, or scrolling while a chosen Focus is active—without locking
the Mac or blocking trusted Computer Use automation.

> [!IMPORTANT]
> CatGuard protects against the **feline** threat model: paws on keyboards and
> pointing devices. It does not protect a Mac from people, malware, theft, or
> deliberate physical access, and it is not a replacement for the macOS lock
> screen. The rescue phrase is a convenience fallback, not a security password.

> [!CAUTION]
> **Do not blindly install someone else's CatGuard binary.** CatGuard is
> intentionally invasive: it asks for system-wide Input Monitoring permission
> and installs an administrator-authorized helper that runs as root and receives
> raw physical keyboard events before other apps do. A malicious build could act
> as a keylogger or abuse root access. This repository's implementation does not
> store or transmit typed keys—the helper keeps only event counts and the
> in-memory rescue-phrase matcher—but you should verify that claim rather than
> trust it. The safest option is to ask Codex to inspect this design and build a
> fresh, locally signed version from source for your Mac. The prompt below is
> provided specifically for that purpose.

The idea came from a real problem: an unlocked Mac is useful for overnight AI
tasks, but an unattended keyboard is irresistible to cats. Locking the Mac stops
the cats, but it also changes how local automation can interact with the GUI.
CatGuard narrows the intervention to physical input and leaves synthetic
Computer Use events alone.

## What it does

- Follows a macOS Focus Filter, even while the app stays in the background.
- Shows an unmistakable state icon in the menu bar: a green paw when input is
  active, a red closed lock when fully guarded, a green open lock while
  bypassed, and an orange warning when protection is unavailable.
- Exclusively opens external physical keyboard HID collections through a small,
  authenticated privileged helper.
- Blocks physical pointer clicks, drags, and scrolling with a Core Graphics
  event tap. The cursor can still move.
- Keeps trusted Computer Use interaction working while physical input is
  guarded.
- Bypasses on a one-pointer circle drawn with an ordinary mouse or trackpad.
- Provides an editable Keychain-backed rescue phrase as a fallback.
- After a bypass, waits until physical input has been idle for five continuous
  minutes before re-arming. Activity resets the idle timer; it is not a fixed
  five-minute countdown.
- Restores keyboard input if the app heartbeat stops.
- When Focus ends, reports blocked keyboard inputs and pointer clicks separately.
  Pointer movement is not counted. If any bypass occurred, that count appears
  first in the notification.

Counts are blocked input events, not estimates of distinct cats or visits. One
enthusiastic keyboard walk can produce several events.

The fresh-install rescue phrase is `catguard`. It is interpreted from physical
HID letter positions, so non-QWERTY layouts should treat the circle or Focus as
their primary bypass until layout-aware phrase capture is implemented.

## Current status

CatGuard is pre-release while its privileged-helper package is validated on
current macOS. The pointer architecture, Computer Use boundary, circle bypass,
and HID seizure have been exercised on real hardware; see
[the experiment log](docs/HID-EXPERIMENTS.md) for successes, failures, and
measured release timing.

**This repository does not currently publish a prebuilt app.** Its maintainer's
free Apple Personal Team cannot issue the Developer ID certificate required for
a properly signed and notarized public macOS release. The local certificate used
for development is trusted only by its owner's Mac and must not be distributed.
If a Developer ID release is added later, a signature will prove which developer
produced it—not that invasive software is safe. Building your own inspected copy
will remain the recommended path.

## Local setup

1. Review the source and follow **Build from source** below. Do not obtain a
   CatGuard binary from an unofficial download.
2. Move your locally built `CatGuard.app` to `/Applications` and open it.
3. Grant Input Monitoring when macOS asks. This lets CatGuard distinguish and
   suppress physical pointer events.
4. Open CatGuard Settings and choose **Install or Update Keyboard Helper**. The
   one-time administrator prompt installs the narrowly scoped root helper.
5. Return to **System Settings → Privacy & Security → Input Monitoring**, click
   **+**, add
   `/Library/PrivilegedHelperTools/com.oanaffg.CatGuard.Helper`, and enable it.
   macOS treats the app and its root helper as separate input-monitoring clients.
   This is the consequential permission that lets the helper receive raw
   physical keyboard events system-wide.
6. In **System Settings → Focus**, edit the Focus you want to use, choose
   **Focus Filters**, add CatGuard, and enable **Guard against cat input**.
7. Optionally enable **Start CatGuard at login**, customize the rescue phrase,
   or disable circle bypass.

The Focus is still enabled and disabled from the Mac, iPhone, or Apple Watch in
the normal Apple way. CatGuard only reacts to the associated filter.

## Recovery paths

- Draw a closed circle with one pointer.
- Type the configured rescue phrase on the guarded keyboard.
- Disable the activating Focus from the Mac, iPhone, or Apple Watch.
- Quit CatGuard from its menu-bar menu.
- If the app crashes or communication stops, the helper watchdog restores the
  keyboard automatically.
- Unplugging the keyboard remains the physical last resort.

Every failure path is fail-open: CatGuard does not show red unless both keyboard
and pointer protection succeeded.

## Build from source

Requirements: macOS 14 or newer, Xcode 26, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open CatGuard.xcodeproj
```

Select your own Apple development team before building. The privileged helper,
app, embedded signing requirements, and bundle identifiers must be signed as one
trusted set. A distributable build additionally requires Developer ID signing
and Apple notarization.

For a stable build used only on your own Mac, no paid membership is required.
The local build script creates a ten-year, Keychain-backed certificate trusted
only on that Mac and binds the app and helper to its exact fingerprint:

```sh
./scripts/build-local.sh
open .build/xcode-local/Build/Products/Release/CatGuard.app
```

This local identity is intentionally unsuitable for distributing a binary to
other people. Public releases should use Developer ID signing and notarization.

macOS may ask for Input Monitoring again after replacing a locally built app or
helper with a new executable. CatGuard fails open while permission is missing:
the menu-bar icon becomes the orange warning symbol and physical input remains
available. Re-enable both `CatGuard.app` and `com.oanaffg.CatGuard.Helper` in
**System Settings → Privacy & Security → Input Monitoring**, then relaunch the
app if macOS requests it. Ordinary users would not encounter local rebuilds;
this note is primarily for source-build development.

The reusable state machines and research utilities use Swift Package Manager:

```sh
swift build
swift test
```

The package contains two intentionally separate research tools:

- `catguard` is the earlier camera/Bluetooth presence prototype. It is not used
  by the production app and never disables input.
- `catguard-hid-test` is the physical-input diagnostic that validated the app's
  HID and event-tap architecture. Its seizure modes impose hard time limits.

Read [the HID experiment log](docs/HID-EXPERIMENTS.md) before running the latter
with `sudo`.

## Architecture

CatGuard keeps the user-session and root responsibilities deliberately separate:

- The menu-bar app owns Focus state, settings, Keychain storage, notifications,
  pointer filtering, circle detection, session counts, and the five-minute idle
  policy.
- The privileged helper owns only external keyboard enumeration, atomic HID
  seizure/release, key-down counting, rescue phrase matching in memory, and the
  heartbeat watchdog.
- Authenticated XPC exposes only arm, disarm, heartbeat, and status data. There
  is no arbitrary command or filesystem interface.

See [Architecture](docs/ARCHITECTURE.md),
[HID experiments](docs/HID-EXPERIMENTS.md), and the
[early design history](docs/IDEA.md) for details.

## Ask Codex to build your variant

**This is the recommended installation path.** The implementation is open
source, but hardware, desired recovery gestures, and macOS versions differ—and
software with global input access plus a root helper deserves more scrutiny than
an ordinary menu-bar app. Give Codex this prompt so it can inspect the design,
explain every privileged capability, and build and validate a version for your
own setup:

```text
Build me a native Swift macOS menu-bar app inspired by CatGuard. Its threat model
is accidental feline input only, never human security. While a configured Focus
Filter is active, block physical external-keyboard input and physical pointer
clicks, drags, and scrolling, but preserve trusted synthetic Computer Use events.
Use a narrowly scoped authenticated privileged helper for atomic IOHID keyboard
seizure, with a heartbeat watchdog that fails open. Keep pointer handling in the
user-session app with a Core Graphics event tap and filter only empirically
verified physical events. Add a mouse/trackpad circle bypass, a Keychain-backed
rescue phrase, and re-arm only after five continuous minutes of physical-input
inactivity while the Focus remains active. On Focus end, notify me of keyboard
key-down and pointer-click counts separately, putting bypass count first when it
is nonzero. Never show “guarded” unless both keyboard and pointer protection are
confirmed. Include hard-timed experiments, unit tests, clean documentation,
signed-helper validation, and an emergency recovery path before enabling it on
my real keyboard. Treat global input access and the root helper as hostile trust
boundaries: audit that no keystrokes or other private input are persisted or
transmitted, explain the exact data flow to me, remove every unnecessary
privilege and endpoint, and sign the app/helper pair with an identity controlled
by me rather than trusting a downloaded binary.
```

Do not blindly copy CatGuard's team ID or bundle identifiers. Ask Codex to use
your signing identity and to re-run the physical-versus-synthetic boundary tests
on your exact macOS release and hardware.

## License

[MIT](LICENSE). Built for cat people, AI nerds, and the considerable overlap
between those populations.
