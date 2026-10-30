# SentryScreen design

Code comments cite the section numbers below (for example "SPEC §8.1").

## 1. Problem

Parents have no reliable way to keep explicit images off a family computer.
SafeSearch, DNS block lists and browser settings are too blunt, too easy to bypass
(another browser, a private window, an app), or too much work. SentryScreen filters
what is actually drawn on the screen: if the pixels show nudity, they get covered,
whichever app drew them.

## 2. Approach

Detect on device, in pixels, with a small object detector, and cover only what is
needed. No cloud, no content leaves the Mac, no per-site lists.

## 3. Goals

- Cover explicit content within a fraction of a second of it appearing.
- Never block input: the worst failure is "cannot see", never "cannot act".
- Run continuously with a small footprint; fail loudly, never silently.

## 4. Architecture

```
ScreenCaptureKit stream (30 fps, or 15 fps without a Neural Engine)
  → idle gate (skip unchanged frames)
  → Core ML detector via Vision (640×640 stretch, 18 labels; plus one tile of a
    2×2 grid per evaluated frame, in rotation, when zoomTiles is on — the default)
  → policy filter (per-class thresholds and size floors, TuningPolicy)
  → region tracker (IoU matching, hysteresis)      → region / media covers
  → window attribution (WindowTracker, z-order)    → curtain (one cover per window)
  → one click-through overlay window per display
Side channels: JSONL logs with 60 s summaries, alerts.log, parent menu bar UI,
root watchdog.
```

The app is one executable, run per login session by a LaunchAgent
(`com.sentryscreen.agent`). A root LaunchDaemon watchdog restarts it. There is
no root helper.

## 5. Components

### 5.1 Capture
ScreenCaptureKit on the main display, downscaled to about 1280 wide. The app's own
overlay windows are excluded from capture, otherwise a cover would hide content from
the detector and strobe on and off.

### 5.2 Detection model
YOLOX-S, Core ML, NMS embedded, 18 NudeNet labels; see `model/README.md`. Thresholds
apply to the raw detector score. Shipped block floors: female breast exposed 0.90,
female genitalia exposed 0.70, male genitalia exposed 0.90, buttocks exposed 0.80,
anus exposed 0.70; the covered classes (strict policy) 0.60. High flat floors miss
small or partial true content, because the model scores small boxes lower. With
`zoomTiles` on (the default) the detector also runs one quarter of the screen per
frame at about twice the zoom, so the four quarters are re-checked every four
frames; this costs about 1.6× the detector time per evaluated frame (measured
offline). Performance tier is chosen at launch: `default`
(30 fps) when the Neural Engine is reachable, `no-ane` (15 fps) otherwise
(`PerfTier.swift`).

### 5.3 Box post-processing
Per-class thresholds and size floors (`TuningPolicy`), an exposed box inside a covered
box of the same part is demoted to the covered label, boxes are merged and padded,
then mapped from capture pixels to screen points.

### 5.4 Region tracker and hysteresis
Boxes match active regions by IoU; matched regions follow scrolling content. Region
and media covers paint on the first detection; in curtain mode a region needs two
consecutive frames. A region clears after about 0.4 s of clean frames, or holds about
1 s when its confidence reached 0.6; at the shipped floors every region does.

### 5.5 Overlays
One persistent, borderless, click-through window per display hosts one layer per
cover, updated atomically each frame. Curtain covers are window-anchored: a flagged
window gets one solid cover that follows it (120 Hz window geometry ring), hands off
across window re-creation, and lifts after the window shows clean content.

### 5.6 Logging
JSONL per session (`/Library/Logs/SentryScreen/<uid>/run.jsonl`), rotated at
50 MB × 4, with lean 60 s summaries; `alerts.log` for events a parent should see.
No screen content is logged.

### 5.7 Configuration
`/Library/Application Support/SentryScreen/config.json`, read at launch. Unknown keys
and out-of-range values exit 64 by name. The tuning tools write
`<state>/parent/tuning.json`, reloaded every second.

### 5.8 Packaging and tamper resistance
System install: the app and model under `/Library/Application Support/SentryScreen`,
LaunchAgent with `KeepAlive` and a root watchdog. The child uses a Standard
account and cannot unload them.

## 6. Performance targets

| Metric | Target |
|---|---|
| Detection to cover | about 0.1–0.25 s typical, 0.4 s worst |
| CPU | ≤ 25% of one core under sustained motion; much less on an idle screen |
| Memory | ≤ 500 MB RSS (tripwire 256 MiB, logged) |
| Logs on disk | ≤ 200 MB |
| False positive | one cover that clears by itself, never a full-screen blackout |

## 7. Known limitations

- Reactive: content can show briefly before it is covered.
- Content that is only partly in view may not be detected until more of it shows.
- Nudity only: not violence, gore or text.
- Native full-screen transitions show the window for about 0.5 s; macOS draws the
  animation above every window.
- Protected (DRM) video captures as black and is not analyzed.
- One Mac, one display. macOS shows its screen-capture indicator and periodically
  asks the user to re-confirm screen capture.

## 8. Failsafe

### 8.1 Safety layers
1. **Panic hotkey:** hold Control + Option + Command + X for 1 s, authenticate as an
   administrator; covers clear and detection pauses 5 minutes.
2. **Tripwires:** at most 30 region layers; region covers over 90% of the screen for
   over 60 s are lifted for 10 s, without a prompt, in every build. Window covers
   (curtains) and detection stay on, and the release is written to `alerts.log`.
3. **Dead-man switch:** every development run uses `--ttl`.
4. **Remote escape:** keep SSH available when testing the installed agent.
5. **Second account:** covers belong to one session; another admin account is clean.
6. **Staged rollout:** test uninstall before relying on `KeepAlive`.
7. **Removal:** Settings › Uninstall… (administrators only) runs the
   installed `uninstall.sh` through a separate signed uninstaller.
8. **Development triggers** (`SIGUSR1` inject, `SIGUSR2` panic) are armed only with
   `--dev-inject`; otherwise the attempt is logged and ignored.
9. **Log root** `/Library/Logs/SentryScreen` is 1777 with root-created per-uid
   directories so one account cannot tamper with another's logs.

Click-through is asserted for every overlay surface by `--ui-selftest`.

### 8.2 Testing without real content
`--dev-inject` registers Control + Option + Command + I to inject fake boxes, so covers,
tracking, hysteresis and the panic path can be tested with benign screens.

### 8.3 Test order
Foreground run with `--ttl` first, then an installed agent without `KeepAlive`, then
panic hotkey and uninstall from a cold boot, and only then `KeepAlive`.
