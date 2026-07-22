# Architecture

CatGuard has two processes because macOS requires elevated privilege for
exclusive access to an external keyboard's primary HID collection, while Focus,
UI, notifications, Keychain, and pointer events belong in the logged-in user
session.

## User-session app

The `CatGuard` application is an `LSUIElement` menu-bar app. It owns:

- the `SetFocusFilterIntent` exposed to macOS Focus settings;
- the green, red, and orange menu-bar state;
- Settings and About windows;
- `SMAppService.mainApp` login registration;
- rescue phrase persistence in Keychain;
- a PID-filtered Core Graphics event tap;
- geometric circle detection;
- session counts and bypass idle policy; and
- end-of-Focus notifications.

The event tap passes nonphysical events through. For guarded physical pointer
events it observes movement for circle detection, suppresses button actions,
dragging, and scrolling, and counts button-down events only. During bypass it
passes input through and treats physical movement, buttons, scrolling, and keys
as activity that resets the five-minute inactivity timer.

## Privileged helper

`com.oanaffg.CatGuard.Helper` is embedded under
`Contents/Library/LaunchServices` and installed with one administrator approval.
It owns:

- enumeration of non-built-in physical keyboard HID collections;
- all-or-nothing exclusive open and rollback;
- key-down counting;
- in-memory rescue phrase matching;
- immediate release; and
- a three-second heartbeat watchdog.

The helper does not read Keychain, Focus state, arbitrary files, shell commands,
network data, or pointer input. It exposes no general-purpose privileged API.

The app and helper authenticate each other with code-signing requirements over
XPC. The helper interface contains only `arm`, `disarm`, and `heartbeat`; replies
carry success/error state, drained key-down counts, and the rescue-trigger bit.
The requirements are injected into both Info plists at build time. Apple-signed
builds bind to the development team; local-only builds bind to the exact
self-signed certificate fingerprint. The same requirements are used by
`SMJobBless` and the live XPC connections, so the two trust boundaries cannot
silently drift apart.

## State and fail-open behavior

The app has four visible states:

- **Input active** (green): Focus is inactive and physical input is available.
- **Guarded** (red): helper-confirmed keyboard seizure and pointer filtering are
  both active.
- **Bypassed** (green): physical input is available until it has been idle for
  five continuous minutes, as long as Focus remains active.
- **Unavailable** (orange): permissions, helper communication, or acquisition
  failed. CatGuard restores input rather than claiming partial protection.

The order for arming is keyboard first, pointer second. If keyboard acquisition
fails, pointer filtering never activates. On disarm, pointer filtering stops
immediately and the helper returns the last undrained keyboard count while it
releases the HID collections.

Normal application termination waits for the helper's disarm reply. XPC calls
have a three-second timeout; abrupt termination and an unresponsive client are
covered independently by the helper's three-second watchdog.

If macOS denies the helper's Input Monitoring access, the helper fails open and
exits after returning the error. Launchd starts a fresh process on the app's
rate-limited retry, allowing a newly granted TCC permission to take effect
without requiring a reboot.

## Why the helper uses SMJobBless

`SMJobBless` is deprecated. The preferred `SMAppService` launch-daemon path was
considered first, but current macOS reports show root daemons registered that way
can still be denied exclusive keyboard HID access while an `SMJobBless` helper
succeeds. Because keyboard seizure is the helper's entire purpose, CatGuard uses
the older narrow mechanism until the modern path is empirically equivalent.

This is a documented compatibility choice, not an assertion that root bypasses
TCC. Each packaged release must repeat the helper installation and HID tests on
its supported macOS versions.
