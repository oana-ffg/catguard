# CatGuard product idea and safety plan

## End goal

Build a lightweight macOS daemon for an Apple-silicon Mac with 8 GB RAM. The Mac
can remain unlocked so Codex and Claude computer-use agents continue working,
while cats cannot operate the physical Bluetooth keyboard, mouse, or trackpad
when a human is away.

CatGuard observes an external USB webcam locally. It samples a low-resolution
frame every 5–10 seconds, invokes Apple Vision only at that interval, and never
records, saves, or transmits images. The intended resource envelope is roughly
100–150 MB RAM and less than 0.5–1% average CPU. Resolution and the analyzed
desk/chair crop should be configurable.

## Non-negotiable safety invariants

1. Input is enabled at process startup and is never restored from a persisted
   `AWAY` state.
2. A confident human detection changes state to `PRESENT` immediately.
3. Missing humans produce `UNCERTAIN` first. `AWAY` requires repeated negative
   detections spanning a configurable delay, initially three minutes.
4. An unplugged, unavailable, permission-denied, stalled, or invalid camera
   immediately enables every managed input device. Unplugging the camera is the
   physical emergency stop.
5. Only selected physical Bluetooth devices are disconnected. CatGuard must not
   install a global input-event filter, because synthetic Accessibility/Core
   Graphics events from computer-use agents must remain functional.
6. A watchdog or independent cleanup mechanism enables all managed devices if
   the daemon exits unexpectedly.
7. SSH or Screen Sharing remains configured as a secondary recovery route.
8. Logs contain only timestamps, transitions, confidence values, health events,
   and device actions—never frames or other image data.

## Intended state model

| State | Meaning | Physical input |
| --- | --- | --- |
| `PRESENT` | A human was detected confidently | Enabled/reconnected |
| `UNCERTAIN` | Absence is not yet established, or camera health is uncertain | Enabled/reconnected |
| `AWAY` | Repeated negative detections exceeded the absence delay | Selected devices disconnected |

Camera failure is represented as `UNCERTAIN` plus a mandatory fail-safe input
enable action. Presence state and device actuation remain separate concepts so
an unreliable sensor can never imply permission to disable input.

## Planned CLI

```text
catguard status
catguard arm
catguard disarm
catguard present
catguard away
```

`present` and `away` should be explicit diagnostic overrides with clearly
documented lifetime and fail-safe behavior, not persisted state.

## Staged delivery

### Milestone 1 — local presence indicator (current)

- Native Swift package using AVFoundation and Vision.
- One-shot external-webcam sample at 640×480; no frame persistence.
- CLI reports `PRESENT` or `UNCERTAIN` plus confidence and camera name.
- Native debug monitor shows the exact in-memory sampled frame, current detection
  result, confidence, and the latest 10 metadata-only results.
- Pure, tested state machine captures immediate presence, delayed/repeated
  absence, and camera-failure recovery semantics.
- No device control, background daemon, or persistent state.

### Milestone 2 — physical-device experiment

- Inventory exact Bluetooth keyboard, mouse, and trackpad identifiers.
- Add a tightly scoped `blueutil --disconnect` / reconnect adapter.
- Before daemon integration, experimentally prove that Codex and Claude can
  still perform GUI actions while those physical devices are disconnected.
- Prove recovery through camera unplug, SSH, and Screen Sharing.

This experiment is a release gate. CatGuard must not automatically disable input
until synthetic agent input and all recovery routes have been validated.

### Milestone 3 — sampled daemon

- Sample at a configurable 5–10 second interval.
- Add configurable confidence, desk/chair crop, absence delay, and required
  negative count.
- Implement `status`, `arm`, `disarm`, `present`, and `away` over a local control
  channel.
- Add structured privacy-safe logs and camera stall detection.

### Milestone 4 — supervision and operational hardening

- Package as a macOS executable/application with correct camera permissions.
- Run under a suitable macOS supervisor and implement an independent cleanup
  path that reconnects devices after crashes or forced termination.
- Measure idle CPU and memory against the resource target.
- Add installation, upgrade, uninstall, and recovery documentation.

## Deliberate exclusions

Python, Docker, Electron, OpenCV, PyTorch, continuous recording, heavyweight
object-detection models, global keyboard/mouse event filtering, and any image
logging or persistence are outside the design.
