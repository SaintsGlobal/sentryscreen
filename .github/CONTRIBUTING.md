# Contributing to SentryScreen

SentryScreen is free software under the GNU AGPL-3.0. Contributions are accepted
under the same license.

## Sign-off (DCO)

Every commit must carry a `Signed-off-by:` line (`git commit -s`), certifying the
[Developer Certificate of Origin](https://developercertificate.org/): you wrote the
change or otherwise have the right to submit it under the project's license.

## Build

- Build only with `scripts/build.sh`; it compiles directly with `swiftc`. Do not
  use `swift build` or `xcodebuild`.
- If the SDK check stops, rerun with the `SDKROOT=...` it names.
- `SENTRY_BUILD_ARCHS=arm64 scripts/build.sh` is the fast development build.
- Package with `packaging/build-pkg.sh` (see the root README "Install").

## Rules

- **No telemetry.** Detection runs on the device. Nothing leaves the Mac except a
  diagnostic report the Mac's owner reviews and explicitly sends
  (`docs/diagnostics.md`). Do not add analytics, crash uploaders, update checks or
  any other network call.
- **No User-Agent.** Network code sends no `User-Agent` header, neither spoofed nor
  a library default. In scripts, curl uses `-A ""`.
- **Keep curtain and region separate.** There are two deliberately separate cover
  pipelines: region/media (per-detection covers) and curtain (`Curtain.swift`, one
  window-anchored cover per flagged window, fed by `WindowTracker`, with its own
  state machine). Do not couple them.
- **Limits fail loudly.** A cap, timeout or budget logs its name, configured value
  and observed value. Never drop work silently.
- **Safety rails.** Pass `--ttl` on every development run. Covers are click-through
  by construction. The panic hotkey (Control + Option + Command + X, held 1 s)
  must keep working.
- **No real explicit content** in the repository, tests, issues or screenshots.
  Use `--dev-inject` and benign images to exercise covers.

## Layout

- `daemon/Sources/SentryScreen/`: the app. Pipeline `Capture` → `Detector` →
  `Tracker` → `Overlay`; `main.swift` wires modes and flags.
- `packaging/`: bundle, package, install, uninstall, launchd jobs.
- `model/`: the shipped model and the code to retrain it (`model/README.md`).
