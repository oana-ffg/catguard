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
macOS disables the tap for a timeout, its callback immediately re-enables it.

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

The repository has no networking dependency in the app target. Reviewers should
still verify that invariant, the PID filter, and the absence of persistence for
input contents on every release.
