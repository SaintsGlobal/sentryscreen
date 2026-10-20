# Changelog

## Unreleased

- `--print-tuning`, the tuning log record, `parent/tuning.json` and the Developer
  tab's Copy now write numbers as short decimals (`0.7`, not
  `0.69999999999999996`). The values are unchanged.
- New default block floors for the exposed classes, on the model's 0–1 score:
  female breast 0.90, female genitalia 0.70, male genitalia 0.90, buttocks 0.80,
  anus 0.70 (all were 0.50). The covered classes stay at 0.60, and an exposed box
  mostly inside a covered box of the same part still counts as covered (overlap
  0.90). The higher floors cut false alarms on swimwear. They also miss more small
  or partial content, because the model scores small boxes lower.
- The zoom pass (`zoomTiles`) is now on by default: each evaluated frame also
  checks one quarter of the screen at about twice the zoom, which finds more small
  content and costs about 1.6× the detector time per evaluated frame (measured
  offline; not yet measured on live screens). `--print-tuning`, the tuning log
  record and the Developer tab's Copy now always include `zoomTiles`, so turning
  it off survives a save.
- If you saved anything in Settings › Developer before this release, your
  `parent/tuning.json` still holds the old values. Press **Reset** to adopt the
  new ones.
- Settings › Developer is shorter. Each class shows its name and threshold, and
  its size steps, minimum box and entry frames open from the name; a closed class
  names any of those that differ from the defaults. The size-steps help is a
  tooltip, the buttons are **Reset** and **Copy JSON**, the Detection view's four
  drawing options fold under **Options**, and the Tiles view shows one line until
  the first tile pass. In Last 60 s each row's floor moved to its second line, a
  key explains the row symbols, covered classes use their own codes (FBC, FGC,
  BC), and the suppression counts fold under **Removed by rules**.
- Settings › Developer's Last 60 s records only while the Developer tab is open
  and for 10 minutes after it closes, so a Mac where nobody opens the tab no
  longer does that work on every frame.
- Removing the app is called **Uninstall…** everywhere: the popover, Settings,
  the Setup window, the confirmation and the Uninstaller. In the popover it sits
  beside Settings… instead of on a line of its own (it keeps its own last line
  while protection is interrupted). With no PIN set, Settings offers "Set a PIN…"
  (not "Change PIN…") and says that changes ask you to set one.
- Settings › General has no "More settings" fold. Under Recent activity a
  **Parent** card holds Set a PIN… / Change PIN…, **Diagnostic report…** (what
  Review Report opened) and, for administrators, **Uninstall…**. "Forgot PIN?" is
  on the Enter PIN screen, and the version is small text at the bottom left of
  Settings.
- Settings › **Developer** asks for the parent PIN before it opens (or for a new
  PIN, if none is set). Once open it stays unlocked until the popover closes, and
  its changes do not ask again.
- The Developer tab's Tiles view has a **Zoomed tile** view: pick tile 1–4 and see
  it at full width, with its boxes and, with the blurred preview on, its
  thumbnail, plus where it is and how far it zooms (about 1.9×). It is for
  checking that the zoom pass looks at the part of the screen it should. The
  four-up drawing outlines the zoomed tile dashed, and box labels sit on a backing
  so they read over any thumbnail. Turning the preview on returns you to the Tiles
  row after the PIN.
- The Tiles preview has a **Blur** checkbox, on by default and on again each time
  the preview turns off. Off, the tiles show sharp and unfilled, as the detector
  saw them, at 640 px wide, so you can read what the zoom pass looked at. The
  preview checkbox is now called **Show preview**.
- The Tiles view fits on one screen: the four tiles sit beside the tile picker and
  the zoomed tile under them, so you no longer scroll between them. Tapping a tile
  in the four-up zooms it.
- Every drawn box has a label. In the Tiles view a label that would leave the
  drawing (a box at a tile's top or right edge) moves inside it, and the Detection
  view's **Show box labels** is now on by default.
- The Tiles view records tile passes only while its row is open on screen, so a
  closed row costs nothing per frame.
- The exit summary in the log now covers the whole run, including the last
  partial minute.
- Window covers now say "Content blocked — click the title bar, then press ⌘W".
  Covers let clicks through, so the old "click here" sent the click to the covered
  content itself. The title bar is never covered, so clicking it only brings the
  window to the front.
- Settings › Recent activity shows the three newest rows and scrolls to the rest
  (still up to ten).
- The "Start at login" row is gone. It only said that the system starts
  SentryScreen at login, which is unchanged.
- The menu bar icon can no longer be hidden: the "Show menu bar icon" setting is
  gone, and so is the Control + Option + Command + S shortcut that brought a hidden
  icon back. If an older install hid the icon, it reappears; the stored setting is
  still read but ignored.
- Settings › Diagnostics is now a single **Diagnostic report…** row. What a report
  contains and never contains moved to the top of the review, so it is read before
  Send. After Send the review stays open and says whether the report arrived;
  Close returns to Settings, which shows the same outcome under the row.
- The menu bar icon shows a green check while SentryScreen is protecting and every
  setup check passes: Screen Recording is allowed, the installed parts are present
  and both background jobs are registered. The jobs are re-checked every 30
  seconds while the app runs, and the check also needs a live screen capture. If
  any check fails the check mark goes away; paused and needs-attention badges are
  unchanged.
- Settings › Developer › "Last 60 s" now lists one row per detection track (a
  class in one window at one place on screen) instead of per-class totals. Rows
  are ranked by their best score, fading with age (half-life 15 s), and re-sorted
  once a second. Each row shows whether that detection dropped a window cover (✓),
  was covered (◼), was removed by a rule and which one (⊘), or stayed under its
  floor (○); the class, a score bar with the floor marked ("0.93 · floor 0.90"),
  box size, app and age. Rows just under their floor are highlighted. Freeze
  stops re-sorting for up to 30 seconds, Clear empties the list, and Copy readout
  copies every row with the summary lines. Rows hold class names, numbers and the
  app name only. The table holds at most 512 tracks; past that the weakest row is
  dropped, counted on the tab and written to the log.
- Settings › Developer has a **Tiles** row (collapsed, shown only while
  `zoomTiles` is on) that shows what the zoom pass is doing: a 2×2 diagram of the
  screen with the tile being checked now highlighted and each tile's latest boxes
  outlined with class and score; boxes only the zoom found are drawn solid. It
  shows no screen pixels. The Detection view also outlines the tile each frame
  ran.
- An optional **Show blurred preview** in that row (off by default, behind the
  parent PIN) adds a heavily blurred thumbnail per tile with every blocked box
  filled black, at most two per second, kept in memory only. It draws nothing until
  screen capture has confirmed it no longer sees the popover, and it turns off when
  the popover closes, on any pause or panic, after 5 minutes, and when
  `zoomTiles` is turned off.

## 0.4.2 (build 29)

Security follow-ups from the 0.4.1 review.

- When the small per-image covers fill more than 90% of the screen for over a
  minute, SentryScreen now lifts only those covers, for 10 seconds. Window
  covers and detection stay on. Before, it cleared every cover and paused
  protection for 5 minutes, which a child could trigger on purpose by filling
  the screen with flagged images. Each lift is written to the parent alert log
  (at most one line per 10 minutes, with a count).
- Window covers now say "Content blocked — click here, then press ⌘W to close"
  when they are wide enough, so whoever is at the Mac knows how to close the
  covered tab or window.
- The app no longer prepares its detection model in the account's own folders.
  If the model copy that the installer prepares is missing, protection shows
  that it has stopped, and the background watchdog rebuilds the copy and restarts
  protection within about a minute. Before, the app prepared a copy in a folder
  the account controls, where a child could swap it for one that never detects
  anything.
- Removing SentryScreen from the app now runs the root removal script with a
  fixed, clean environment (`env -i` with a fixed PATH, and `bash -p`).
  Before, settings a standard account had made for its own session could
  reach that script once a parent entered the administrator password there.

## 0.4.1 (build 28)

Security and privacy fixes.

- A standard account can no longer stop protection from starting by putting a
  special file (such as a named pipe) where the app writes its logs. The app
  now skips any log file that is not a plain file and starts anyway, and the
  background watchdog moves the bad file aside and records it as tampering.
- The watchdog no longer changes permissions on a log folder after handing it
  to the user, which a user could have redirected to another file.
- If macOS refuses to hide the app's own covers from screen capture, the app
  keeps retrying every 30 seconds instead of giving up, and records the failure
  so it shows in the parent's status and in diagnostics.
- The parent's view of another account now says "detector failing" when
  detection has stopped working there, instead of "protecting".
- Docs: the privacy section names the developer-only option that saves image
  crops (never used by the installed app); the diagnostics page says plainly
  that two reports from the same Mac can be matched by their contents; the
  install-from-source steps include the setting an ad-hoc build needs.
- The package now includes the full Apache License 2.0 text for the YOLOX-based
  detector.

## 0.4.0 (build 27)

First open-source release, under the AGPL-3.0 (code and model weights).

- Free: no license, trial, account or subscription.
- One network request only: a diagnostic report the Mac's owner reviews in full
  and chooses to send, one way, with no User-Agent
  ([docs/diagnostics.md](docs/diagnostics.md)). Its address is set when the app
  is built (`SENTRY_DIAGNOSTICS_URL`).
- No root helper: the installer no longer adds a root parent-controls helper.
- No auto-updater: download new releases from GitHub Releases.
- The tuning tools (Settings › Developer, detection view) are in every build.
- Release packages are Developer ID signed and notarized.
- Upgrades from or to an ad-hoc signed app reset the stale Screen Recording entry, and
  the repair window explains how to re-add SentryScreen if it still reads off.
- "Uninstall SentryScreen…" is in the popover and the Setup window in every
  state, including setup and permission repair.
