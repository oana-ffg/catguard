# CatGuard

CatGuard is an experimental, lightweight macOS safety daemon intended to keep
local computer-use agents working while preventing cats from operating physical
input devices when no human is present.

The repository is currently at milestone 1: a native Swift command-line presence
indicator and a tested presence state machine. It does **not** disconnect devices
or run persistently yet.

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

## Development

```sh
swift build
swift test
```

See [docs/IDEA.md](docs/IDEA.md) for the full product goal, safety invariants,
and staged implementation plan.
