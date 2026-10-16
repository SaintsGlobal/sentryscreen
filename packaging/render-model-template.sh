#!/bin/bash
# Render a payload template that cannot source packaging/release.env.
#
# Receipt: packaging/pkg-scripts/configure-install.sh and
# packaging/config.sample.json ship INSIDE the installed payload, where
# release.env does not exist. They therefore carry the literal token
# @SENTRY_MODEL_FILE@ and every writer of a payload copy substitutes it here.
# Callers: build-pkg.sh (both files, into the package) and install.sh
# (config.sample.json, into the development install root).
#
# usage: render-model-template.sh <source> <destination> <mode>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The path is fixed to the runtime repository root.
# shellcheck disable=SC1090,SC1091
source "$ROOT/packaging/release.env"

[ "$#" -eq 3 ] || { echo "usage: $0 <source> <destination> <mode>" >&2; exit 64; }
SOURCE="$1"
DESTINATION="$2"
MODE="$3"
TOKEN='@SENTRY_MODEL_FILE@'

fail() {
  echo "render-model-template: $*" >&2
  exit 1
}

[ -f "$SOURCE" ] || fail "template configured=existing-file observed=missing path=$SOURCE remediation=restore-the-template"
# Tripwire, source side: if someone resolves a merge by pasting a literal
# basename back into a template, the placeholder disappears and this renderer
# becomes a silent no-op that ships the wrong name forever.
/usr/bin/grep -Fq "$TOKEN" "$SOURCE" || \
  fail "template placeholder name=${SOURCE##*/} configured=$TOKEN observed=absent remediation=restore-the-placeholder-in-$SOURCE"

/usr/bin/sed "s|$TOKEN|$SENTRY_MODEL_FILE|g" "$SOURCE" > "$DESTINATION"
/bin/chmod "$MODE" "$DESTINATION"

# Tripwire, destination side: never let an unsubstituted token reach a payload.
if /usr/bin/grep -Fq "$TOKEN" "$DESTINATION"; then
  fail "rendered output name=${SOURCE##*/} configured=no-placeholder observed=unsubstituted-token remediation=packaging/render-model-template.sh"
fi
/usr/bin/grep -Fq "$SENTRY_MODEL_FILE" "$DESTINATION" || \
  fail "rendered output name=${SOURCE##*/} configured=contains-$SENTRY_MODEL_FILE observed=absent remediation=packaging/render-model-template.sh"
