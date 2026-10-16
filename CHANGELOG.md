# Changelog

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
