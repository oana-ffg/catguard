# CatGuard

CatGuard is an experimental, lightweight macOS safety daemon intended to keep
local computer-use agents working while preventing cats from operating physical
input devices when no human is present.

The repository is currently at milestone 1: a native Swift presence indicator,
live debugging monitor, and tested presence state machine. It does **not**
disconnect devices or run persistently yet.

## Run the presence indicator

Connect an external USB webcam, then run:

```sh
swift run catguard status
```

On first use, macOS may request camera permission. CatGuard prefers external
cameras and will not use the built-in camera unless explicitly allowed:

```sh
swift run catguard status --allow-built-in
swift run catguard status --camera "camera name"
```

The command samples one 640×480 frame, runs Apple's Vision human-rectangle
detection locally, and discards the frame. It prints `PRESENT` for a confident
detection or `UNCERTAIN` otherwise. A single sample can never report `AWAY`.

Exit codes are `0` for `PRESENT`, `2` for `UNCERTAIN`, and `3` when the camera is
unavailable or an error occurs. Physical input remains enabled in every case at
this milestone.

## Run the live debugging monitor

```sh
swift run catguard monitor
```

The native monitor displays the exact sampled frame passed to Vision, a green
human or red no-human result, confidence, camera details, and the latest 10
detection results. The default interval is five seconds and can be changed:

```sh
swift run catguard monitor --interval 8
```

The webcam is opened only long enough to capture each low-resolution sample.
Only the current frame is retained in memory for display; closing the window
releases it. Images are never written to disk, and the 10-result history contains
metadata only. Monitor mode cannot disconnect input devices.
The process also writes timestamped state, confidence, duration, and camera-name
diagnostics to standard output; these logs contain no image data.

## Development

```sh
swift build
swift test
```

See [docs/IDEA.md](docs/IDEA.md) for the full product goal, safety invariants,
and staged implementation plan.
