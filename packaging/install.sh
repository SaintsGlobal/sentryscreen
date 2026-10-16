#!/bin/bash
# Install from a source build, without a .pkg: lays down the same system layout
# the package postinstall does. Run with sudo from the repo root after
# packaging/bundle.sh. Uninstall with
# "/Library/Application Support/SentryScreen/uninstall.sh".
set -euo pipefail
cd "$(dirname "$0")/.."
# The script changes to the runtime repo root first.
# shellcheck disable=SC1091
source packaging/release.env
MODEL_SOURCE="${SENTRY_MODEL_PATH:-model/weights/$SENTRY_MODEL_FILE}"
[ "$(id -u)" = "0" ] || { echo "run with sudo" >&2; exit 77; }
test -d "$MODEL_SOURCE" || { echo "model weights missing: $MODEL_SOURCE (fix: SENTRY_MODEL_PATH)" >&2; exit 1; }

# Check the signed app before anything is copied.
bash packaging/install-preflight.sh "$PWD/daemon/.build"

SUPPORT="/Library/Application Support/SentryScreen"
mkdir -p "$SUPPORT"

# Replace, never merge: cp -R into an existing bundle merges directory
# trees, leaving stale files inside the .app (and a signature/TCC-identity
# landmine). Same for the mlpackage.
# ${VAR:?} at a destructive site: release.env already rejects an empty
# basename, but an rm -rf under /Library must not depend on a guard in
# another file to avoid expanding to the support directory itself.
rm -rf "$SUPPORT/SentryScreen.app" "$SUPPORT/${SENTRY_MODEL_FILE:?}"
cp -R daemon/.build/SentryScreen.app "$SUPPORT/"
cp -R "$MODEL_SOURCE" "$SUPPORT/$SENTRY_MODEL_FILE"
cp packaging/watchdog.sh "$SUPPORT/watchdog.sh"
cp packaging/agent-launch.sh "$SUPPORT/agent-launch.sh"
cp packaging/uninstall.sh "$SUPPORT/uninstall.sh"
cp packaging/reset-pin.sh "$SUPPORT/reset-pin.sh"
cp packaging/pkg-scripts/json-tool.sh "$SUPPORT/json-tool.sh"
# config.sample.json carries the @SENTRY_MODEL_FILE@ placeholder because the
# pkg copy has no release.env to read; render it the same way build-pkg.sh does.
bash packaging/render-model-template.sh packaging/config.sample.json \
  "$SUPPORT/config.default.json" 644
cp packaging/launchd/com.sentryscreen.agent.plist /Library/LaunchAgents/
cp packaging/launchd/com.sentryscreen.watchdog.plist /Library/LaunchDaemons/

# This is also the pkg postinstall implementation. Keep configuration and
# bootstrap behavior in one place.
SENTRY_MODEL_FILE="$SENTRY_MODEL_FILE" bash packaging/pkg-scripts/configure-install.sh
echo "uninstall: $SUPPORT/uninstall.sh"
