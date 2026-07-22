# Agent build guide: physical-input guards on macOS

This guide is for coding agents and humans building a CatGuard-like utility. It
turns the experiment history into a repeatable implementation and validation
workflow. Read [the threat model and raw results](HID-EXPERIMENTS.md) before
changing the input boundary.

## Start with the actual threat model

CatGuard prevents accidental input from cats on an unlocked Mac. It is not a
security boundary against humans. This distinction determines the architecture:

- visible cursor movement is acceptable;
- a human-readable rescue phrase is acceptable;
- quitting the app is an acceptable escape;
- preserving synthetic Computer Use is mandatory; and
- global input permissions remain dangerous even though the process is not root.

Do not reuse this design for authentication, exam proctoring, parental control,
malware resistance, or protection from a deliberate person.

## The production design that worked

Use one signed, logged-in user application with a Core Graphics filtering event
tap:

```swift
CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: context
)
```

The production mask includes:

- `keyDown`, `keyUp`, and `flagsChanged`;
- left, right, and other mouse button down/up;
- mouse movement and all dragged variants; and
- scroll wheel events.

On the hardware tested here, physical HID events consistently report
`eventSourceUnixProcessID == 0`. Computer Use events carry an originating
process PID. CatGuard suppresses only the empirically verified PID-0 class.
Never assume this boundary on different hardware or a new macOS release without
retesting it.

While guarded:

- return `nil` for physical keyboard events;
- return `nil` for physical clicks, releases, drags, and scrolling;
- pass pointer movement after feeding its deltas to the circle detector; and
- pass every event that does not match the verified physical classifier.

Keep the callback fast. Mutate a small lock-protected state value, schedule UI
work outside the callback, and re-enable the tap when macOS sends
`tapDisabledByTimeout` or `tapDisabledByUserInput`.

## Permissions are two separate gates

Preflight both permissions before claiming protection:

```swift
CGPreflightListenEventAccess()
CGPreflightPostEventAccess()
```

Input Monitoring permits observing global physical events. Accessibility is
also required because `.defaultTap` suppresses events rather than merely
listening. A tap-creation failure after checking only Input Monitoring is often
an unreported Accessibility failure.

TCC permission follows the executable's code-signing requirement, not merely its
bundle identifier or path. Moving from a self-signed build to an Apple
Development build can leave apparently enabled but stale rows in System
Settings. Remove and re-add the `/Applications` copy in both Input Monitoring
and Accessibility after changing signing identity.

## Do not confuse signing with trust

The Focus Filter is an App Intent. On the tested macOS version, a self-signed app
could appear in the Focus Filter picker while its **Add** button remained
disabled. A build signed by the developer's Apple Personal Team enabled it.

A Personal Team development signature is useful on the developer's Mac; it is
not a distributable Developer ID release. Developer ID signing and notarization
identify the publisher, but neither proves that global-input code is harmless.
For this class of app, source inspection plus a locally controlled build is the
recommended installation model.

## Rescue input without retaining typed text

Suppressing key events does not prevent the event tap from recognizing a rescue
sequence. CatGuard maps macOS ANSI virtual key codes directly to physical
QWERTY letter positions and feeds only those letters into an in-memory sequence
matcher. It counts key-down events but never constructs, logs, persists, or
transmits general typed strings.

The rescue matcher should:

- accept only an explicitly validated letters-only phrase;
- reset after a short inter-key gap;
- handle partial-prefix overlap;
- suppress the final matching key as well; and
- latch its callback until the coordinator changes state.

The physical-position mapping is deliberately independent of the active
keyboard layout. Document that tradeoff for non-QWERTY users.

## A device-independent pointer escape

Public IOHID callbacks delivered no usable Magic Trackpad motion values in the
experiments, even with root, valid Input Monitoring access, and every exposed
collection tested. Core Graphics did provide reliable relative X/Y deltas.

Accumulate those deltas into a short path and require all of the following for a
circle:

- minimum width and height;
- minimum sample count and duration;
- bounded maximum duration and idle gaps;
- an endpoint close to the starting point;
- meaningful enclosed area; and
- a plausible path-length-to-span ratio.

Test clockwise and counterclockwise circles. Reject straight swipes,
backtracking swipes, open arcs, disconnected half-circles, and idle-separated
fragments. Ordinary mice and trackpads then share the same escape mechanism.

The cursor still moves at this tap location. Judge that behavior against the
feline threat model: movement cannot activate controls when button actions,
dragging, and scrolling are suppressed.

## Why the privileged helper was removed

An interactive diagnostic run through `sudo` genuinely seized the external
Magic Keyboard and Magic Trackpad with
`IOHIDDeviceOpen(..., kIOHIDOptionsTypeSeizeDevice)`. It also proved that
Computer Use continued to work and that device release was effectively
instantaneous.

The same API in an authenticated, Team-signed `SMJobBless` launchd helper was a
dangerous false positive:

- `IOHIDDeviceOpen` returned `kIOReturnSuccess`;
- the helper retained the device objects and reported itself guarded;
- physical keyboard input still reached applications; and
- I/O Registry showed `ClientOptions=1` but `ClientSeized=No` for the helper's
  `IOHIDLibUserClient` instances.

Reinstalling after granting the helper Input Monitoring permission did not
change the result. The important lesson is broader than CatGuard: never treat a
successful API return as proof of an exclusive hardware effect. Validate the
kernel-visible state and the real physical behavior in the exact process
context that will ship.

For this threat model, user-session event suppression is more truthful, less
privileged, easier to recover, and sufficient. The helper, XPC protocol,
launchd configuration, admin UI, and signing requirements were deleted rather
than left as dormant code.

## State and recovery invariants

Keep activation reasons separate from the current protection state. CatGuard
combines a Focus-filter reason with an in-memory manual-arm latch. A Focus change
must not accidentally clear the manual latch.

The visible states are:

- green `Input active` when no activation reason exists;
- red `CatGuard armed` only after the suppressing tap exists and its policy is
  active;
- green bypass with the exact trigger and five-minute idle policy; and
- orange unavailable when permissions or tap creation fail.

A circle or rescue phrase clears manual arm. If Focus remains active, input is
bypassed until five continuous minutes without physical activity. Physical
activity resets that interval; synthetic Computer Use activity does not.

The process must fail open. A normal quit sets the tap policy inactive, and an
abrupt exit causes macOS to destroy the event tap. Keep at least three independent
recovery paths during development: the circle, rescue phrase, and process exit.
Remote access or a disconnected spare keyboard is a useful fourth route.

## Safe hardware validation sequence

Do not make the first test an indefinite lockout.

1. Build and test the pure state machines and gesture detector.
2. Run diagnostics with a hard deadline and automatic cleanup.
3. Confirm the exact physical event classifier while input is still passed.
4. Suppress pointer clicks first while leaving the keyboard available.
5. Verify that physical clicks fail while Computer Use can still click.
6. Add keyboard suppression and keep a short automatic release or remote escape.
7. With the production app armed, press random physical keys and confirm they do
   not reach a text field.
8. In the same state, use Computer Use to enter text and activate controls.
9. Exercise circle, rescue phrase, Focus-off, normal quit, and force-quit
   recovery separately.
10. Repeat the boundary test after every signing-identity, event-tap, macOS, or
    hardware change.

The successful production validation used an external Apple keyboard and Magic
Trackpad. Physical random keys were blocked while Computer Use typed `Cylvia`
into Photos and loaded the results. Pointer movement remained visible; clicks
and other actions were suppressed until the natural circle bypass fired.

## Repository verification checklist

Before publishing or installing a new revision:

```sh
xcodegen generate
swift test
xcrun swift-format lint --strict --recursive Sources/CatGuardApp Sources/CatGuardCore Tests/CatGuardCoreTests
plutil -lint Config/CatGuard-Info.plist Config/CatGuard.entitlements
bash -n scripts/build-local.sh scripts/build-development.sh scripts/create-local-signing-identity.sh
./scripts/build-development.sh
codesign --verify --deep --strict --verbose=2 .build/xcode-team/Build/Products/Release/CatGuard.app
```

Also inspect the built bundle. It should contain the app executable, resources,
App Intent metadata, and signature only—no helper, daemon, XPC service, system
extension, or networking component.

The code review should explicitly confirm:

- no input contents are persisted or transmitted;
- only key-down and pointer-down counts leave the tap callback;
- the physical classifier is narrow and documented;
- every failure path leaves input available;
- the menu-bar color follows real protection state; and
- documentation still warns users not to trust an arbitrary binary.
