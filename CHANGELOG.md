# Changelog

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
