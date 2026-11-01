# Runtime waste audit

Scope: the production menu-bar app's idle maintenance and input callback. No
app launch, event-tap installation, permissions prompt, hardware suppression,
installation, or release was used for this audit. Counts come from in-process
Swift harnesses; they are not battery, kernel wake-up, or input-latency readings.

## Circle detection

While guarded with circle bypass enabled, every physical mouse move previously
scanned the three-second sample window four times for bounds, traversed it for
path length and area, and shifted its array as old samples expired. More pointer
reports meant more samples **and** more scans of those samples.

A FIFO made from two aggregate stacks now keeps bounds, length, and signed area
with the samples. Every sample is appended, transferred, and removed once. The
window, detection thresholds, timestamps, reset conditions, and public metrics
are preserved. Floating-point sums are regrouped; regression comparisons allow
small rounding differences. Work is amortized linear over an event stream,
not constant in the worst individual callback: a stack transfer still processes
the retained window. Summaries also use more memory per retained sample than
raw points. Retention remains limited to the same three-second window, with
array capacity reusable across gestures.

The harness feeds a diagonal path for twelve synthetic seconds. This fills and
rolls the window without triggering a bypass:

| Pointer reports | Events | Distance calculations before → after | Sample coordinate reads before → after |
| --- | ---: | ---: | ---: |
| 125 Hz | 1,500 | 493,618 → 5,617 | 5,923,416 → 55,460 |
| 1,000 Hz | 12,000 | 31,511,464 → 44,991 | 378,137,568 → 443,948 |

Reproduce the baseline and current counts from the repository root:

```sh
mkdir -p .build/runtime-costs
git show ea309dca6927e0e5472c0711573fdaf9f84e718c:Sources/CatGuardCore/PointerCircleDetector.swift > .build/runtime-costs/before.swift
python3 scripts/check-runtime-costs.py .build/runtime-costs/before.swift
python3 scripts/check-runtime-costs.py --check
```

The script instruments a temporary copy of the real detector and compiles it
with `swiftc -O`. Counters do not exist in production. CI asserts at most four
distance calculations and forty coordinate reads per input event over each
complete fixture. The old implementation exceeds those budgets. Unit tests
compare rolling metrics with an independent full-window calculation across
12,000 reports, check value-copy isolation, and detect circles in both directions
at both report rates. Existing rejection and idle-gap tests remain in place.

## Idle maintenance

The coordinator formerly woke once per second to ask whether a Focus query,
permission retry, or bypass inactivity check was due. Healthy Focus queries
were already limited to every thirty seconds, so most ticks did no useful work.

A cancellable one-shot scheduler now sleeps until the earliest deadline:

- Healthy Focus reconciliation: thirty seconds.
- Failed Focus query: two seconds, retaining the fail-open policy.
- Unavailable input protection: the existing ten-second retry deadline.
- Active bypass: the existing one-second inactivity check.

Focus callbacks and protection-state changes replan the sleep immediately.
Wake notifications still explicitly refresh Focus. Replanning cancels the
pending sleep, not an active query; Focus's existing revision and single-flight
rules still reject stale results.

A virtual-clock replay of the old one-second loop through the original
`FocusStateMonitor` counted **28,800 maintenance wakes and 961 Focus queries**
for eight idle hours, including the initial query and a query at the endpoint.
`GuardMaintenanceSchedulerTests.idleWakeCount` drives the actual new scheduler
and monitor with a virtual sleeper: **960 maintenance wakes and the same 961
queries**. This is a count of scheduled continuations, not a measurement of
macOS wake-ups. Run it with:

```sh
swift test --filter GuardMaintenanceSchedulerTests
```

Tests also cover earliest-deadline selection, replacing an idle sleep on bypass,
cancellation, preserving active work, and query deadlines after callbacks and
failures. Existing Focus tests cover coalesced refreshes and stale results.

## Checked without changes

- The event callback has no file, settings, Keychain, logging, network, or process
  calls. It updates memory and invokes callbacks. Synthetic events return before
  gesture or rescue processing. The physical classifier and suppression policy
  were not changed.
- Keyboard-down and pointer-down callbacks create main-actor tasks for session
  counts. Guarded pointer movement does not create a task per report. No
  problematic queue growth was demonstrated at realistic key/click rates;
  batching was not justified by this audit.
- Bypass movement notifications are already throttled to one per quarter second.
  Other physical activity remains immediate to preserve the inactivity policy.
- Session history stores bypass timestamps, not event contents or a record per
  input. Counts are integers; a new session clears the previous session. An
  arbitrary history cap would remove the promised bypass report detail without
  evidence of a practical memory problem.
- Settings writes occur on an explicit toggle or save. Keychain migration is a
  launch-only path. Neither runs per tick or per input event.
- Status-item rendering already deduplicates unchanged state. Menu construction
  and notification formatting occur on explicit menu/session actions.
- The separate camera/Bluetooth research CLI is documented and shipped as a
  diagnostic product. It is not started by the menu-bar app. Its samplers schedule
  the next request only after completion; its displayed histories retain ten
  readings. No change was made to experimental diagnostics.

## Verification limits

Safe local checks include Swift package tests/build, an unsigned Xcode app
build, Swift formatting, plist validation, shell syntax, and operation budgets.
A direct callback harness also checked 10,000 physical key-down suppressions,
10,000 pointer-down suppressions, and 10,000 synthetic key passes using unposted
in-memory `CGEvent` values; `PhysicalInputGuard.start()` was never called.

Live event-tap latency, tap timeout behavior, actual idle CPU/battery use, and
physical recovery gestures remain unmeasured. Signed build/install/relaunch and
hardware diagnostics are intentionally left for a separately authorized session.
No other demonstrated runtime-waste finding or unrelated dead code was found.
