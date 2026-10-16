# Diagnostic reports

A diagnostic report is the only thing SentryScreen ever sends over the
network. It is sent once, only when the Mac's owner chooses to send it.

## When a report is sent

Never automatically. There are no background, scheduled, crash-triggered or
error-triggered sends, no queue and no retries.

1. Open Settings and press **Review a diagnostic report…** (under the fold of
   the App page).
2. If a parent PIN is set, enter it.
3. SentryScreen builds the report and shows all of it, exactly as it will be
   sent.
4. Press **Send** to send it once, or **Cancel** to discard it. A short notice
   says whether it arrived.

## What is in a report

The report is built from allowlists, then every string goes through one
redaction pass (`daemon/Sources/SentryScreen/DiagnosticsRedaction.swift`):

- App version and build, the model identity, macOS version, architecture,
  Mac model and uptime.
- Your account's uid, whether it is an administrator, and whether it owns the
  console.
- Whether SentryScreen's launchd jobs are running, and their last exit code.
- SentryScreen's settings, reduced to an allowlist of keys. Account names are
  replaced by `admin` or `standard`.
- The tail of SentryScreen's own logs: alerts, allowlisted status lines,
  counter summaries and cover counts.
- SentryScreen's most recent crash log, if there is one.

Never included: screen content, images, what was detected, window titles,
application names, your name, your e-mail address, home-folder paths, or the
device identifiers a crash log carries. A report is at most 256 KiB before
compression.

## What leaves the Mac

One HTTPS `POST` to the address the app was built with
(`SENTRY_DIAGNOSTICS_URL` at build time; release builds use
`https://api.sentry-screen.com/v1/diagnostics`), gzip-compressed JSON, with no User-Agent header. The body is the review text:
the report plus a small envelope (app version and build, macOS version,
architecture, `reason: manual`, the time). The receiver requires a
`machine_id` field; SentryScreen fills it with a new random value for every
report and never stores it, so two reports cannot be linked to each other or
to a Mac.

The reply is read only for its HTTP status, to show "sent" or "not sent".
Nothing from the server is stored or acted on.

The receiver's source is in the `sentryscreen-web` repository
(`src/diagnostics.ts`).
