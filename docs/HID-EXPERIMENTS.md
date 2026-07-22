# CatGuard physical-input experiments

This document records the experiments that led to CatGuard's production input
architecture. It exists so future maintainers do not repeat attractive but
non-working approaches.

Experiments were performed on macOS 26 in July 2026 with an external Bluetooth
Apple Magic Keyboard and Magic Trackpad.

## Threat model

CatGuard protects an unattended, unlocked Mac from accidental input by cats.
The adversary has paws, curiosity, and no deliberate bypass strategy.

CatGuard is **not** designed to protect against people. It is not an
authentication boundary, lock screen, anti-tampering product, parental-control
tool, or substitute for macOS account security. A person with access to the Mac
can quit, disable, modify, or bypass it. The fallback rescue phrase is a
convenience feature for the feline threat model, not a secure password.

The other central requirement is that trusted computer-use agents must continue
to operate the GUI while physical input is guarded.

## Result summary

The validated design is intentionally split:

- A Core Graphics event tap observes and suppresses physical pointer clicks,
  drags, and scrolling. It also receives relative X/Y deltas for a one-finger
  circle escape gesture.
- A privileged helper exclusively opens physical keyboard HID collections.
  This blocks keyboard input below the application-shortcut layer.
- Synthetic Computer Use interactions remain functional.
- A natural one-finger circle temporarily releases physical input.
- A hard timer, helper watchdog, rescue phrase, and process-exit cleanup provide
  independent recovery routes.

## Experiment 1: exclusive IOHID seizure

The test utility opens selected devices with
`kIOHIDOptionsTypeSeizeDevice` through `IOHIDDeviceOpen`.

### What worked

- The external Magic Keyboard and Magic Trackpad were enumerated without using
  names alone. Safety filters included transport, vendor, product, usage page,
  usage, and built-in status.
- Every eligible collection was opened individually. Partial acquisition was
  treated as failure and immediately rolled back.
- Physical keyboard and trackpad input stopped.
- Computer Use successfully operated Photos while Oana pressed keys, moved the
  trackpad, and clicked physically.
- The process released every collection automatically at the deadline and on
  `SIGINT`/`SIGTERM`.
- Releasing a seized trackpad collection took approximately 0.05–0.19 ms in
  `IOHIDDeviceClose`; the whole measured release routine took approximately
  0.16–0.81 ms. Perceived recovery was immediate.

### Privilege boundary

The primary external keyboard collection returned `kIOReturnNotPrivileged` for
an ordinary user process, even with Input Monitoring access. Running the same
test through `sudo` succeeded. The primary trackpad collection could be seized
without root.

This is why the production design needs a narrowly scoped privileged keyboard
helper but can keep pointer gesture recognition in the user-session app.

### Relevant command

```sh
sudo .build/debug/catguard-hid-test --seize --duration 600
```

The experiment always imposed a maximum ten-minute deadline.

## Experiment 2: reading trackpad IOHID values

We initially expected the seized Magic Trackpad's public IOHID elements to
provide movement or raw multitouch reports.

The device exposed four application collections:

- Generic Desktop / Mouse (`1/2`)
- Apple vendor `65280/18`
- Apple vendor `65280/11`
- Apple vendor `65280/13`

The primary pointer descriptor advertised relative X/Y and three buttons. Vendor
elements also advertised large Apple-specific reports.

### What did not work

Neither `IOHIDDeviceRegisterInputValueCallback` nor
`IOHIDDeviceRegisterInputReportCallback` delivered values from any collection.
This remained true when:

- callback registration happened before and after opening;
- the process opened normally or seized the collection;
- the process ran as the user or through `sudo`;
- `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` returned `granted`; and
- each collection was tested separately.

The diagnostic counts consistently reported zero values while physical movement
was definitely occurring.

I/O Registry inspection showed the real stream was owned by a separate
`AppleMultitouchDevice` user client. The public IOHID collection remained useful
for suppressing the device, but it was not the readable motion source on this
hardware and macOS version.

### Multitouch protocol investigation

The Linux kernel contains a maintained Magic Trackpad decoder in
[`hid-magicmouse.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-magicmouse.c).
That made decoding contact records plausible, but macOS presented different
collection/report identifiers and did not deliver the reports through the
public callback path. We stopped before introducing a brittle private-protocol
dependency.

## Experiment 3: Core Graphics event tap

A Core Graphics event tap was installed at `cghidEventTap`, at the head of the
tap chain, using a normal filtering tap rather than listen-only mode.

### What worked

- `CGPreflightListenEventAccess()` returned true.
- A Terminal-launched probe captured hundreds of physical pointer events.
- Physical events consistently reported `sourcePID=0` and exposed relative
  `mouseEventDeltaX`/`mouseEventDeltaY` values.
- Returning `nil` suppressed physical clicks, drags, and scrolling. Oana could
  see the cursor move, but clicks on the Dock and Codex did nothing.
- Computer Use continued to switch Photos views, scroll, and perform explicit
  coordinate-level clicks while the physical tap events were suppressed.
- A 662-event validation run detected the circle and changed suppression to
  inactive immediately.

The visible cursor still moving is a macOS behavior at this tap location. For
the feline threat model it is acceptable: cats may move the pointer, but they
cannot activate controls, click, drag, or scroll. Avoiding a lower-level private
driver keeps the implementation maintainable and preserves Computer Use.

### What did not work

Event taps created by a CLI launched inside Codex's process host did not receive
events even though access checks and tap creation succeeded. The same executable
launched directly from Terminal received events. Production therefore uses a
real signed user-session application with explicit Input Monitoring onboarding.

## Circle escape gesture

The escape detector uses only physical PID-0 relative pointer deltas, so it works
with ordinary mice and trackpads rather than depending on Apple multitouch
contacts.

A candidate must satisfy geometric constraints including:

- minimum width and height;
- a short bounded duration;
- enough samples;
- ending close to its starting point;
- meaningful enclosed signed area; and
- path length consistent with a loop rather than a swipe.

Tests accept clockwise and counterclockwise circles and reject straight swipes,
backtracking swipes, open arcs, and disconnected half-circles. A natural small
circle drawn by Oana released pointer input successfully.

This is cat-resistant rather than mathematically cat-proof. Real paw tests remain
useful calibration data. A cat that deliberately draws closed circles has earned
temporary computer privileges.

## Recovery and safety requirements

The production app must preserve these invariants:

1. Never report guarded unless both pointer suppression and keyboard seizure are
   confirmed.
2. If helper communication, permissions, or device acquisition fails, release
   physical input and show an error state.
3. The helper releases all keyboard collections when its app heartbeat expires.
4. Quitting normally disarms before exit; forced termination is covered by the
   helper watchdog.
5. A successful circle or rescue phrase releases immediately.
6. A temporary release re-arms only if the configured Focus remains active.
7. Synthetic Computer Use events remain outside the physical-input suppression
   path.

## Production helper caveat

Apple's modern `SMAppService` can register an approved launch daemon and start it
on subsequent boots. However, developers have reproduced a macOS 26/TCC problem
where an `SMAppService` root daemon cannot exclusively open keyboard HID devices
while an older `SMJobBless` helper can. See the
[`SMAppService` documentation](https://developer.apple.com/documentation/servicemanagement/smappservice)
and the
[matching Apple Developer Forums investigation](https://developer.apple.com/forums/thread/795686).

CatGuard must empirically validate the packaged helper on the target macOS
release. It must not assume that UID 0 automatically bypasses Input Monitoring
or other TCC policy.

## Human-factor cues

Testing exposed an important usability requirement: instructions can be missed
when the user is reading Codex from a phone. Diagnostics therefore use:

- Glass sound plus a white screen flash: perform the requested gesture now.
- Basso sound plus an amber screen flash: read the latest instructions.

These cues are diagnostic conveniences and are not required for normal guarded
operation.
