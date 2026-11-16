# Architecture

CatGuard is a single, unprivileged, logged-in user application. It deliberately
does not install a root helper, system extension, kernel extension, or virtual
input driver.

## User-session app

The `CatGuard` application is an `LSUIElement` menu-bar app. It owns:

- the `SetFocusFilterIntent` exposed to macOS Focus settings;
- the green, red, and orange menu-bar state;
- Settings and About windows;
- `SMAppService.mainApp` login registration;
- rescue phrase persistence in Keychain;
- a PID-filtered Core Graphics event tap;
- geometric circle detection;
- session counts, bypass timestamps, and bypass idle policy; and
- end-of-Focus notifications.

The event tap receives physical keyboard and pointer events before normal app
dispatch. Experiments on the supported hardware identify physical events by
`eventSourceUnixProcessID == 0`; events created by Computer Use carry their
originating process ID and pass through unchanged.

While guarded, CatGuard suppresses physical key-down, key-up, and modifier
events. It counts key-downs only. It maps ANSI letter-position virtual key codes
to an in-memory rescue-phrase matcher; it does not construct, store, log, or
transmit typed text. Pointer movement remains visible and supplies relative
deltas to the circle detector. Button actions, dragging, and scrolling are
suppressed, and button-down events are counted.

During bypass, every physical event passes through. Activity resets the
five-minute continuous-inactivity timer. Synthetic events never affect that
timer.

## State and fail-open behavior

Focus filter `perform()` delivers its populated `isEnabled` value through a
process-local notification on the main actor. The coordinator applies it before
`perform()` returns. This application has no intent extension, so the callback
and coordinator run in the same process.

A serialized Focus monitor queries the current filter on startup and wake, and
every 300 seconds as reconciliation for a missed callback. A callback resets that
interval. Query failures retry after 2 seconds, then exponentially back off
through 4, 8, 16, 32, 64, 128, and 256 seconds to a 300-second cap. The first preserves the last
known state and the second clears Focus activation while preserving a manual
arm. A newer callback supersedes any in-flight query result or failure. Observer
registrations are removed on stop or release, and pending queries cannot update
a stopped monitor. If macOS misses a callback, the fallback observes a Focus
change on the next check, about 300 seconds later at most plus the query duration.

The app has four visible states:

- **Input active** (green): no activation reason exists and physical input is
  available.
- **Guarded** (red): the suppressing event tap was created successfully and its
  keyboard and pointer policies are active.
- **Bypassed** (green): physical input is available until it has been idle for
  five continuous minutes, as long as Focus remains active.
- **Unavailable** (orange): a required permission is absent or macOS refused to
  create the event tap. Physical input remains available.

The tap is installed once and switched among inactive, guarded, and bypassed
policies in memory. macOS destroys the tap when the app exits or crashes, so
physical input fails open without a watchdog or privileged cleanup process. If
macOS disables the tap for a timeout or user input, its callback attempts to
re-enable it and requests a health check. While guarded or unavailable, an
independent 30-second timer (5 s tolerance) checks both non-prompting permission
preflights, `CFMachPortIsValid`, and `CGEvent.tapIsEnabled`, even while a Focus
query is suspended. It does not run while input is simply active: arming
rechecks the tap before guarding. Failed re-enable,
revocation, or invalidation tears down the tap and shows orange. Recovery retries
every ten seconds without requesting permissions. Restoring permissions allows
the intended guard policy to resume.

Circle and rescue-phrase callbacks are latched so one gesture cannot issue
duplicate bypasses. The rescue phrase is matched from physical ANSI positions,
which makes it independent of the active text-input destination and avoids
asking macOS to synthesize suppressed characters.

## Trust boundary

Input Monitoring and Accessibility are powerful, system-wide permissions. A
malicious build with the same capabilities could observe keystrokes across
applications or interfere with input. Removing the helper removes an
administrator/root trust boundary, but does not make blind binary installation
appropriate. The recommended distribution model remains source inspection and
a build signed by the person who will run it.

Sparkle 2.8.1 is pinned through SwiftPM and contacts the GitHub release feed
for updates. Its installer/downloader XPC services are disabled and removed
from release builds because CatGuard is not sandboxed. The local release script
signs the remaining nested helpers and framework inside-out using the same
Developer ID, so hardened library validation needs no exception. The app
entitlements remain empty: Core Graphics input access uses macOS privacy
consent, and the in-process Focus App Intent declares no additional entitlement.
This configuration must still be exercised during the owner-assisted switchover.

`UpdateInstallationGate` blocks automatic and requested installation while
either activation reason exists, even during bypass or an unavailable tap, or
while Focus state is unknown. The updater retains its installation continuation
until safe. Quitting is never blocked: it is a documented recovery path, and
logout or restart must not be vetoed. A staged update quit this way is installed
by Sparkle without relaunching, so the guard simply ends, as on any quit. Reviewers should verify these boundaries, the PID filter, and the
absence of persistence or transmission of input contents on every release.

On first launch under the new bundle ID, app-owned preferences are copied once
from the old defaults domain without overwriting new preferences. The rescue
phrase stays in the original `com.oanaffg.CatGuard` Keychain service and account
`rescue-phrase`, preserving the item and its access control. Read/validation
errors preserve the item, open Settings, and block arming visibly. Only a missing
item on a fresh installation creates the default; saving a replacement is an
explicit user action. Login registration uses the new app's `SMAppService.mainApp`;
old Focus, privacy, and login registrations require the documented handover.
