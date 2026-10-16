# Roadmap

SentryScreen is free software under the AGPL-3.0, with no paid tier. Plans, not
promises; ideas and pull requests are welcome (see
[CONTRIBUTING.md](../.github/CONTRIBUTING.md)).

## Next

- **Wider testing.** Apple silicon on macOS 27 is tested. Intel Macs and
  macOS 14–26 build but are untested; reports from those Macs help most.
- **Retraining run.** The training scripts in `model/training/` pass a small
  end-to-end run; a full retrain on a larger dataset is next.

## Ongoing

- Better detection where reports show misses or false covers.

## Not planned

- Accounts, subscriptions, telemetry, analytics or automatic update checks.
  The only network request stays the diagnostic report the Mac's owner
  reviews and sends ([diagnostics.md](diagnostics.md)).
- Publishing the training dataset.
